import CryptoKit
import Foundation

/// What the user asked for. Carried into every intent check and, for the specialist sub-agent, every step.
public struct ComputerUseTaskContext: Sendable, Hashable {
    public var userRequest: [String]
    /// Carried verbatim; lost constraints are the most common long-horizon failure.
    public var constraints: [String]
    /// Each must be confirmed with `computer_verify`; restated until it is.
    public var successCriteria: [String]

    public init(userRequest: [String], constraints: [String] = [], successCriteria: [String] = []) {
        self.userRequest = userRequest
        self.constraints = constraints
        self.successCriteria = successCriteria
    }
}

public struct ComputerUseSessionConfiguration: Sendable {
    public var task: ComputerUseTaskContext
    /// Fixed for the session's lifetime.
    public var coordinateMode: ComputerUseCoordinateMode
    public var classifier: ComputerUseActionClassifier
    /// Image limit applied to observations that do not set one; taken from the bound model's limits. Keep it within
    /// the tool-result pipeline's `maxInlineImagePixelDimension`: screenshots are never resized after capture, so
    /// one over that cap reaches the model as a marker instead of an image.
    public var imageLimit: ObservationImageLimit?
    /// Observations kept for citing. Older ones must be re-observed.
    public var retainedObservations: Int
    /// Consecutive failed batches before the session escalates to `ask_user`.
    public var maxConsecutiveFailures: Int
    public var conversationID: UUID?
    public var runID: UUID?
    public var accountID: UUID?
    public var auditCapacity: Int
    /// Replay thumbnails kept per session. Past it, the first and the newest are kept.
    public var replayThumbnailCapacity: Int = 120
    public var replayThumbnailEdgePx: Int = Self.defaultReplayThumbnailEdgePx
    /// Anthropic's native toolset, when the bound model speaks it over Anthropic's API; `nil` uses the harness's
    /// own `computer_*` tools.
    public var nativeDialect: ComputerUseNativeDialect?

    public static let defaultReplayThumbnailEdgePx = 320

    public init(
        task: ComputerUseTaskContext,
        coordinateMode: ComputerUseCoordinateMode = .imagePixels,
        classifier: ComputerUseActionClassifier = ComputerUseActionClassifier(),
        imageLimit: ObservationImageLimit? = ObservationImageLimit(longEdgePx: ObservationImageLimit.defaultLongEdgePx),
        retainedObservations: Int = 8,
        maxConsecutiveFailures: Int = 3,
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        accountID: UUID? = nil,
        auditCapacity: Int = 1_000
    ) {
        self.task = task
        self.coordinateMode = coordinateMode
        self.classifier = classifier
        self.imageLimit = imageLimit
        self.retainedObservations = max(1, retainedObservations)
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
        self.conversationID = conversationID
        self.runID = runID
        self.accountID = accountID
        self.auditCapacity = max(1, auditCapacity)
    }
}

public enum ComputerUseTerminalReason: String, Sendable, Codable, Hashable {
    case stepBudget = "step-budget"
    case timeBudget = "time-budget"
    case costBudget = "cost-budget"
    case killSwitch = "kill-switch"
    case permissionRevoked = "permission-revoked"
    /// Too many consecutive steps without progress.
    case noProgress = "no-progress"
    /// The cutoff the task stated passed.
    case deadline
    case ended

    var releaseReason: ReleaseReason {
        switch self {
        case .stepBudget, .costBudget: return .budgetExhausted
        case .timeBudget, .deadline: return .expired
        case .noProgress: return .aborted
        case .killSwitch: return .killSwitch
        case .permissionRevoked: return .permissionRevoked
        case .ended: return .completed
        }
    }
}

public enum ComputerUseGateDecision: String, Sendable, Codable, Hashable {
    case allowed
    /// Allowed after the user confirmed it.
    case confirmed
    case denied
    case userDenied = "user-denied"
    case headlessDenied = "headless-denied"
    case notExecuted = "not-executed"
}

/// One line of the action log: enough to explain every decision after the fact.
public struct ComputerUseActionRecord: Sendable, Codable, Hashable {
    public var step: Int
    public var at: Date
    public var kind: ComputerActionKind
    /// The canonical form with typed text replaced by its hash.
    public var canonical: String
    /// SHA-256 of `canonical`; what an approval is bound to.
    public var binding: String
    public var observations: [ObservationID]
    public var actionClass: String
    public var decision: ComputerUseGateDecision
    public var reason: String
    public var intentVerdict: String?
    public var effect: ActionEffect
    public var evidence: String?
    /// The step led to a state not seen before, as observed next.
    public var madeProgress = false
}

public struct ComputerUseBatchResult: Sendable {
    public var outcomes: [ActionOutcome]
    public var records: [ComputerUseActionRecord]
    /// Observations produced by this batch, in order.
    public var observations: [DisplayObservation]
    public var terminal: ComputerUseTerminalReason?
    /// Set to `askUser` after repeated failures.
    public var escalation: ActionEscalation?
}

public struct ComputerUseVerification: Sendable, Codable, Hashable {
    public var criterion: String
    public var met: Bool
    public var evidence: String
    public var observation: ObservationID
}

public enum ComputerUseSessionError: Error, Sendable, Equatable {
    case ended(ComputerUseTerminalReason)
    case unknownObservation(ObservationID)
    /// Verification must cite an observation taken after the last action.
    case staleVerification(ObservationID)
    /// Verification must cite one of the task's success criteria, when it has any.
    case unknownCriterion(String)
    case takeoverActive
}

