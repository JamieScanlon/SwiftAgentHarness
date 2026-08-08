import Foundation
import Logging

/// A connect attempt that outlasted ``ChannelListenerService/connectTimeout``.
struct ChannelConnectTimeout: Error, Equatable {
    var seconds: TimeInterval
}

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
    /// plus a socket `stop()` can never close. `starting` is set *before* the first suspension.
    ///
    /// `stopping` exists for the mirror-image reason: `stop()` suspends twice before it can honestly
    /// say `stopped`.
    ///
    /// Two things need to know about that window. `start()` must keep refusing throughout it — which
    /// is why this is a distinct case rather than setting `stopped` early, since that would let a
    /// second attempt take the instance lock while the first supervisor was still draining. And a
    /// superseded `start()` resuming mid-teardown must be able to tell that nobody owns the shared
    /// transport, so it closes the connection it just opened instead of leaking it.
    private enum RunState { case stopped, starting, stopping, running }
    private var runState: RunState = .stopped
    /// Bumped by every `start()` attempt and by every `stop()`.
    ///
    /// `runState` alone cannot tell an in-flight start that it has been superseded: `stop()` sets
    /// `.stopped`, and a later `start()` sets `.starting` again, so a start resuming from
    /// `prepareSupervisedTransport()` sees a state consistent with its own and attaches a supervisor
    /// to a transport nobody wants any more. That listener is then running, holds no instance lock
    /// (the interleaved `stop()` released it), and — since the registry gained a teardown path — may
    /// be unreachable from the registry that would stop it, so it survives to process exit ingesting
    /// events. Comparing an epoch captured before the first suspension is what makes "am I still the
    /// current attempt" answerable. Same pattern as `PacedBlockSender.runGeneration`.
    private var lifecycleEpoch: UInt64 = 0
    /// Wall-clock of the last failed start, for the retry floor below.
    private var lastStartFailureAt: Date?
    /// Minimum gap between start attempts after a failure.
    ///
    /// `ChannelTransportSupervisor` owns the real backoff curve, but a failure inside
    /// `prepareSupervisedTransport()` happens *before* the supervisor exists and so gets none of it.
    /// Without a floor, any caller that can drive reconcile in a loop turns that into a connect
    /// flood at the upstream platform.
    private static let startRetryFloor: TimeInterval = 5
    /// Ceiling on one connect attempt, for a transport that honours cancellation.
    ///
    /// `prepareSupervisedTransport()` is the only unbounded await in this actor, and it is reached
    /// while `ChannelListenerRegistry.reconcile()` holds its serialization gate — so a connect that
    /// never returns wedges every channel lifecycle operation in the process, not just this channel.
    ///
    /// **Read the limit carefully.** Structured concurrency cannot abandon a child task: the group
    /// cancels the loser and then *waits* for it. So this bounds a cooperative connect — one that
    /// checks cancellation, which URLSession-shaped and most SDK clients do — and does **not** bound
    /// one that ignores it. A real transport must still carry its own deadline; this is a backstop,
    /// not a guarantee, and claiming otherwise would be worse than having no timeout at all. No
    /// in-tree transport can hang today, so none of this is exercised yet.
    private static let connectTimeout: TimeInterval = 30

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
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
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
                await failStart(epoch: epoch, fatal: ChannelFatalError(
                    code: "instance_lock_contention",
                    message: "another process holds the channel lock pid=\(owner.map(String.init) ?? "unknown")",
                    retryable: false
                ))
                return
            }
        } catch {
            await failStart(epoch: epoch, fatal: ChannelFatalError(
                code: "instance_lock_error",
                message: String(describing: error),
                retryable: false
            ))
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
            try await Self.withConnectTimeout(seconds: Self.connectTimeout) { [listener] in
                try await listener.prepareSupervisedTransport()
            }
        } catch {
            // Read before the disconnect below, not after. `Task.isCancelled` is a property of the
            // calling task, so a genuine `connect_failed` — a bad credential — whose caller happens
            // to be cancelled *during* `disconnect()` would otherwise take the cancelled branch and
            // never record the fatal, leaving the only account of why the channel died as a bare
            // `.disconnected`.
            let wasCancelled = Task.isCancelled
            // Guarded for the same reason as the success path below, and more urgently. `failStart()`
            // stops `self.pipeline`, releases the instance lock and arms the retry floor — all of
            // which may belong to a *newer* attempt by the time a slow connect finally throws. A
            // superseded start reaching here would stop the live pipeline, delete the lock file
            // while the new supervisor is running (so a second gateway can double-ingest), and leave
            // `runState == .stopped` with `supervisor != nil` — which lets the next `start()` past
            // its own guard and orphan a supervisor that keeps draining events. That is the
            // duplicate-ingestion defect `runState` was introduced to prevent, re-entered through
            // the error path. It would also record a fatal and a 5s floor over a deliberate `stop()`
            // that had just cleared both.
            //
            // Same disconnect condition as the success path, and for the same reason: a
            // `ChannelConnectTimeout` can be thrown while the operation child actually connected, so
            // "the connect threw" does not mean "no socket". Only when nobody owns the shared
            // transport — a successor owns it from its own `starting` onward.
            guard lifecycleEpoch == epoch else {
                if runState == .stopped || runState == .stopping {
                    await listener.disconnect()
                }
                return
            }
            // Leave the transport no worse than we found it. `failStart()` drops the pipeline and the
            // lock but never disconnects, and `stop()` only disconnects through the supervisor —
            // which does not exist on this path. Without this a connect that half-succeeded, or one
            // that completes after being cancelled, leaves a socket nobody owns, and the retry 5s
            // later opens a second one under the same bot identity.
            await listener.disconnect()
            // A cheap early-out, not the safety net. `disconnect()` above is a suspension point, so
            // this guard is itself stale by the time anything below it runs — which is exactly why
            // the real re-check lives *inside* `failStart`, after its own suspension, where the
            // mutations are. A guard checked before an `await` is not a guard for what follows it,
            // and the first two attempts at this fix both got that wrong.
            guard lifecycleEpoch == epoch else { return }
            // Cancellation is not a channel failure. Wrapping the connect in a task group made
            // `Task.sleep` a cancellation-throwing suspension inside `start()`, so a cancelled caller
            // would land here — and `ChannelSupervisedListening` has no `clearFatal`, so the channel
            // would carry a bogus permanent `connect_failed` for the life of the process.
            //
            // Keyed on the caller's cancellation, not on the error's type. Under caller cancellation
            // both children of the timeout group are cancelled and either may finish first, so the
            // error that escapes can be the transport's own spelling of "cancelled"
            // (`URLError(.cancelled)`, an NIO closed-channel error, a gRPC status) — a type test
            // would miss those. And testing the type *as well* would be the only way to reach this
            // branch with the caller alive, which skips the retry floor: a transport that races
            // internally and lets a child's `CancellationError` escape would then be retried with no
            // floor at all, which is the connect flood `startRetryFloor` exists to prevent.
            if wasCancelled {
                await failStart(epoch: epoch, cancelled: true)
                return
            }
            // A distinct code, because the two failures need different operator responses: a refused
            // connection is a credential or endpoint problem, a timeout is usually the network or an
            // upstream outage. Both are retryable; only one is worth re-reading the config over.
            let code = error is ChannelConnectTimeout ? "connect_timeout" : "connect_failed"
            await failStart(epoch: epoch, fatal: ChannelFatalError(
                code: code,
                message: String(describing: error),
                retryable: true
            ))
            return
        }
        // The connect is the first suspension in this method, so this is the earliest point a
        // `stop()` can have interleaved — and it may still be *in* its teardown, not past it.
        //
        // The connect nonetheless succeeded, so a transport is open. Close it, or it survives to
        // process exit with no supervisor and nobody holding it, and the next `start()` opens a
        // second connection under the same bot identity — the leak the error path above disconnects
        // to avoid. `stopping` as well as `stopped` is the whole point: `stop()` sets `stopping`
        // synchronously but only reaches `stopped` after two awaits, so testing `stopped` alone
        // missed the window this guard exists for. Not `starting`/`running`: the listener owns one
        // shared transport and a successor attempt owns it from its own `starting` onward, so
        // disconnecting then would tear down a live channel.
        guard lifecycleEpoch == epoch else {
            if runState == .stopped || runState == .stopping {
                await listener.disconnect()
            }
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
        // Checked again: `transportSupervisor.start()` is a suspension point too, and a `stop()`
        // running across it saw `supervisor` already set, stopped it and cleared the state. Without
        // this the listener would be marked connected and a `connected` status written for a channel
        // that is stopped.
        guard lifecycleEpoch == epoch else { return }
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
    ///
    /// `cancelled` distinguishes "this attempt was abandoned" from "this attempt failed". A
    /// cancelled start has nothing to report: writing `.fatal` would leave a status file saying the
    /// channel died with no recorded reason — `fatalError` is nil, because cancellation is not a
    /// channel fault — and arming the retry floor would make a caller that merely went away delay
    /// the next real attempt by five seconds.
    private func failStart(
        epoch: UInt64,
        fatal: ChannelFatalError? = nil,
        cancelled: Bool = false
    ) async {
        // Captured before suspending: by the time `stop()` returns, `self.pipeline` may belong to a
        // newer attempt, and the one that must be drained is *this* attempt's.
        let dying = pipeline
        await dying?.stop()
        // The only suspension in this method, and every mutation below owns `self` state a newer
        // attempt may have taken over while it ran — its pipeline, its instance lock, its runState,
        // its retry floor. Without this a failed start deletes the lock file of a *live* attempt and
        // drops its pipeline from the actor while its supervisor keeps ingesting: the
        // duplicate-ingestion defect `runState` exists to prevent, re-entered one frame down. The
        // caller's guard is a guard for what happens before this `await`, not after it — which is
        // the whole lesson of `lifecycleEpoch` and the reason it is threaded in rather than read.
        guard lifecycleEpoch == epoch else { return }
        // Recorded here rather than by the caller, so a superseded attempt cannot brand a healthy
        // listener. `ChannelSupervisedListening` has no `clearFatal` and `writeStatus` reports a
        // recorded fatal at every state including `.connected`, so a fatal set outside this guard
        // sticks to whatever attempt is live for the rest of the process.
        if let fatal {
            listener.setFatal(fatal)
        }
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
        if !cancelled {
            lastStartFailureAt = Date()
        }
        await writeStatus(state: cancelled ? .disconnected : .fatal)
    }

    /// Same epoch discipline as ``failStart(epoch:fatal:cancelled:)``, and for a reason that is easy
    /// to talk yourself out of.
    ///
    /// Known and not fixed here: nothing serializes lifecycle entry points against each other.
    /// `reconcile()` is serialized against itself, but `reload()`, `ChannelListenerRegistry.start()`
    /// and `.stop()` are not, so two `stop()`s can overlap. This method is safe under that; its
    /// *callers* are not entirely — a `reload()` whose `stop()` is superseded finds `runState` not
    /// yet `stopped`, so its `start()` no-ops while it still reports `.restarted`. `reload()` has no
    /// production caller today. The fix is a registry-level gate over all four entry points, not more
    /// epochs down here.
    ///
    /// A concurrent `start()` genuinely cannot interleave into the mutation region — `start()`
    /// returns early unless `runState == .stopped`. A concurrent **`stop()`** can, and nothing
    /// serializes lifecycle entry points: `reconcile()` is serialized against itself, but `reload()`
    /// is stop-then-start with no gate at all, so two reloads of the same channel are enough. Stop #1
    /// suspends in `supervisor.stop()`; stop #2 runs to completion; reload #2's `start()` then takes
    /// the instance lock and attaches a new supervisor; stop #1 resumes and nils *that* supervisor
    /// (orphaning a live one nothing can reach), kills its pipeline, and releases its lock file while
    /// it is ingesting. That is the duplicate-ingestion defect `runState` exists to prevent, entered
    /// through `stop()`.
    ///
    /// So: tear the captured objects down first, re-assert, then mutate. Capturing rather than
    /// reading `self` twice is what makes the teardown apply to *this* stop's objects, and doing it
    /// before the mutations is what keeps the instance lock held until the supervisor is actually
    /// down — mutating first would open a window for a second gateway. The one exception is
    /// `runState = .stopping`, which *must* precede the first suspension; see ``RunState``.
    func stop() async {
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        // Synchronous, before the first suspension. See ``RunState/stopping``.
        runState = .stopping
        let dyingSupervisor = supervisor
        let dyingPipeline = pipeline
        await dyingSupervisor?.stop()
        await dyingPipeline?.stop()
        guard lifecycleEpoch == epoch else {
            // Superseded. The immediate superseder is always another `stop()` — a `start()` is
            // refused while `runState == .stopping`, so it can only own the epoch transitively, once
            // some stop has reached `.stopped`. Either way clear only what is provably still ours,
            // by identity rather
            // than a blanket nil: a stale non-nil `supervisor` leaves `isRunning` true after this
            // returns, and the caller acts on that — `syncOutbound` would arm outbound for a channel
            // that is going down, which is the one thing it exists to prevent.
            if supervisor === dyingSupervisor { supervisor = nil }
            if pipeline === dyingPipeline { pipeline = nil }
            return
        }
        supervisor = nil
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

    /// Run `operation`, or throw ``ChannelConnectTimeout`` if it outlasts `seconds`.
    ///
    /// Whichever child finishes first wins and the group cancels the loser — but it also awaits it,
    /// because a task group may not outlive its children. An operation that ignores cancellation is
    /// therefore *not* abandoned, and this call returns no sooner than it does. See
    /// ``connectTimeout`` for why that is accepted rather than worked around: the alternative is an
    /// unstructured task the caller drops on the floor, which trades a stall for a live socket
    /// nobody owns.
    private static func withConnectTimeout(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ChannelConnectTimeout(seconds: seconds)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
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
