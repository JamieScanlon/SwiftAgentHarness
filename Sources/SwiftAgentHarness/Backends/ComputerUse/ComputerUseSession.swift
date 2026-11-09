import CryptoKit
import EasyJSON
import Foundation

/// What the user asked for. Carried into every intent check and, for the specialist sub-agent, every step.
public struct ComputerUseTaskContext: Sendable {
    public var userRequest: [String]
    /// Carried verbatim; lost constraints are the most common long-horizon failure.
    public var constraints: [String]
    /// Each must be confirmed with `computer_verify`; restated until it is.
    public var successCriteria: [String]
    /// What the specialist's finish result must match, when the task set one.
    public var returnSchema: JSON?

    public init(userRequest: [String], constraints: [String] = [], successCriteria: [String] = [], returnSchema: JSON? = nil) {
        self.userRequest = userRequest
        self.constraints = constraints
        self.successCriteria = successCriteria
        self.returnSchema = returnSchema
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
    /// Draw element refs onto screenshots the model sees, beside the tree that lists them.
    public var labelsScreenshots = true
    /// Whether screenshots reach the model. A model without vision works from the tree, asks `describer` what the
    /// screen shows, and finds points with `grounder`. Screenshots are still taken for them and for approval cards.
    public var showsScreenshots = true
    /// The `vision-describe` role, offered as `computer_describe`.
    public var describer: ComputerUseDescriber?
    /// The `grounder` role, offered as `computer_locate`.
    public var grounder: ComputerUseGrounder?
    /// Replay thumbnails kept per session. Past it, the first and the newest are kept.
    public var replayThumbnailCapacity: Int = 120
    public var replayThumbnailEdgePx: Int = Self.defaultReplayThumbnailEdgePx
    /// Anthropic's native toolset, when the bound model speaks it over Anthropic's API; `nil` uses the harness's
    /// own `computer_*` tools.
    public var nativeDialect: ComputerUseNativeDialect?
    /// For a specialist delegated by another delegate, its path in the delegation tree, shown on its cards.
    public var delegatePath: String?
    /// In watch mode, how long an action waits for the user to open the live view before the session ends.
    /// Stores an approval card's image (PNG bytes) and returns its blob id; without it the image travels inline as
    /// a `data:` URL.
    public var storeApprovalImage: (@Sendable (Data) async -> String?)?
    public var watchModeWait: Duration = .seconds(120)
    /// The current computer-use policy of the modes that apply, read before every action. Only a stricter policy
    /// takes effect mid-session; a looser one waits for the next session.
    public var modePolicy: (@Sendable () async -> ComputerUseModePolicy)?
    /// Confirm every Interact action with the user, as a stricter mode requires. Neither a consistent intent check,
    /// an unshared target, nor the operator's opt-out skips it.
    public var confirmsInteract = false
    public var watchModePollInterval: Duration = .seconds(1)

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

/// What the modes over a computer-use session require of it: the strictest of the delegating conversation's mode and
/// every mode above it.
public struct ComputerUseModePolicy: Sendable, Equatable {
    /// A mode denies the computer-use delegate tool.
    public var denied: Bool
    public var confirmsInteract: Bool

    public init(denied: Bool = false, confirmsInteract: Bool = false) {
        self.denied = denied
        self.confirmsInteract = confirmsInteract
    }
}

public enum ComputerUseTerminalReason: String, Sendable, Codable, Hashable {
    case stepBudget = "step-budget"
    case timeBudget = "time-budget"
    case costBudget = "cost-budget"
    case killSwitch = "kill-switch"
    case permissionRevoked = "permission-revoked"
    /// A mode over the session started denying computer use.
    case policyRevoked = "policy-revoked"
    /// The lease was lost with the holder's connection to a remote target.
    case holderLost = "holder-lost"
    /// Too many consecutive steps without progress.
    case noProgress = "no-progress"
    /// The cutoff the task stated passed.
    case deadline
    /// In watch mode, nobody watched the live view, or the target serves none.
    case liveViewRequired = "live-view-required"
    /// The specialist produced nothing for its idle timeout.
    case idleTimeout = "idle-timeout"
    /// The target can't be used until the user does something at it, such as unlock it or wake its display.
    case targetUnavailable = "target-unavailable"
    /// A question or handoff went unanswered for its timeout.
    case needsUser = "needs-user"
    /// The run was stopped or failed before the session ended on its own.
    case cancelled
    case ended

    var releaseReason: ReleaseReason {
        switch self {
        case .stepBudget, .costBudget: return .budgetExhausted
        case .timeBudget: return .expired
        case .deadline: return .deadline
        case .noProgress: return .noProgress
        case .liveViewRequired, .needsUser, .cancelled: return .cancelled
        case .targetUnavailable: return .targetUnavailable
        case .idleTimeout: return .idleTimeout
        case .killSwitch: return .killSwitch
        case .permissionRevoked: return .permissionRevoked
        case .policyRevoked: return .policyRevoked
        case .holderLost: return .holderLost
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
    /// The vendor's per-action intent: the model's own claim, logged and shown on cards, never used to gate.
    public var statedIntent: String?
}

public struct ComputerUseBatchResult: Sendable {
    public var outcomes: [ActionOutcome]
    public var records: [ComputerUseActionRecord]
    /// Observations produced by this batch, in order.
    public var observations: [DisplayObservation]
    public var terminal: ComputerUseTerminalReason?
    /// Set to `askUser` after repeated failures.
    public var escalation: ActionEscalation?
    /// The user confirmed the call's vendor safety signals, so the vendor may be told they were acknowledged.
    public var signalsAcknowledged = false
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
    case scratchpadTooLong(limit: Int)
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
    /// The user didn't hand back within the handoff's timeout; the session ends with `needs-user`.
    case timedOut
}

public enum ComputerUseUserReply: Sendable, Hashable {
    case answered(String)
    case unavailable
    /// The user didn't answer within the question's timeout; the session ends with `needs-user`.
    case timedOut
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

/// The ceiling a session reached, which a present user decides on with a continue-or-stop card.
public enum ComputerUseCeilingLimit: String, Sendable, Codable, Hashable {
    case steps
    case time
}

/// The surfaces a session reaches a person through for questions and human-only steps.
public protocol ComputerUseOversight: Sendable {
    func askUser(_ question: String) async -> ComputerUseUserReply
    /// Returns once the user hands control back.
    func handoff(_ request: ComputerUseHandoffRequest) async -> ComputerUseHandoffResult
}

/// A session-level entry in the action log: budget extensions, ceiling questions, and how the session ended, with
/// the progress facts behind each.
public struct ComputerUseSessionEvent: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case extended
        case timeExtended = "time-extended"
        case ceilingQuestion = "ceiling-question"
        /// A sensitive-domain signal put the session in watch mode.
        case watchMode = "watch-mode"
        /// The user took over. Nothing is recorded until the takeover ends, since they may be typing a credential.
        case takeoverStarted = "takeover-started"
        case takeoverEnded = "takeover-ended"
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
    public var limit: ComputerUseCeilingLimit?
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
        limit: ComputerUseCeilingLimit? = nil,
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
    /// The model was told to ask the user after repeated failures; failing again before progress ends the session.
    private var askedAfterFailures = false
    /// Actions refused since the last progress. They aren't steps, but they fill the no-progress window.
    private var refusedSinceProgress = 0
    /// Set when a mode over the session started requiring confirmation after the session started.
    private var modeTightenedConfirmsInteract = false
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
    /// Cards waiting on the user, signalled when the session ends.
    private var endWaiters: [String: AsyncStream<Void>.Continuation] = [:]
    private var progressAtLastGrant = ComputerUseProgress()
    private var endedAt: Date?
    /// The time-ceiling decision in flight, so an action and the child run's timer reaching it together ask once.
    private var endTimeDecision: Task<Void, Never>?
    public private(set) var isTakeoverActive = false
    private var targetEvents: Task<Void, Never>?
    private var secrets: Set<String> = []
    private var endsAtObserver: (@Sendable (Date) async -> Void)?
    /// The user's latest keystroke on a shared desktop, as the target reported it.
    private var userTypedAt: Date?
    /// Set by a sensitive-domain signal for the rest of the session: every action then waits until the user
    /// watches the live view.
    public private(set) var isWatchModeOn = false
    /// On a target with no live view, the user confirmed continuing in watch mode.
    private var watchModeConfirmed = false
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
    /// A question the user didn't answer before it timed out or the session was stopped.
    public private(set) var unresolvedQuestion: String?
    private enum AwaitedUser { case question(String), handoff(ComputerUseHandoffRequest) }
    /// What the session is waiting on the user for, so a stop can hand it back to the parent.
    private var awaitingUser: AwaitedUser?
    /// Grants the session's refused actions needed, one per subject at the highest tier asked. Grants can't change
    /// during a run, so the parent has to delegate again with them.
    public private(set) var missingGrants: [ComputerUseGrant] = []
    /// The specialist's own notes, restated in every task reminder so they outlive pruned screenshots.
    public private(set) var scratchpad: String?
    public static let scratchpadLimit = 2_000
    public private(set) var replayFrames: [ComputerUseReplayFrame] = []
    /// Files the lease downloaded, read when the session ended.
    public private(set) var downloads: [DisplayDownload] = []

    /// Downloads the specialist named in its accepted ``finish(result:keepFiles:)``, by resolved path.
    private var keptDownloadPaths: Set<String> = []
    private var finishAttempts = 0
    /// Calls to ``finish(result:keepFiles:)`` allowed: one, and one more after a rejection.
    public static let finishAttemptLimit = 2
    /// The result of the specialist's accepted ``finish(result:keepFiles:)``; `nil` until it commits.
    public private(set) var finishedResult: String?
    public private(set) var hasFinished = false
    /// Why the latest ``finish(result:keepFiles:)`` was rejected, while none has been accepted.
    public private(set) var finishRejection: [String]?

    /// How a ``finish(result:keepFiles:)`` call went. An accepted call may still carry problems: on the last
    /// allowed attempt the call commits anyway, a mismatched result is left out, and refused paths aren't kept.
    public struct FinishOutcome: Sendable, Equatable {
        public var accepted: Bool
        public var problems: [String]
    }

    /// The specialist's single commit: its result, validated against the return schema, and the downloads to keep,
    /// as paths relative to the session's download folder. A first call with problems is rejected so the
    /// specialist can call again; the last allowed one commits whatever is valid.
    public func finish(result: String, keepFiles: [String]) async -> FinishOutcome {
        guard !hasFinished else { return FinishOutcome(accepted: false, problems: ["computer_finish was already accepted"]) }
        finishAttempts += 1
        let (kept, pathProblems) = await resolveKeepFiles(keepFiles)
        let schemaProblems = ComputerUseResultBuilder.reportProblems(result, schema: configuration.task.returnSchema)
            .map { "result \($0)" }
        let problems = pathProblems + schemaProblems
        if !problems.isEmpty, finishAttempts < Self.finishAttemptLimit {
            finishRejection = problems
            return FinishOutcome(accepted: false, problems: problems)
        }
        keptDownloadPaths = kept
        finishedResult = result
        hasFinished = true
        finishRejection = nil
        return FinishOutcome(accepted: true, problems: problems)
    }

    private func resolveKeepFiles(_ requested: [String]) async -> (kept: Set<String>, problems: [String]) {
        guard !requested.isEmpty else { return ([], []) }
        let current = terminalReason == nil ? await target.downloads(lease) : downloads
        guard let folder = current.first.map({ Self.resolved(URL(fileURLWithPath: $0.path).deletingLastPathComponent()) }) else {
            return ([], requested.map { "keep_files \($0): nothing was downloaded in this session" })
        }
        var kept: Set<String> = []
        var problems: [String] = []
        for raw in requested {
            let candidate = Self.resolved(folder.appendingPathComponent(raw))
            guard !raw.hasPrefix("/"), candidate.deletingLastPathComponent().path == folder.path else {
                problems.append("keep_files \(raw): not a path inside the download folder")
                continue
            }
            guard current.contains(where: { Self.resolved(URL(fileURLWithPath: $0.path)).path == candidate.path }) else {
                problems.append("keep_files \(raw): nothing was downloaded by that name")
                continue
            }
            kept.insert(candidate.path)
        }
        return (kept, problems)
    }

    /// Lists every download once the session ended. A managed browser's files are deleted unless the specialist's
    /// finish named them, and named ones move to the attachment `move` returns. The user's browser's files all stay
    /// where they are, and named ones are also copied. A file over `attachmentLimit` bytes isn't copied: a managed
    /// browser's stays in its folder instead.
    public func finalizeDownloads(
        attachmentLimit: Int? = nil,
        moving move: (@Sendable (DisplayDownload, Data) async -> String?)?
    ) async -> [ComputerUseResult.Download] {
        var listed: [ComputerUseResult.Download] = []
        for download in downloads {
            let url = URL(fileURLWithPath: download.path)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: download.path))?[.size] as? NSNumber)?.intValue ?? 0
            let named = keptDownloadPaths.contains(Self.resolved(url).path)
            let kept = !download.disposable || named
            var entry = ComputerUseResult.Download(name: download.name, bytes: bytes, kept: kept)
            if named, download.completed, bytes <= attachmentLimit ?? .max, let move, let data = try? Data(contentsOf: url) {
                entry.attachment = await move(download, data)
            }
            if download.disposable, !kept || entry.attachment != nil {
                try? FileManager.default.removeItem(at: url)
            }
            listed.append(entry)
        }
        if let folder = downloads.first.map({ URL(fileURLWithPath: $0.path).deletingLastPathComponent() }),
           (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
        return listed
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The observation the latest targeted action cited; its app is where untargeted input goes.
    private var lastCitedObservation: ObservationID?
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
    ///
    /// - Parameters:
    ///   - safetySignals: Vendor signals on single actions, by index.
    ///   - callSignals: Vendor signals on the whole call. The user confirms the call once, on a card listing its
    ///     actions, before the first one runs.
    ///   - intents: The vendor's per-action intent, by index: logged and shown on cards as the model's claim.
    public func perform(
        _ actions: [ComputerAction],
        safetySignals: [Int: [ComputerUseSafetySignal]] = [:],
        callSignals: [ComputerUseSafetySignal] = [],
        intents: [Int: String] = [:]
    ) async -> ComputerUseBatchResult {
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
        if let typed = userTypedAt, now().timeIntervalSince(typed) < Self.userTypingQuiet,
           actions.contains(where: { !Self.isObservation($0) }) {
            result.outcomes = actions.indices.map {
                $0 == 0
                    ? ActionOutcome(action: 0, effect: .notExecuted, evidence: "the user is typing on this desktop; wait until they stop, then observe", escalation: .observe)
                    : ActionOutcome(action: $0, effect: .notExecuted)
            }
            return result
        }
        if !callSignals.isEmpty {
            noteSignals(callSignals)
            if isWatchModeOn, !(await waitForWatcher()) {
                let reason = terminalReason?.rawValue ?? ComputerUseTerminalReason.liveViewRequired.rawValue
                result.outcomes = notExecuted(actions.indices, evidence: "session ended: \(reason)")
                result.terminal = terminalReason
                return result
            }
            if let refusal = await confirmCall(actions, signals: callSignals, intents: intents) {
                result.outcomes = actions.indices.map {
                    $0 == 0 ? ActionOutcome(action: 0, effect: .refused, evidence: refusal, escalation: .askUser) : ActionOutcome(action: $0, effect: .notExecuted)
                }
                refusedSinceProgress += 1
                await endIfNotProgressing()
                result.terminal = terminalReason
                return result
            }
            result.signalsAcknowledged = true
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
            let signals = safetySignals[index] ?? []
            noteSignals(signals)
            if isWatchModeOn, !(await waitForWatcher()) {
                let reason = terminalReason?.rawValue ?? ComputerUseTerminalReason.liveViewRequired.rawValue
                result.outcomes.append(ActionOutcome(action: index, effect: .notExecuted, evidence: "session ended: \(reason)"))
                stopped = true
                continue
            }
            let (outcome, record, observation) = await performOne(action, index: index, signals: signals, statedIntent: intents[index])
            result.outcomes.append(outcome)
            result.records.append(record)
            if let observation { result.observations.append(observation) }
            if outcome.effect.stopsBatch || outcome.escalation == .observe { stopped = true }
        }

        let failed = result.outcomes.contains { $0.effect == .refused || $0.effect == .suspectedNoop || $0.effect == .partial }
        consecutiveFailures = failed ? consecutiveFailures + 1 : 0
        if consecutiveFailures >= configuration.maxConsecutiveFailures, terminalReason == nil {
            if askedAfterFailures {
                await end(.noProgress, detail: "\(consecutiveFailures) failing batches in a row again after the user was asked")
            } else {
                result.escalation = .askUser
                askedAfterFailures = true
            }
        }
        result.terminal = terminalReason
        return result
    }

    /// Polls fresh observations until the condition holds; only the last is retained. A condition the target can't
    /// show is a bounded wait followed by an observation, and the evidence says so.
    private func waitFor(_ condition: WaitCondition, timeoutMilliseconds: Int, index: Int) async throws -> (ActionOutcome, DisplayObservation?) {
        if case .window(_, let app, _) = condition {
            return try await waitForWindow(condition, app: app, timeoutMilliseconds: timeoutMilliseconds, index: index)
        }
        var request = ComputerUseWaitEvaluator.observeRequest(for: condition, manifest: manifest)
        request.maxImage = configuration.imageLimit
        var result = ComputerUseWaitEvaluator.modes(for: condition, manifest: manifest)
        if result == nil {
            var reference: ElementRef?
            switch condition {
            case .element(_, _, _, let ref?), .value(_, let ref, _):
                reference = latestObservation?.element(ref)
                guard reference != nil else {
                    return (ActionOutcome(action: index, effect: .refused, evidence: "\(ref) is not in the latest observation; observe and cite a current ref", escalation: .observe), nil)
                }
            default:
                break
            }
            result = try await ComputerUseWaitEvaluator.wait(for: condition, timeoutMilliseconds: timeoutMilliseconds, reference: reference) {
                [target, lease, request] in try await target.observe(lease, request)
            }
        }
        switch result {
        case .met(let observation, let elapsed)?:
            let kept = retainFresh(observation)
            return (ActionOutcome(action: index, effect: .confirmed, evidence: "\(condition.summary) after \(elapsed) ms", observation: kept.id), kept)
        case .timedOut(let observation)?:
            let kept = observation.map(retainFresh)
            return (ActionOutcome(action: index, effect: .partial, evidence: "\(condition.summary) did not happen within \(timeoutMilliseconds) ms", observation: kept?.id), kept)
        case .unevaluable(let why)?:
            try await Task.sleep(for: .milliseconds(min(timeoutMilliseconds, 10_000)))
            let kept = retainFresh(try await target.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil), maxImage: configuration.imageLimit)))
            return (ActionOutcome(
                action: index,
                effect: .unverifiable,
                evidence: "can't evaluate \(condition.summary) here (\(why)); waited \(min(timeoutMilliseconds, 10_000)) ms and observed",
                observation: kept.id
            ), kept)
        case nil:
            return (ActionOutcome(action: index, effect: .unverifiable, evidence: "nothing to wait for"), nil)
        }
    }

