import Foundation
import Logging

actor ChannelListenerService {
    private let channel: ChannelId
    private let listener: any ChannelSupervisedListening
    private let security: any ChannelSecurityAdapting
    private let sessionGrammar: any ChannelSessionGrammarAdapting
    private let parseRawEvent: @Sendable (ChannelTransportRawEvent) -> ChannelMessageEvent?
    private let dataDirectory: URL
    private let mediaRoot: URL
    private let ingress: ChannelIngressAdapter
    private let dedupe: any TriggerDedupeChecking
    private let lifecycleCoordinator: ChannelSessionLifecycleCoordinator?
    private let logger: Logger
    private var pipeline: ChannelIntakePipeline?
    private var supervisor: ChannelTransportSupervisor?
    private var ownsLock = false
    /// `start()` suspends at `prepareSupervisedTransport()` while `supervisor` is still nil, so a
    /// `guard supervisor == nil` is not a mutual exclusion: actor reentrancy lets two callers both
    /// pass it, both build a pipeline, and both attach a supervisor — the first of each is then
    /// orphaned but keeps draining events, which is duplicate ingestion of every inbound message
    /// plus a socket `stop()` can never close. This flag is set *before* the first suspension.
    private enum RunState { case stopped, starting, running }
    private var runState: RunState = .stopped
    /// Wall-clock of the last failed start, for the retry floor below.
    private var lastStartFailureAt: Date?
    /// Minimum gap between start attempts after a failure.
    ///
    /// `ChannelTransportSupervisor` owns the real backoff curve, but a failure inside
    /// `prepareSupervisedTransport()` happens *before* the supervisor exists and so gets none of it.
    /// Without a floor, any caller that can drive reconcile in a loop turns that into a connect
    /// flood at the upstream platform.
    private static let startRetryFloor: TimeInterval = 5

    init(
        channel: ChannelId,
        bundle: ChannelBuiltListenerBundle,
        dataDirectory: URL,
        mediaRoot: URL,
        ingress: ChannelIngressAdapter,
        dedupe: any TriggerDedupeChecking,
        lifecycleCoordinator: ChannelSessionLifecycleCoordinator? = nil,
        logger: Logger
    ) {
        self.channel = channel
        self.listener = bundle.listener
        self.security = bundle.plugin.security
        self.sessionGrammar = bundle.plugin.sessionGrammar
        self.parseRawEvent = bundle.parseRawEvent
        self.dataDirectory = dataDirectory
        self.mediaRoot = mediaRoot
        self.ingress = ingress
        self.dedupe = dedupe
        self.lifecycleCoordinator = lifecycleCoordinator
        self.logger = logger
    }

    /// Whether a supervisor is attached right now.
    ///
    /// Not "did start succeed": a start that lost the instance lock or failed to connect returns
    /// with `supervisor` still nil, which is exactly the answer a lifecycle caller wants.
    var isRunning: Bool { supervisor != nil }

    func start() async {
        guard runState == .stopped else { return }
        if let lastStartFailureAt, Date().timeIntervalSince(lastStartFailureAt) < Self.startRetryFloor {
            logger.debug("channel_start_throttled channel=\(channel.rawValue)")
            return
        }
        runState = .starting
        do {
            ownsLock = try ChannelInstanceLock.tryAcquire(
                dataDirectory: dataDirectory,
                channel: channel,
                platformIdentity: listener.platformIdentity
            )
            guard ownsLock else {
                let owner = try ChannelInstanceLock.readOwnerPID(
                    dataDirectory: dataDirectory,
                    channel: channel,
                    platformIdentity: listener.platformIdentity
                )
                listener.setFatal(ChannelFatalError(
                    code: "instance_lock_contention",
                    message: "another process holds the channel lock pid=\(owner.map(String.init) ?? "unknown")",
                    retryable: false
                ))
                await failStart()
                return
            }
        } catch {
            listener.setFatal(ChannelFatalError(code: "instance_lock_error", message: String(describing: error), retryable: false))
            await failStart()
            return
        }
        let pipeline = ChannelIntakePipeline(
            channel: channel,
            config: listener.config,
            security: security,
            sessionGrammar: sessionGrammar,
            mediaRoot: mediaRoot,
            dedup: ChannelMessageDedup(
                dedupe: dedupe,
                ttlSeconds: listener.config.dedupe.ttlSeconds,
                logger: logger
            ),
            lifecycleCoordinator: lifecycleCoordinator,
            logger: logger
        ) { [ingress] trigger in
            _ = try? await ingress.ingest(trigger)
        }
        self.pipeline = pipeline
        do {
            try await listener.prepareSupervisedTransport()
        } catch {
            listener.setFatal(ChannelFatalError(code: "connect_failed", message: String(describing: error), retryable: true))
            await failStart()
            return
        }
        let parseRawEvent = parseRawEvent
        let transportSupervisor = ChannelTransportSupervisor(
            transport: listener.transportForSupervision(),
            logger: logger
        ) { [pipeline, listener, self] raw in
            guard let event = parseRawEvent(raw) else { return }
            await pipeline.process(event: event)
            listener.markTransportConnected()
            await self.writeStatus(state: listener.state)
        }
        supervisor = transportSupervisor
        runState = .running
        lastStartFailureAt = nil
        await transportSupervisor.start()
        listener.markTransportConnected()
        await writeStatus(state: .connected)
    }

    /// Unwind a start that failed partway.
    ///
    /// Every early return in `start()` used to leave whatever it had already taken: the instance
    /// lock, and — on the `connect_failed` path — a live `ChannelIntakePipeline` with its debounce
    /// tasks. Repeated reconciles then leaked one pipeline per attempt and left the lock held by a
    /// listener that was not listening, so a second instance saw `instance_lock_contention` from a
    /// dead channel.
    private func failStart() async {
        await pipeline?.stop()
        pipeline = nil
        if ownsLock {
            try? ChannelInstanceLock.release(
                dataDirectory: dataDirectory,
                channel: channel,
                platformIdentity: listener.platformIdentity
            )
            ownsLock = false
        }
        runState = .stopped
        lastStartFailureAt = Date()
        await writeStatus(state: .fatal)
    }

    func stop() async {
        if let supervisor {
            await supervisor.stop()
        }
        supervisor = nil
        await pipeline?.stop()
        pipeline = nil
        runState = .stopped
        // A deliberate stop is not a failed start: clear the retry floor so an owner who pauses and
        // immediately resumes is not made to wait it out.
        lastStartFailureAt = nil
        listener.markTransportDisconnected()
        if ownsLock {
            try? ChannelInstanceLock.release(
                dataDirectory: dataDirectory,
                channel: channel,
                platformIdentity: listener.platformIdentity
            )
            ownsLock = false
        }
        await writeStatus(state: .disconnected)
    }

    func listenerInstance() -> any ChannelSupervisedListening {
        listener
    }

    func cancelDebounce(burstKeys: Set<String>) async {
        await pipeline?.cancelDebounce(burstKeys: burstKeys)
    }

    private func writeStatus(state: ChannelListenerState) async {
        let counters = await pipeline?.counters ?? ChannelIntakeCounters()
        let inflight = await pipeline?.inflightDebounceCount() ?? 0
        // The fatal is reported whenever one is recorded, even at `.connected`.
        //
        // `ChannelSupervisedListening` has no `clearFatal`, so a listener that went fatal and was
        // later restarted still carries the old error. Suppressing it on non-fatal states looks like
        // the fix and is not: `stop()` writes `.disconnected`, so the *first* stop after a failure
        // would erase the only record of why the channel died — and this file is where an operator
        // is told to look. `state` already carries the recovery: `.connected` with a fatal present
        // reads as "failed, then came back".
        let snapshot = ChannelRuntimeStatusSnapshot(
            channel: channel.rawValue,
            platformIdentity: listener.platformIdentity,
            state: state,
            fatalError: listener.fatalError,
            counters: counters,
            inflightDebounce: inflight,
            updatedAt: Date()
        )
        try? ChannelRuntimeStatus.write(snapshot, dataDirectory: dataDirectory)
    }
}