public enum ComputerUseHandoffReason: String, Sendable, Codable, Hashable {
    case login
    case twoFactor = "2fa"
    case captcha
    case payment
    case ambiguous
    case consequential
}

public struct ComputerUseHandoffRequest: Sendable, Hashable {
    public var reason: ComputerUseHandoffReason
    public var prompt: String
    public var target: DisplayTargetID
}

public enum ComputerUseHandoffResult: Sendable, Hashable {
    case handedBack(note: String?)
    case declined
    case unavailable
}

public enum ComputerUseUserReply: Sendable, Hashable {
    case answered(String)
    case unavailable
}

/// What a session is doing, for the "agent is using <target>" indicator.
public struct ComputerUseActivity: Sendable, Equatable {
    public var status: ComputerUseSurfaceIntentPayload.Status
    public var step: Int
    public var maxSteps: Int
    /// Bundle id or domain the latest action landed in.
    public var app: String?
    public var action: ComputerActionKind?
    public var terminalReason: ComputerUseTerminalReason?
    /// How many times the step allotment was extended.
    public var extensions = 0
}

/// Asked of a present user when a session reaches its step or time ceiling.
public struct ComputerUseCeilingQuestion: Sendable, Hashable {
    public enum Limit: String, Sendable, Codable, Hashable {
        case steps
        case time
    }

    public var limit: Limit
    public var stepsUsed: Int
    public var extensions: Int
    public var prompt: String

    static func isAffirmative(_ answer: String) -> Bool {
        let first = answer.lowercased().split { !$0.isLetter }.first.map(String.init) ?? ""
        return ["yes", "y", "yeah", "yep", "sure", "ok", "okay", "continue", "go"].contains(first)
    }
}

/// The surfaces a session reaches a person through for questions and human-only steps.
public protocol ComputerUseOversight: Sendable {
    func askUser(_ question: String) async -> ComputerUseUserReply
    /// Returns once the user hands control back.
    func handoff(_ request: ComputerUseHandoffRequest) async -> ComputerUseHandoffResult
    /// Whether to go past a ceiling. `true` grants one more extension.
    func continuePastCeiling(_ question: ComputerUseCeilingQuestion) async -> Bool
}

extension ComputerUseOversight {
    /// Asks through ``askUser(_:)`` and reads a yes from the reply.
    public func continuePastCeiling(_ question: ComputerUseCeilingQuestion) async -> Bool {
        guard case .answered(let answer) = await askUser(question.prompt) else { return false }
        return ComputerUseCeilingQuestion.isAffirmative(answer)
    }
}

/// A session-level entry in the action log: budget extensions, ceiling questions, and how the session ended, with
/// the progress facts behind each.
public struct ComputerUseSessionEvent: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case extended
        case timeExtended = "time-extended"
        case ceilingQuestion = "ceiling-question"
        case ended
    }

    public enum Answer: String, Sendable, Codable, Hashable {
        case `continue`
        case stop
    }

    public var kind: Kind
    public var at: Date
    public var step: Int
    /// The step allotment after an extension.
    public var stepsGranted: Int?
    /// The session's end time after a time extension.
    public var endsAt: Date?
    /// For an extension, progress since the previous one; for the end, the session's totals.
    public var criteriaVerified: Int?
    public var statesReached: Int?
    public var limit: ComputerUseCeilingQuestion.Limit?
    public var answer: Answer?
    public var reason: ComputerUseTerminalReason?

    public init(
        kind: Kind,
        at: Date,
        step: Int,
        stepsGranted: Int? = nil,
        endsAt: Date? = nil,
        criteriaVerified: Int? = nil,
        statesReached: Int? = nil,
        limit: ComputerUseCeilingQuestion.Limit? = nil,
        answer: Answer? = nil,
        reason: ComputerUseTerminalReason? = nil
    ) {
        self.kind = kind
        self.at = at
        self.step = step
        self.stepsGranted = stepsGranted
        self.endsAt = endsAt
        self.criteriaVerified = criteriaVerified
        self.statesReached = statesReached
        self.limit = limit
        self.answer = answer
        self.reason = reason
    }
}