    /// Window conditions are checked against the target's window list, then one observation shows the result.
    private func waitForWindow(_ condition: WaitCondition, app: String, timeoutMilliseconds: Int, index: Int) async throws -> (ActionOutcome, DisplayObservation?) {
        guard grants.tier(forApp: app) != nil else {
            return (ActionOutcome(action: index, effect: .refused, evidence: "\(app) isn't granted, so its windows aren't listed"), nil)
        }
        let waited = try await ComputerUseWaitEvaluator.waitForWindow(condition, timeoutMilliseconds: timeoutMilliseconds) {
            [target, lease] in try await target.describe(lease)
        }
        guard let waited else {
            let bounded = min(timeoutMilliseconds, 10_000)
            try await Task.sleep(for: .milliseconds(bounded))
            let kept = retainFresh(try await target.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil), maxImage: configuration.imageLimit)))
            return (ActionOutcome(
                action: index,
                effect: .unverifiable,
                evidence: "can't evaluate \(condition.summary) here (\(manifest.label) doesn't list windows); waited \(bounded) ms and observed",
                observation: kept.id
            ), kept)
        }
        var request = ComputerUseWaitEvaluator.observeRequest(for: condition, manifest: manifest)
        request.maxImage = configuration.imageLimit
        let kept = retainFresh(try await target.observe(lease, request))
        let evidence = waited.met
            ? "\(condition.summary) after \(waited.afterMilliseconds) ms"
            : "\(condition.summary) did not happen within \(timeoutMilliseconds) ms"
        return (ActionOutcome(action: index, effect: waited.met ? .confirmed : .partial, evidence: evidence, observation: kept.id), kept)
    }

    private static func sameDocument(_ base: DisplayObservation, _ current: DisplayObservation) -> Bool {
        func page(_ url: String?) -> String? {
            guard let url, var components = URLComponents(string: url) else { return url }
            components.fragment = nil
            components.query = nil
            return components.string
        }
        return base.target.app == current.target.app && base.target.windowID == current.target.windowID
            && page(base.target.url) == page(current.target.url)
    }

    private func retainFresh(_ observation: DisplayObservation) -> DisplayObservation {
        let stable = refs.stabilize(observation)
        retain(stable)
        return stable
    }

    /// Password and one-time-code fields, whose values are secrets.
    private func isSecretField(_ element: ElementRef) -> Bool {
        if element.isSecureInput { return true }
        guard let purpose = element.inputPurpose?.lowercased() else { return false }
        let classifier = configuration.classifier
        return classifier.secureInputPurposes.contains(purpose) || classifier.secureInputPurposePrefixes.contains(where: purpose.hasPrefix)
    }

    /// Values redacted from every helper model's input: what password and one-time-code fields held or were given,
    /// and what the user typed during a takeover.
    public func knownSecrets() -> [String] {
        Array(secrets)
    }

    /// Records the text of an action that types into a secret field.
    private func noteSecretInput(_ action: ComputerAction) {
        let typed: (String, ActionTarget?)? = switch action {
        case .type(let text, let into, _): (text, into)
        case .setValue(let at, let value): (value, at)
        default: nil
        }
        guard let (text, target) = typed, !text.isEmpty, let target, let ref = target.elementRef,
              let field = retained[target.observation]?.tree?.elements[ref], isSecretField(field)
        else { return }
        secrets.insert(text)
    }

    private func noteSignals(_ signals: [ComputerUseSafetySignal]) {
        guard signals.contains(.sensitiveDomain), !isWatchModeOn else { return }
        isWatchModeOn = true
        events.append(ComputerUseSessionEvent(kind: .watchMode, at: now(), step: steps))
    }

    /// One card for a call a vendor flagged as a whole, listing its actions. `nil` when the user confirmed; otherwise
    /// why the call doesn't run.
    private func confirmCall(_ actions: [ComputerAction], signals: [ComputerUseSafetySignal], intents: [Int: String]) async -> String? {
        let why = signals.map { "vendor safety signal: \($0.rawValue)" }.joined(separator: "; ")
        guard lease.userPresent else { return "headlessDenied: \(why)" }
        guard approvals != nil else { return "no approval surface for: \(why)" }
        let canonical = actions.map(ComputerUseCanonicalForm.describe)
        var context = ["Why confirm: \(why)", "Actions:"]
        if let delegatePath = configuration.delegatePath { context.insert("Asked by: \(delegatePath)", at: 1) }
        for (index, form) in canonical.enumerated() {
            context.append("\(index + 1). \(form)")
            if let intent = intents[index] { context.append("   Model's stated intent (unverified): \(intent)") }
        }
        let title = "Computer use: confirm a flagged call on \(manifest.label)"
        let request = ExecApprovalRequest(
            id: "computer-use-call-\(UUID().uuidString.prefix(8))",
            command: canonical.joined(separator: "; "),
            title: title,
            description: context.joined(separator: "\n"),
            allowsDurableBypass: false,
            presentation: .standard(title: title, context: context, buttons: [
                ApprovalButton(id: ApprovalDecision.allowOnce.rawValue, label: "Allow these actions", style: .primary),
                ApprovalButton(id: ApprovalDecision.deny.rawValue, label: "Deny", style: .danger),
            ])
        )
        switch await requestApproval(request) ?? .denied("the session ended") {
        case .approved:
            return terminalReason == nil && !isTakeoverActive ? nil : "the session changed while awaiting approval"
        case .denied(let message): return "denied by the user: \(message)"
        case .headlessDenied(let message): return "headlessDenied: \(message)"
        case .deferred(let message): return "approval deferred: \(message)"
        }
    }

    private func performOne(
        _ action: ComputerAction,
        index: Int,
        signals: [ComputerUseSafetySignal],
        statedIntent: String?
    ) async -> (ActionOutcome, ComputerUseActionRecord, DisplayObservation?) {
        let untargeted = action.citedTargets.isEmpty && Self.needsFocusedApp(action)
        let layout = untargeted ? try? await target.describe(lease) : nil
        // Untargeted input goes to the working app: the app of the most recently cited observation, never the
        // frontmost app just because it is frontmost.
        let workingApp = lastCitedObservation.flatMap { retained[$0]?.target.app } ?? layout?.focusedApp
        let classification = configuration.classifier.classify(
            action,
            context: ComputerUseClassificationContext(
                grants: grants,
                observation: { [retained] in retained[$0] },
                focusedApp: workingApp,
                focusedURL: layout?.tabs.first(where: \.isActive)?.url,
                safetySignals: signals,
                sharedTarget: manifest.humanPresence == .shared,
                latestObservation: latestObservation
            )
        )
        if let cited = action.citedObservations.last { lastCitedObservation = cited }
        noteSecretInput(action)
        let gate = await gate(classification, action: action, statedIntent: statedIntent)
        var record = makeRecord(action, classification: classification, gate: gate)
        record.statedIntent = statedIntent

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
                    let base = retained[diffBase]
                    let sameDocument = base.map { Self.sameDocument($0, observation) } ?? true
                    let text = base?.tree.map {
                        ComputerUseTreeDiff.render(base: $0, baseID: diffBase, current: current, sameDocument: sameDocument)
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
            case .waitFor(let condition, let timeout):
                (outcome, produced) = try await waitFor(condition, timeoutMilliseconds: timeout, index: index)
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
        } catch DisplayTargetError.targetUnavailable(let reason) {
            // Retrying can't help until the user acts at the target, so the run ends with the reason.
            outcome = ActionOutcome(action: index, effect: .refused, evidence: reason)
            await end(.targetUnavailable, detail: reason)
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

    /// Announces the session to the user's surfaces and starts listening to the target's events.
    public func announceStart() async {
        await listenToTarget()
        await report(.started)
    }

    /// Called with the new end time whenever a present user moves the time ceiling.
    public func observeEndsAt(_ observer: @escaping @Sendable (Date) async -> Void) {
        endsAtObserver = observer
    }

    /// How long after the user's last keystroke on a shared desktop the agent's input waits.
    public static let userTypingQuiet: TimeInterval = 2

    private func listenToTarget() async {
        guard targetEvents == nil, terminalReason == nil else { return }
        // Subscribed before returning, so no event sent after the announcement is missed.
        let stream = await target.events(lease)
        guard targetEvents == nil else { return }
        targetEvents = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: DisplayTargetEvent) async {
        guard terminalReason == nil else { return }
        switch event {
        case .stopRequested:
            await end(.killSwitch)
        case .permissionsChanged(let snapshot):
            if !snapshot.missing(manifest.requires).isEmpty { await end(.permissionRevoked) }
        case .takeoverChanged(let on):
            guard on != isTakeoverActive else { return }
            markTakeover(on)
            if on { pendingActing = nil }
            await report(on ? .takenOver : .acting)
        case .userTyping:
            userTypedAt = now()
        case .typedDuringTakeover(let value):
            secrets.insert(value)
        case .leaseEnded(let reason):
            switch reason {
            case .killSwitch: await end(.killSwitch, detail: "the user pressed stop while the target was unreachable")
            case .permissionRevoked: await end(.permissionRevoked)
            default: await end(.holderLost)
            }
        }
    }

    // MARK: - Gating

    private struct GateResult {
        var decision: ComputerUseGateDecision
        var reason: String
        var escalation: ActionEscalation?
        var intent: ComputerUseIntentVerdict?
    }

    private func gate(_ classification: ComputerUseClassification, action: ComputerAction, statedIntent: String?) async -> GateResult {
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
            if configuration.confirmsInteract || modeTightenedConfirmsInteract {
                var reasons = ["this conversation's mode requires confirming every interact action"]
                if case .confirm(let reason, _)? = intent { reasons.append(reason) }
                return await confirm(classification, action: action, reasons: reasons, intent: intent, statedIntent: statedIntent)
            }
            switch intent {
            case .consistent?:
                return GateResult(decision: .allowed, reason: "interact within grant; intent consistent", intent: intent)
            case .confirm(let reason, _)?:
                return await confirm(classification, action: action, reasons: [reason], intent: intent, statedIntent: statedIntent)
            case .unbound?, nil:
                let skip = configuration.classifier.reviewer.overrides.skipInteractConfirmationWithoutIntentCheck
                if manifest.humanPresence == .shared && !skip {
                    return await confirm(
                        classification,
                        action: action,
                        reasons: ["no intent checker is bound and a person may be using this screen"],
                        intent: intent,
                        statedIntent: statedIntent
                    )
                }
                return GateResult(decision: .allowed, reason: "interact within grant", intent: intent)
            }
        case .consequential(let reasons):
            let intent = await checkIntent(classification)
            return await confirm(classification, action: action, reasons: reasons, intent: intent, statedIntent: statedIntent)
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
        intent: ComputerUseIntentVerdict?,
        statedIntent: String?
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
        var request = Self.approvalRequest(
            id: "computer-use-\(binding.prefix(16))-\(UUID().uuidString.prefix(8))",
            canonical: canonical,
            classification: classification,
            target: manifest,
            reasons: reasons,
            intent: intent,
            action: action,
            observation: action.citedObservations.first.flatMap(observation),
            statedIntent: statedIntent,
            delegatePath: configuration.delegatePath
        )
        await storeImages(in: &request)
        switch await requestApproval(request) ?? .denied("the session ended") {
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
        observation: DisplayObservation? = nil,
        statedIntent: String? = nil,
        delegatePath: String? = nil
    ) -> ExecApprovalRequest {
        var location = classification.domain ?? classification.app?.bundleID ?? target.label
        if classification.domain != nil, let app = classification.app?.bundleID { location += " (\(app))" }
        var element = classification.element?.role ?? "—"
        if let label = classification.element?.label, !label.isEmpty { element += " \"\(label)\"" }
        let title = "Computer use: confirm \(classification.kind.rawValue) on \(target.label)"
        var context = [
            "Action: \(canonical)",
            "Target: \(element) in \(location)",
            "Why confirm: \(reasons.joined(separator: "; "))",
            "Intent check: \(intent?.summary ?? "not run")",
        ]
        if let statedIntent { context.append("Model's stated intent (unverified): \(statedIntent)") }
        if let delegatePath { context.append("Asked by: \(delegatePath)") }
        // The command keeps only the script's hash, so the card shows the whole script to review.
        if case .script(let language, let source, _)? = action {
            context.append("Script (\(language.rawValue)):\n\(source)")
        }
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
           let crop = ComputerUseTargetCrop.image(of: region, in: observation, alt: Self.approvalImageAlt(classification, target: target)) {
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

    /// Moves the card's inline images into the blob store, so the card carries refs.
    private func storeImages(in request: inout ExecApprovalRequest) async {
        guard let store = configuration.storeApprovalImage else { return }
        var presentation = request.presentation
        var stored = false
        for (index, block) in presentation.blocks.enumerated() {
            guard case .image(var image) = block, let data = image.inlineData, let ref = await store(data) else { continue }
            image.ref = ref
            presentation.blocks[index] = .image(image)
            stored = true
        }
        guard stored else { return }
        request = ExecApprovalRequest(
            id: request.id,
            command: request.command,
            title: request.title,
            description: request.description,
            allowsDurableBypass: request.allowsDurableBypass,
            presentation: presentation
        )
    }

    /// The action in words, for surfaces that show only the alt text: "Click "Pay now" in Safari, checkout.example.com".
    static func approvalImageAlt(_ classification: ComputerUseClassification, target: DisplayTargetManifest) -> String {
        var what = classification.kind.rawValue.prefix(1).uppercased() + classification.kind.rawValue.dropFirst()
        if let element = classification.element {
            what += element.label.map { " \"\($0)\"" } ?? " the \(element.role)"
        }
        let place = [classification.app?.bundleID ?? target.label, classification.domain].compactMap { $0 }.joined(separator: ", ")
        return "\(what) in \(place)"
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
        await applyStricterModePolicy()
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

    /// A mode change that tightens computer use reaches the session at its next action and stays for the rest of it.
    private func applyStricterModePolicy() async {
        guard let policy = await configuration.modePolicy?() else { return }
        if policy.confirmsInteract { modeTightenedConfirmsInteract = true }
        if policy.denied {
            await end(.policyRevoked, detail: "a conversation's mode now denies computer use")
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
        timeCeiling = timeCeiling.addingTimeInterval(added)
        endsAt = [timeCeiling, budgets.deadline, grantExpiresAt].compactMap { $0 }.min() ?? timeCeiling
        events.append(ComputerUseSessionEvent(kind: .timeExtended, at: now(), step: steps, endsAt: endsAt))
        await endsAtObserver?(endsAt)
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
    /// as much as asking per click. A continue-or-stop card, so the answer needs no parsing; a card that times out
    /// is a stop.
    private func askToContinue(_ limit: ComputerUseCeilingLimit, prompt: String) async -> Bool {
        guard lease.userPresent, approvals != nil else { return false }
        let title = "Computer use: continue past the \(limit.rawValue) ceiling on \(manifest.label)?"
        let request = ExecApprovalRequest(
            id: "computer-use-ceiling-\(UUID().uuidString.prefix(8))",
            command: "continue past the \(limit.rawValue) ceiling",
            title: title,
            description: prompt,
            allowsDurableBypass: false,
            presentation: .standard(title: title, context: [prompt], buttons: [
                ApprovalButton(id: ApprovalDecision.allowOnce.rawValue, label: "Continue", style: .primary),
                ApprovalButton(id: ApprovalDecision.deny.rawValue, label: "Stop", style: .danger),
            ])
        )
        let yes = await requestApproval(request) == .approved
        events.append(ComputerUseSessionEvent(kind: .ceilingQuestion, at: now(), step: steps, limit: limit, answer: yes ? .continue : .stop))
        return yes && terminalReason == nil
    }

    /// A card for the user, withdrawn when the session ends first: ``end(_:detail:)`` answers every card still
    /// waiting, so a stopped session's cards don't outlive it.
    private func requestApproval(_ request: ExecApprovalRequest) async -> ExecApprovalDeliveryResult? {
        guard let approvals, terminalReason == nil else { return nil }
        let id = request.id
        let (ended, endSignal) = AsyncStream.makeStream(of: Void.self)
        endWaiters[id] = endSignal
        defer { endWaiters[id] = nil }
        return await withTaskGroup(of: ExecApprovalDeliveryResult?.self) { group in
            group.addTask { await approvals.requestApproval(request, headless: false) }
            group.addTask {
                for await _ in ended { return nil }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { await approvals.sendFollowup(approvalID: id, approved: false) }
            return first
        }
    }

    /// Ends the session and releases the lease. Idempotent.
    public func end(_ reason: ComputerUseTerminalReason = .ended, detail: String? = nil) async {
        guard terminalReason == nil else { return }
        let handBack = isTakeoverActive
        if handBack { markTakeover(false) }
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
        for waiter in endWaiters.values { waiter.finish() }
        targetEvents?.cancel()
        switch awaitingUser {
        case .question(let question)?: unresolvedQuestion = question
        case .handoff(let request)?: unresolvedHandoff = request
        case nil: break
        }
        // A task of its own: a cancelled caller's requests never reach a remote target, and cleanup must.
        downloads = await Task { [target, lease] in
            if handBack { try? await target.takeover(lease, on: false) }
            let downloads = await target.downloads(lease)
            await target.release(lease, reason: reason.releaseReason)
            return downloads
        }.value
        await report(.ended)
    }

    // MARK: - Watch mode

    /// Whether someone watches the live view, waiting up to ``ComputerUseSessionConfiguration/watchModeWait`` for a
    /// viewer to connect. On a target with no live view, a present user confirms on a card instead, and so they do on
    /// someone's own screen when nobody watches its view, since the user may be at it. Ends the session when nobody
    /// can or does.
    private func waitForWatcher() async -> Bool {
        let rule = "after a sensitive-domain signal the session continues only while someone watches its live view"
        guard lease.userPresent else {
            await end(.liveViewRequired, detail: "\(rule), and nobody is present")
            return false
        }
        let servesLiveView = manifest.observerAccess != .none
        if servesLiveView, await isWatched() { return true }
        guard servesLiveView, manifest.humanPresence != .shared else {
            if watchModeConfirmed { return true }
            if await confirmWatchMode() {
                watchModeConfirmed = true
                return true
            }
            let why = servesLiveView ? "nobody watched its live view" : "it serves no live view"
            await end(.liveViewRequired, detail: "a sensitive-domain signal needs the user's confirmation on \(manifest.label), since \(why), and the user didn't give it")
            return false
        }
        await report(.waitingForLiveView)
        let deadline = ContinuousClock.now.advanced(by: configuration.watchModeWait)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: configuration.watchModePollInterval)
            guard terminalReason == nil, !Task.isCancelled else { return false }
            if await isWatched() {
                await report(.acting)
                return true
            }
        }
        await end(.liveViewRequired, detail: "\(rule), and nobody opened it")
        return false
    }

    private func confirmWatchMode() async -> Bool {
        let title = "Computer use: continue on a sensitive page on \(manifest.label)?"
        let detail = manifest.observerAccess == .none
            ? "The vendor flagged this page as sensitive. \(manifest.label) has no live view to watch, so the agent continues only if you confirm."
            : "The vendor flagged this page as sensitive. Nobody is watching \(manifest.label)'s live view, so the agent continues only if you confirm."
        let request = ExecApprovalRequest(
            id: "computer-use-watch-\(UUID().uuidString.prefix(8))",
            command: "continue in watch mode",
            title: title,
            description: detail,
            allowsDurableBypass: false,
            presentation: .standard(title: title, context: [detail], buttons: [
                ApprovalButton(id: ApprovalDecision.allowOnce.rawValue, label: "Continue", style: .primary),
                ApprovalButton(id: ApprovalDecision.deny.rawValue, label: "Stop", style: .danger),
            ])
        )
        return await requestApproval(request) == .approved
    }

    private func isWatched() async -> Bool {
        ((try? await target.liveViewers(lease)) ?? 0) > 0
    }

    // MARK: - Oversight

    /// A link to watch the target: for the user, who also controls it through the link during takeover, or for an
    /// observer, who only watches. `nil` when the target serves none.
    public func liveView(role: DisplayLiveViewRole = .user) async throws -> DisplayLiveView? {
        if let terminalReason { throw ComputerUseSessionError.ended(terminalReason) }
        return try await target.liveView(lease, role: role)
    }

    /// Ends every observer's stream and revokes the observer links.
    public func endObservers() async throws {
        if let terminalReason { throw ComputerUseSessionError.ended(terminalReason) }
        try await target.endObservers(lease)
    }

    /// Who is connected to the live view, under their links' ids.
    public func liveConnections() async throws -> [DisplayLiveViewConnection] {
        if let terminalReason { throw ComputerUseSessionError.ended(terminalReason) }
        return try await target.liveConnections(lease)
    }

    /// Ends one live-view connection, or revokes its link if it hasn't connected. `false` when there is none.
    public func revokeLiveView(_ id: UUID) async throws -> Bool {
        if let terminalReason { throw ComputerUseSessionError.ended(terminalReason) }
        return try await target.revokeLiveView(lease, id: id)
    }

    public func setTakeover(_ on: Bool) async throws {
        if let terminalReason { throw ComputerUseSessionError.ended(terminalReason) }
        guard on != isTakeoverActive else { return }
        try await target.takeover(lease, on: on)
        markTakeover(on)
        // What the user does meanwhile is never credited to the agent's last action.
        if on { pendingActing = nil }
        await report(on ? .takenOver : .acting)
    }

    /// Hands the screen back to the agent even when the handoff's caller was cancelled or the target failed: a stuck
    /// takeover would refuse every later action.
    private func endTakeover() async {
        guard isTakeoverActive, terminalReason == nil else { return }
        markTakeover(false)
        await Task { [target, lease] in try? await target.takeover(lease, on: false) }.value
        await report(.acting)
    }

    public func askUser(_ question: String) async -> ComputerUseUserReply {
        guard lease.userPresent, terminalReason == nil, let oversight else { return .unavailable }
        awaitingUser = .question(question)
        let reply = await oversight.askUser(question)
        awaitingUser = nil
        switch reply {
        case .answered:
            // The user's answer is the response to the failure escalation.
            consecutiveFailures = 0
        case .timedOut:
            unresolvedQuestion = question
            await end(.needsUser, detail: "the user didn't answer the specialist's question")
        case .unavailable:
            break
        }
        return reply
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
        awaitingUser = .handoff(request)
        let result = await oversight.handoff(request)
        awaitingUser = nil
        await endTakeover()
        if case .handedBack = result {
            unresolvedHandoff = nil
        } else {
            unresolvedHandoff = request
        }
        if case .timedOut = result {
            await end(.needsUser, detail: "the user didn't hand back control")
        }
        return result
    }

    /// Replaces the notes; blank notes clear them. Notes are not actions and take no step.
    public func setScratchpad(_ notes: String) throws(ComputerUseSessionError) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.scratchpadLimit else { throw .scratchpadTooLong(limit: Self.scratchpadLimit) }
        scratchpad = trimmed.isEmpty ? nil : trimmed
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
            askedAfterFailures = false
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
            askedAfterFailures = false
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
        for element in observation.tree?.elements.values ?? [:].values where isSecretField(element) {
            if let value = element.value, !value.isEmpty { secrets.insert(value) }
        }
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

    /// Takeover starts and ends are marked in the events, so a replay shows where its frames stop.
    private func markTakeover(_ on: Bool) {
        isTakeoverActive = on
        events.append(ComputerUseSessionEvent(kind: on ? .takeoverStarted : .takeoverEnded, at: now(), step: steps))
    }

    private func keepReplayFrame(of observation: DisplayObservation) {
        // An observation that returns after a takeover began may show the user typing a credential.
        guard !isTakeoverActive, let data = observation.image?.data,
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
        case .type, .key, .hold, .pointer, .scroll, .menu, .script: return true
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
        case .script(let language, let source, let timeout):
            redacted = .script(language: language, source: hashed(source), timeoutMilliseconds: timeout)
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
