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

    func start() async {
        guard supervisor == nil else { return }
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
                await writeStatus(state: .fatal)
                return
            }
        } catch {
            listener.setFatal(ChannelFatalError(code: "instance_lock_error", message: String(describing: error), retryable: false))
            await writeStatus(state: .fatal)
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
            await writeStatus(state: .fatal)
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
        await transportSupervisor.start()
        listener.markTransportConnected()
        await writeStatus(state: .connected)
    }

    func stop() async {
        if let supervisor {
            await supervisor.stop()
        }
        supervisor = nil
        await pipeline?.stop()
        pipeline = nil
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