/// One leased computer-use session: gates every action, runs it against the target, and keeps the action log.
public actor ComputerUseSession {
    public nonisolated let id = UUID()
    public nonisolated let lease: Lease
    public nonisolated let manifest: DisplayTargetManifest
    public nonisolated let configuration: ComputerUseSessionConfiguration
    public nonisolated let coordinateCodec: ComputerUseCoordinateCodec
    public nonisolated let startedAt: Date

    private let target: any DisplayTarget
    private let grants: ComputerUseGrantSet
    private let approvals: (any ExecApprovalDelivering)?
    private let intentChecker: ComputerUseIntentChecker?
    private let oversight: (any ComputerUseOversight)?
    private let activity: (@Sendable (ComputerUseActivity) async -> Void)?
    private let now: @Sendable () -> Date

    private var retained: [ObservationID: DisplayObservation] = [:]
    private var refs = ComputerUseRefStabilizer()
    private var retainedOrder: [ObservationID] = []
    private var history: [ComputerUseProposedAction] = []
    private var steps = 0
    private var spentUSD: Double = 0
    private var consecutiveFailures = 0
    /// Actions refused since the last progress. They aren't steps, but they fill the no-progress window.
    private var refusedSinceProgress = 0
    private var lastActionAt: Date?
    public private(set) var terminalReason: ComputerUseTerminalReason?
    /// What ran out, in words, when a budget ended the session.
    public private(set) var terminalDetail: String?
    /// The lease's budgets as extended so far.
    public private(set) var budgets: ComputerUseBudgets
    public private(set) var endsAt: Date
    public private(set) var extensions = 0
    public private(set) var events: [ComputerUseSessionEvent] = []
    private var timeCeiling: Date
    private var progressAtLastGrant = ComputerUseProgress()
    private var endedAt: Date?
    /// The time-ceiling decision in flight, so an action and the child run's timer reaching it together ask once.
    private var endTimeDecision: Task<Void, Never>?
    public private(set) var isTakeoverActive = false
    public private(set) var auditLog: [ComputerUseActionRecord] = []
    /// Records ever appended, so a record can be found after older ones were trimmed.
    private var auditCount = 0
    public private(set) var progress = ComputerUseProgress()
    private var seenStates: Set<String> = []
    /// The latest acting step not yet followed by an observation: its number, effect, and record's position.
    private var pendingActing: (step: Int, effect: ActionEffect, record: Int)?
    public private(set) var verifications: [ComputerUseVerification] = []
    /// Consequential actions denied because nobody was present; surfaced on the next interactive attach.
    public private(set) var headlessDenials: [ComputerUseActionRecord] = []
    /// The latest handoff nobody took, cleared when a later one is handed back.
    public private(set) var unresolvedHandoff: ComputerUseHandoffRequest?
    /// Grants the session's refused actions needed, one per subject at the highest tier asked. Grants can't change
    /// during a run, so the parent has to delegate again with them.
    public private(set) var missingGrants: [ComputerUseGrant] = []
    public private(set) var replayFrames: [ComputerUseReplayFrame] = []
    /// Where the last pointer action left the pointer, in the target's global space.
    public private(set) var lastPointer: DisplayPoint?

    public init(
        target: any DisplayTarget,
        lease: Lease,
        configuration: ComputerUseSessionConfiguration,
        approvals: (any ExecApprovalDelivering)? = nil,
        intentChecker: ComputerUseIntentChecker? = nil,
        oversight: (any ComputerUseOversight)? = nil,
        activity: (@Sendable (ComputerUseActivity) async -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.target = target
        self.lease = lease
        self.manifest = target.manifest
        self.configuration = configuration
        self.coordinateCodec = ComputerUseCoordinateCodec(mode: configuration.coordinateMode)
        self.grants = ComputerUseGrantSet(lease.grants)
        self.approvals = approvals
        self.intentChecker = intentChecker
        self.oversight = oversight
        self.activity = activity
        self.now = now
        self.startedAt = now()
        self.budgets = lease.budgets
        self.endsAt = lease.endsAt
        self.timeCeiling = lease.issuedAt.addingTimeInterval(lease.budgets.maxDuration.timeInterval)
    }

    public var stepCount: Int { steps }

    public func observation(_ id: ObservationID) -> DisplayObservation? {
        retained[id]
    }

    /// The most recent retained observation with pixels: the frame native coordinates refer to.
    public var latestScreenshot: DisplayObservation? {
        retainedOrder.reversed().lazy.compactMap { [retained] in retained[$0] }.first { $0.image != nil }
    }

    public var latestObservation: DisplayObservation? {
        retainedOrder.last.flatMap { retained[$0] }
    }

    // MARK: - Actions

    /// Gates and runs a batch, one action at a time. Stops at the first refusal or failure; every action after it is
    /// reported `not-executed`.
    public func perform(_ actions: [ComputerAction], safetySignals: [Int: [String]] = [:]) async -> ComputerUseBatchResult {
        var result = ComputerUseBatchResult(outcomes: [], records: [], observations: [], terminal: nil, escalation: nil)
        if terminalReason == nil, let reason = await budgetOrPermissionViolation() {
            await end(reason)
        }
        if let terminalReason {
            result.outcomes = notExecuted(actions.indices, evidence: "session ended: \(terminalReason.rawValue)")
            result.terminal = terminalReason
            return result
        }
        if isTakeoverActive {
            result.outcomes = actions.indices.map {
                ActionOutcome(action: $0, effect: .refused, evidence: "the user has taken over")
            }
            return result
        }

        var stopped = false
        for (index, action) in actions.enumerated() {
            if stopped {
                result.outcomes.append(ActionOutcome(action: index, effect: .notExecuted))
                continue
            }
            await enforceBudgets()
            if let terminalReason {
                result.outcomes.append(ActionOutcome(action: index, effect: .notExecuted, evidence: "session ended: \(terminalReason.rawValue)"))
                stopped = true
                continue
            }
            let (outcome, record, observation) = await performOne(action, index: index, signals: safetySignals[index] ?? [])
            result.outcomes.append(outcome)
            result.records.append(record)
            if let observation { result.observations.append(observation) }
            if outcome.effect.stopsBatch || outcome.escalation == .observe { stopped = true }
        }

        let failed = result.outcomes.contains { $0.effect == .refused || $0.effect == .suspectedNoop || $0.effect == .partial }
        consecutiveFailures = failed ? consecutiveFailures + 1 : 0
        if consecutiveFailures >= configuration.maxConsecutiveFailures {
            result.escalation = .askUser
        }
        result.terminal = terminalReason
        return result
    }

    private func performOne(
        _ action: ComputerAction,
        index: Int,
        signals: [String]
    ) async -> (ActionOutcome, ComputerUseActionRecord, DisplayObservation?) {
        let focusedApp = action.citedTargets.isEmpty && Self.needsFocusedApp(action)
            ? (try? await target.describe(lease))?.focusedApp
            : nil
        let classification = configuration.classifier.classify(
            action,
            context: ComputerUseClassificationContext(
                grants: grants,
                observation: { [retained] in retained[$0] },
                focusedApp: focusedApp,
                safetySignals: signals
            )
        )
        let gate = await gate(classification, action: action)
        var record = makeRecord(action, classification: classification, gate: gate)

        guard gate.decision == .allowed || gate.decision == .confirmed else {
            let outcome = ActionOutcome(action: index, effect: .refused, evidence: gate.reason, escalation: gate.escalation)
            record.effect = .refused
            record.evidence = gate.reason
            if gate.decision == .headlessDenied { headlessDenials.append(record) }
            if let missing = classification.missingGrant { noteMissing(missing) }
            appendAudit(record)
            refusedSinceProgress += 1
            await endIfNotProgressing()
            return (outcome, record, nil)
        }

        steps += 1
        record.step = steps
        var produced: DisplayObservation?
        var outcome: ActionOutcome
        do {
            switch action {
            case .observe(var request):
                if request.maxImage == nil { request.maxImage = configuration.imageLimit }
                // The session diffs on its own stable refs; drivers always return the full tree.
                let diffBase = request.diffAgainst
                request.diffAgainst = nil
                var observation = refs.stabilize(try await target.observe(lease, request))
                if let diffBase, let current = observation.tree {
                    let text = retained[diffBase]?.tree.map {
                        ComputerUseTreeDiff.render(base: $0, baseID: diffBase, current: current)
                    } ?? ComputerUseTreeDiff.unavailable(baseID: diffBase, current: current)
                    observation.tree?.diff = ObservationTreeDiff(base: diffBase, text: text)
                }
                retain(observation)
                produced = observation
                outcome = ActionOutcome(action: index, effect: .confirmed, observation: observation.id)
            case .zoom(let region, _):
                let observation = try await target.observe(lease, ObserveRequest(modes: [.pixels], scope: .region(region)))
                retain(observation)
                produced = observation
                outcome = ActionOutcome(action: index, effect: .confirmed, observation: observation.id)
            default:
                let driverAction = action.mappingElementRefs { ref, observation in
                    refs.driverRef(ref, observation: observation) ?? ref
                }
                let outcomes = try await target.act(lease, ActionBatch([driverAction]))
                var first = outcomes.first ?? ActionOutcome(action: 0, effect: .unverifiable, evidence: "driver reported no outcome")
                first.action = index
                outcome = first
                if !Self.isObservation(action) {
                    lastActionAt = now()
                    history.append(classification.proposedAction)
                }
                if let pointer = Self.pointerDestination(of: action) { lastPointer = pointer }
            }
        } catch DisplayTargetError.leaseNotHeld {
            outcome = ActionOutcome(action: index, effect: .refused, evidence: "lease is no longer held")
            await end(.ended)
        } catch {
            // The action may already have been delivered; the next step is an observe, never a second attempt.
            outcome = ActionOutcome(action: index, effect: .unverifiable, evidence: "driver error: \(error)", escalation: .observe)
            if !Self.isObservation(action) { lastActionAt = now() }
        }
        // A step is an action delivered to the driver.
        if outcome.effect == .notExecuted { steps -= 1 }
        record.effect = outcome.effect
        record.evidence = outcome.evidence
        appendAudit(record)
        if outcome.effect != .notExecuted { noteProgress(after: action, effect: outcome.effect, observation: produced) }
        await report(.acting, action: action.kind, app: classification.domain ?? classification.app?.bundleID)
        return (outcome, record, produced)
    }

    private func report(
        _ status: ComputerUseSurfaceIntentPayload.Status,
        action: ComputerActionKind? = nil,
        app: String? = nil
    ) async {
        guard let activity else { return }
        await activity(ComputerUseActivity(
            status: status,
            step: steps,
            maxSteps: budgets.steps,
            app: app,
            action: action,
            terminalReason: status == .ended ? terminalReason : nil,
            extensions: extensions
        ))
    }

    /// Announces the session to the user's surfaces.
    public func announceStart() async {
        await report(.started)
    }

    // MARK: - Gating

    private struct GateResult {
        var decision: ComputerUseGateDecision
        var reason: String
        var escalation: ActionEscalation?
        var intent: ComputerUseIntentVerdict?
    }

    private func gate(_ classification: ComputerUseClassification, action: ComputerAction) async -> GateResult {
        switch classification.actionClass {
        case .outOfGrant(let reason):
            guard let missing = classification.missingGrant else { return GateResult(decision: .denied, reason: reason) }
            return GateResult(
                decision: .denied,
                reason: "\(reason); grants can't change during this run. Finish and report it, and the parent can delegate "
                    + "again with \(ComputerUseGrant.delegateArguments([missing]))"
            )
        case .unresolvable(let reason):
            return GateResult(decision: .denied, reason: reason, escalation: .observe)
        case .observe, .navigate:
            return GateResult(decision: .allowed, reason: "\(classification.actionClass.label) within grant")
        case .interact:
            let intent = await checkIntent(classification)
            switch intent {
            case .consistent?:
                return GateResult(decision: .allowed, reason: "interact within grant; intent consistent", intent: intent)
            case .confirm(let reason, _)?:
                return await confirm(classification, action: action, reasons: [reason], intent: intent)
            case .unbound?, nil:
                let skip = configuration.classifier.reviewer.overrides.skipInteractConfirmationWithoutIntentCheck
                if manifest.humanPresence == .shared && !skip {
                    return await confirm(
                        classification,
                        action: action,
                        reasons: ["no intent checker is bound and a person may be using this screen"],
                        intent: intent
                    )
                }
                return GateResult(decision: .allowed, reason: "interact within grant", intent: intent)
            }
        case .consequential(let reasons):
            let intent = await checkIntent(classification)
            return await confirm(classification, action: action, reasons: reasons, intent: intent)
        }
    }

    private func checkIntent(_ classification: ComputerUseClassification) async -> ComputerUseIntentVerdict? {
        guard let intentChecker else { return nil }
        return await intentChecker.evaluate(ComputerUseIntentCheckInput(
            conversationID: configuration.conversationID,
            runID: configuration.runID,
            accountID: configuration.accountID,
            userRequest: configuration.task.userRequest,
            history: history,
            proposed: classification.proposedAction
        ))
    }

    private func confirm(
        _ classification: ComputerUseClassification,
        action: ComputerAction,
        reasons: [String],
        intent: ComputerUseIntentVerdict?
    ) async -> GateResult {
        let why = reasons.joined(separator: "; ")
        guard lease.userPresent else {
            return GateResult(decision: .headlessDenied, reason: "headlessDenied: \(why)", intent: intent)
        }
        guard let approvals else {
            return GateResult(decision: .denied, reason: "no approval surface for: \(why)", intent: intent)
        }
        let canonical = ComputerUseCanonicalForm.describe(action)
        let binding = ComputerUseCanonicalForm.binding(canonical)
        let request = Self.approvalRequest(
            id: "computer-use-\(binding.prefix(16))-\(UUID().uuidString.prefix(8))",
            canonical: canonical,
            classification: classification,
            target: manifest,
            reasons: reasons,
            intent: intent,
            action: action,
            observation: action.citedObservations.first.flatMap(observation)
        )
        switch await approvals.requestApproval(request, headless: false) {
        case .approved:
            // The approval covers this exact canonical action; anything that changed since invalidates it.
            guard terminalReason == nil, !isTakeoverActive,
                  ComputerUseCanonicalForm.binding(ComputerUseCanonicalForm.describe(action)) == binding else {
                return GateResult(decision: .denied, reason: "the session changed while awaiting approval", intent: intent)
            }
            return GateResult(decision: .confirmed, reason: "confirmed by the user: \(why)", intent: intent)
        case .denied(let message):
            return GateResult(decision: .userDenied, reason: "denied by the user: \(message)", escalation: .askUser, intent: intent)
        case .headlessDenied(let message):
            return GateResult(decision: .headlessDenied, reason: "headlessDenied: \(message)", intent: intent)
        case .deferred(let message):
            return GateResult(decision: .denied, reason: "approval deferred: \(message)", intent: intent)
        }
    }

    static func approvalRequest(
        id: String,
        canonical: String,
        classification: ComputerUseClassification,
        target: DisplayTargetManifest,
        reasons: [String],
        intent: ComputerUseIntentVerdict?,
        action: ComputerAction? = nil,
        observation: DisplayObservation? = nil
    ) -> ExecApprovalRequest {
        var location = classification.domain ?? classification.app?.bundleID ?? target.label
        if classification.domain != nil, let app = classification.app?.bundleID { location += " (\(app))" }
        var element = classification.element?.role ?? "—"
        if let label = classification.element?.label, !label.isEmpty { element += " \"\(label)\"" }
        let title = "Computer use: confirm \(classification.kind.rawValue) on \(target.label)"
        let context = [
            "Action: \(canonical)",
            "Target: \(element) in \(location)",
            "Why confirm: \(reasons.joined(separator: "; "))",
            "Intent check: \(intent?.summary ?? "not run")",
        ]
        var presentation = ApprovalPresentation.standard(
            title: title,
            context: context,
            buttons: [
                ApprovalButton(id: ApprovalDecision.allowOnce.rawValue, label: "Allow this action", style: .primary),
                ApprovalButton(id: ApprovalDecision.deny.rawValue, label: "Deny", style: .danger),
            ]
        )
        if let action, let observation,
           let region = ComputerUseTargetCrop.region(for: action, in: observation),
           let crop = ComputerUseTargetCrop.image(of: region, in: observation, alt: "Target region: \(element) in \(location)") {
            presentation.blocks.insert(.image(crop), at: presentation.blocks.count - 1)
        }
        return ExecApprovalRequest(
            id: id,
            command: canonical,
            title: title,
            description: context.joined(separator: "\n"),
            allowsDurableBypass: false,
            presentation: presentation
        )
    }

    // MARK: - Budgets and lifecycle

    private func budgetOrPermissionViolation() async -> ComputerUseTerminalReason? {
        if let max = budgets.maxUSD, spentUSD > max { return .costBudget }
        let missing = await target.permissions().missing(manifest.requires)
        return missing.isEmpty ? nil : .permissionRevoked
    }

    public func recordCost(usd: Double) async {
        guard usd.isFinite, usd > 0 else { return }
        spentUSD += usd
        if terminalReason == nil, let max = budgets.maxUSD, spentUSD > max {
            await end(.costBudget)
        }
    }

    /// The kill switch. Reachable from the user's surfaces only; no model-facing tool calls it.
    public func stop() async {
        await end(.killSwitch)
    }

    /// Checked before every action. The no-progress window and the end time can end the session; a used-up step
    /// allotment is extended when there was progress since the last grant, and at a ceiling a present user decides.
    private func enforceBudgets() async {
        guard terminalReason == nil else { return }
        await endIfNotProgressing()
        guard terminalReason == nil else { return }
        if now() >= endsAt {
            await reachedEndTime()
            guard terminalReason == nil else { return }
        }
        if steps >= budgets.steps {
            await ranOutOfSteps()
        }
    }

    /// Ends the session once `noProgressSteps` steps and refused actions in a row have made no progress. Refused
    /// actions aren't steps, but a session refused at every turn is going nowhere.
    private func endIfNotProgressing() async {
        guard terminalReason == nil else { return }
        let sinceProgress = steps - (progress.lastProgressStep ?? 0)
        let attempts = sinceProgress + refusedSinceProgress
        guard attempts >= budgets.noProgressSteps else { return }
        await end(.noProgress, detail: refusedSinceProgress == 0
            ? "no progress in the last \(sinceProgress) steps"
            : "no progress in the last \(attempts) attempts, \(refusedSinceProgress) of them refused")
    }

    private func noteMissing(_ grant: ComputerUseGrant) {
        guard let index = missingGrants.firstIndex(where: { $0.sameSubject(as: grant) }) else { return missingGrants.append(grant) }
        missingGrants[index] = missingGrants[index].merging(grant)
    }

    private var grantExpiresAt: Date? {
        budgets.grantExpiry.map { lease.issuedAt.addingTimeInterval($0.timeInterval) }
    }

    /// When the specialist's child run must end: the lease's end time while the session runs, moved when a present
    /// user extends it, and `grace` after the session ends so the child can wrap up. Reaching the end time here
    /// makes the same decision an action would, so a slow model turn doesn't skip the user's question.
    public func childRunDeadline(grace: TimeInterval) async -> Date {
        if terminalReason == nil, now() >= endsAt { await reachedEndTime() }
        if let endedAt { return endedAt.addingTimeInterval(grace) }
        return endsAt
    }

    private func reachedEndTime() async {
        if let endTimeDecision { return await endTimeDecision.value }
        let decision = Task { await self.decideAtEndTime() }
        endTimeDecision = decision
        await decision.value
        endTimeDecision = nil
    }

    /// The deadline and an unattended session's grant expiry are never moved; only the time ceiling is, and only by a
    /// present user.
    private func decideAtEndTime() async {
        let current = now()
        guard terminalReason == nil, current >= endsAt else { return }
        if let deadline = budgets.deadline, current >= deadline {
            return await end(.deadline, detail: "the deadline passed")
        }
        if let expiry = grantExpiresAt, current >= expiry {
            return await end(.timeBudget, detail: "the unattended session's grant expiry passed")
        }
        let added = budgets.maxDuration.timeInterval * budgets.extensionShare
        let minutes = max(1, Int((added / 60).rounded()))
        let prompt = "The computer-use task on \(manifest.label) has reached its time limit. Continue for another \(minutes) minutes?"
        guard await askToContinue(.time, prompt: prompt) else {
            return await end(.timeBudget, detail: "time ceiling reached")
        }
        timeCeiling = now().addingTimeInterval(added)
        endsAt = [timeCeiling, budgets.deadline, grantExpiresAt].compactMap { $0 }.min() ?? timeCeiling
        events.append(ComputerUseSessionEvent(kind: .timeExtended, at: now(), step: steps, endsAt: endsAt))
    }

    private func ranOutOfSteps() async {
        let share = max(1, Int((Double(lease.budgets.steps) * budgets.extensionShare).rounded(.up)))
        if budgets.steps < budgets.ceilingSteps {
            let since = progressSinceGrant
            guard since.criteriaVerified + since.statesReached > 0 else {
                return await end(.stepBudget, detail: "the step allotment ran out with no progress since the last extension")
            }
            return grant(steps: min(budgets.steps + share, budgets.ceilingSteps))
        }
        let extended = extensions == 0 ? "" : ", extended \(extensions) \(extensions == 1 ? "time" : "times")"
        let prompt = "The computer-use task on \(manifest.label) has used all \(steps) of its steps\(extended). Continue for \(share) more?"
        guard await askToContinue(.steps, prompt: prompt) else {
            return await end(.stepBudget, detail: "step ceiling reached")
        }
        grant(steps: budgets.steps + share)
    }

    private var progressSinceGrant: (criteriaVerified: Int, statesReached: Int) {
        (progress.criteriaVerified - progressAtLastGrant.criteriaVerified, progress.statesReached - progressAtLastGrant.statesReached)
    }

    private func grant(steps allotment: Int) {
        let since = progressSinceGrant
        budgets.steps = allotment
        budgets.ceilingSteps = max(budgets.ceilingSteps, allotment)
        extensions += 1
        progressAtLastGrant = progress
        events.append(ComputerUseSessionEvent(
            kind: .extended,
            at: now(),
            step: steps,
            stepsGranted: allotment,
            criteriaVerified: since.criteriaVerified,
            statesReached: since.statesReached
        ))
    }

    /// Asked one by one only at a ceiling; extensions below it aren't, since asking per extension tires the user
    /// as much as asking per click.
    private func askToContinue(_ limit: ComputerUseCeilingQuestion.Limit, prompt: String) async -> Bool {
        guard lease.userPresent, let oversight else { return false }
        let question = ComputerUseCeilingQuestion(limit: limit, stepsUsed: steps, extensions: extensions, prompt: prompt)
        let yes = await oversight.continuePastCeiling(question)
        events.append(ComputerUseSessionEvent(kind: .ceilingQuestion, at: now(), step: steps, limit: limit, answer: yes ? .continue : .stop))
        return yes && terminalReason == nil
    }

    /// Ends the session and releases the lease. Idempotent.
    public func end(_ reason: ComputerUseTerminalReason = .ended, detail: String? = nil) async {
        guard terminalReason == nil else { return }
        terminalReason = reason
        terminalDetail = detail
        endedAt = now()
        events.append(ComputerUseSessionEvent(
            kind: .ended,
            at: now(),
            step: steps,
            criteriaVerified: progress.criteriaVerified,
            statesReached: progress.statesReached,
            reason: reason
        ))
        let handBack = isTakeoverActive
        isTakeoverActive = false
        // A task of its own: a cancelled caller's requests never reach a remote target, and cleanup must.
        await Task { [target, lease] in
            if handBack { try? await target.takeover(lease, on: false) }
            await target.release(lease, reason: reason.releaseReason)
        }.value
        await report(.ended)
    }

    // MARK: - Oversight

    public func setTakeover(_ on: Bool) async throws {
        if let terminalReason { throw ComputerUseSessionError.ended(terminalReason) }
        guard on != isTakeoverActive else { return }
        try await target.takeover(lease, on: on)
        isTakeoverActive = on
        // What the user does meanwhile is never credited to the agent's last action.
        if on { pendingActing = nil }
        await report(on ? .takenOver : .acting)
    }

    /// Hands the screen back to the agent even when the handoff's caller was cancelled or the target failed: a stuck
    /// takeover would refuse every later action.
    private func endTakeover() async {
        guard isTakeoverActive, terminalReason == nil else { return }
        isTakeoverActive = false
        await Task { [target, lease] in try? await target.takeover(lease, on: false) }.value
        await report(.acting)
    }

    public func askUser(_ question: String) async -> ComputerUseUserReply {
        guard lease.userPresent, terminalReason == nil, let oversight else { return .unavailable }
        return await oversight.askUser(question)
    }

    /// Human-only steps (logins, 2FA, CAPTCHAs, payment entry). Capture and agent input are suspended until the
    /// user hands back, so the model never sees a password being typed.
    public func handoff(reason: ComputerUseHandoffReason, prompt: String) async -> ComputerUseHandoffResult {
        let request = ComputerUseHandoffRequest(reason: reason, prompt: prompt, target: manifest.id)
        guard lease.userPresent, terminalReason == nil, let oversight else {
            unresolvedHandoff = request
            return .unavailable
        }
        do {
            try await setTakeover(true)
        } catch {
            unresolvedHandoff = request
            return .unavailable
        }
        let result = await oversight.handoff(request)
        await endTakeover()
        if case .handedBack = result {
            unresolvedHandoff = nil
        } else {
            unresolvedHandoff = request
        }
        return result
    }

    /// Task criteria without a verification that they are met, in task order.
    public var unverifiedCriteria: [(number: Int, criterion: String)] {
        configuration.task.successCriteria.enumerated().compactMap { index, criterion in
            let met = verifications.last { ComputerUseResultBuilder.criterionMatches($0.criterion, criterion: criterion, index: index) }?.met
            return met == true ? nil : (index + 1, criterion)
        }
    }

    /// One line for the parent: how many actions ran and how they ended.
    public var auditSummary: String {
        let counts = Dictionary(grouping: auditLog, by: \.effect).mapValues(\.count)
        let order: [ActionEffect] = [.confirmed, .unverifiable, .suspectedNoop, .partial, .refused, .notExecuted]
        let parts = order.compactMap { effect in counts[effect].map { "\($0) \(effect.rawValue)" } }
        let noun = auditLog.count == 1 ? "action" : "actions"
        return parts.isEmpty ? "0 actions" : "\(auditLog.count) \(noun): " + parts.joined(separator: ", ")
    }

    public func verify(criterion: String, met: Bool, evidence: String, observation id: ObservationID) throws {
        if let terminalReason { throw ComputerUseSessionError.ended(terminalReason) }
        guard let observation = retained[id] else { throw ComputerUseSessionError.unknownObservation(id) }
        if let lastActionAt, observation.at < lastActionAt { throw ComputerUseSessionError.staleVerification(id) }
        let criteria = configuration.task.successCriteria
        let index = criteria.indices.first { ComputerUseResultBuilder.criterionMatches(criterion, criterion: criteria[$0], index: $0) }
        if index == nil, !criteria.isEmpty { throw ComputerUseSessionError.unknownCriterion(criterion) }
        let metBefore = index.map { index in
            verifications.contains { $0.met && ComputerUseResultBuilder.criterionMatches($0.criterion, criterion: criteria[index], index: index) }
        } ?? true
        verifications.append(ComputerUseVerification(criterion: criterion, met: met, evidence: evidence, observation: id))
        if met, !metBefore {
            progress.criteriaVerified += 1
            progress.lastProgressStep = max(progress.lastProgressStep ?? 0, steps)
            refusedSinceProgress = 0
        }
    }

    // MARK: - Progress

    private static let creditableEffects: Set<ActionEffect> = [.confirmed, .partial, .unverifiable]

    /// A step made progress when the next observation shows a state not seen before and the step acted on the
    /// target without a known failure. Observing and waiting never earn progress, so a page that changes on its
    /// own doesn't count.
    private func noteProgress(after action: ComputerAction, effect: ActionEffect, observation: DisplayObservation?) {
        switch action {
        case .observe:
            defer { pendingActing = nil }
            guard let observation, let state = ComputerUseStateDigest.of(observation), seenStates.insert(state).inserted,
                  let acting = pendingActing, Self.creditableEffects.contains(acting.effect) else { return }
            progress.statesReached += 1
            progress.lastProgressStep = max(progress.lastProgressStep ?? 0, acting.step)
            refusedSinceProgress = 0
            let position = acting.record - (auditCount - auditLog.count)
            if auditLog.indices.contains(position) { auditLog[position].madeProgress = true }
        case .zoom, .wait, .waitFor:
            return
        default:
            pendingActing = (steps, effect, auditCount - 1)
        }
    }

    // MARK: - Helpers

    private func retain(_ observation: DisplayObservation) {
        if retained.updateValue(observation, forKey: observation.id) == nil {
            retainedOrder.append(observation.id)
            keepReplayFrame(of: observation)
        }
        while retainedOrder.count > configuration.retainedObservations {
            let evicted = retainedOrder.removeFirst()
            retained.removeValue(forKey: evicted)
            refs.forget(evicted)
        }
    }

    private static func pointerDestination(of action: ComputerAction) -> DisplayPoint? {
        switch action {
        case .click(let at, _, _, _), .move(let at): return at.point
        case .drag(let path, _): return path.last?.point
        case .scroll(let at?, _, _, _): return at.point
        default: return nil
        }
    }

    private func keepReplayFrame(of observation: DisplayObservation) {
        guard let data = observation.image?.data,
              let image = ComputerUseImageEncoding.thumbnail(
                  of: data,
                  maxEdgePx: configuration.replayThumbnailEdgePx,
                  alt: "Observation \(observation.id)"
              )
        else { return }
        replayFrames.append(ComputerUseReplayFrame(
            observationID: observation.id,
            at: observation.at,
            app: observation.target.app?.bundleID,
            image: image
        ))
        let capacity = max(1, configuration.replayThumbnailCapacity)
        if replayFrames.count > capacity {
            replayFrames.remove(at: capacity > 1 ? 1 : 0)
        }
    }

    private func makeRecord(
        _ action: ComputerAction,
        classification: ComputerUseClassification,
        gate: GateResult
    ) -> ComputerUseActionRecord {
        let canonical = ComputerUseCanonicalForm.describe(action)
        return ComputerUseActionRecord(
            step: steps,
            at: now(),
            kind: action.kind,
            canonical: canonical,
            binding: ComputerUseCanonicalForm.binding(canonical),
            observations: action.citedObservations,
            actionClass: classification.actionClass.label,
            decision: gate.decision,
            reason: gate.reason,
            intentVerdict: gate.intent?.summary,
            effect: .notExecuted,
            evidence: nil
        )
    }

    private func appendAudit(_ record: ComputerUseActionRecord) {
        auditLog.append(record)
        auditCount += 1
        if auditLog.count > configuration.auditCapacity {
            auditLog.removeFirst(auditLog.count - configuration.auditCapacity)
        }
    }

    private func notExecuted(_ indices: Range<Int>, evidence: String) -> [ActionOutcome] {
        indices.map { ActionOutcome(action: $0, effect: .notExecuted, evidence: evidence) }
    }

    private static func needsFocusedApp(_ action: ComputerAction) -> Bool {
        switch action {
        case .type, .key, .hold, .pointer, .scroll, .menu: return true
        default: return false
        }
    }

    private static func isObservation(_ action: ComputerAction) -> Bool {
        switch action {
        case .observe, .zoom, .wait, .waitFor: return true
        default: return false
        }
    }
}

/// The canonical form an approval is bound to: the action, its target refs and observation ids, with typed text
/// replaced by its hash so the audit log never holds what was typed.
enum ComputerUseCanonicalForm {
    static func describe(_ action: ComputerAction) -> String {
        let redacted: ComputerAction
        switch action {
        case .type(let text, let into, let mode):
            redacted = .type(text: hashed(text), into: into, mode: mode)
        case .setValue(let at, let value):
            redacted = .setValue(at: at, value: hashed(value))
        default:
            redacted = action
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(redacted) else { return action.kind.rawValue }
        return "\(action.kind.rawValue) \(String(decoding: data, as: UTF8.self))"
    }

    static func binding(_ canonical: String) -> String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hashed(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest.prefix(16)) len=\(text.count)"
    }
}
