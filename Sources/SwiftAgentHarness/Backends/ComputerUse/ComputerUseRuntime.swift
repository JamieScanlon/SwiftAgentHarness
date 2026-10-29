import Foundation
import Synchronization

/// How the computer-use specialist sub-agent runs.
public struct ComputerUseSpecialistProfile: Sendable {
    /// Mode profile the child runs under; its tool surface is narrowed to the computer-use family regardless.
    public var modeProfileID: String
    /// The `computer-use` role binding. `nil` uses the parent conversation's model when it can see images and
    /// call tools.
    public var modelRef: String?
    /// Wall-clock ceiling for one specialist run, on top of the task's own time budget.
    public var runTimeoutSeconds: TimeInterval

    public init(modeProfileID: String = "subagent-computer-use", modelRef: String? = nil, runTimeoutSeconds: TimeInterval = 1_800) {
        self.modeProfileID = modeProfileID
        self.modelRef = modelRef
        self.runTimeoutSeconds = runTimeoutSeconds
    }
}

/// Everything a host supplies to turn computer use on. Install it with
/// ``HarnessRuntimeSession/installComputerUse(_:)``.
public struct ComputerUseConfiguration: Sendable {
    public var registry: DisplayTargetRegistry
    public var defaults: ComputerUseSpecialistDefaults
    /// Shows the one start-of-session grant dialog.
    public var approveGrants: ComputerUseGrantApprover
    /// Per-action confirmation cards for consequential actions.
    public var approvals: (any ExecApprovalDelivering)?
    public var intentChecker: ComputerUseIntentChecker?
    public var oversight: (any ComputerUseOversight)?
    /// In-process observer of every specialist's activity, such as the host's "agent active" HUD. Surfaces get
    /// the same updates as `computerUseActivity` intents on the user's conversation.
    public var activityObserver: (@Sendable (ComputerUseSurfaceIntentPayload) async -> Void)?
    public var retention: ComputerUseRetention
    public var specialist: ComputerUseSpecialistProfile

    public init(
        registry: DisplayTargetRegistry,
        defaults: ComputerUseSpecialistDefaults,
        approveGrants: @escaping ComputerUseGrantApprover,
        approvals: (any ExecApprovalDelivering)? = nil,
        intentChecker: ComputerUseIntentChecker? = nil,
        oversight: (any ComputerUseOversight)? = nil,
        activityObserver: (@Sendable (ComputerUseSurfaceIntentPayload) async -> Void)? = nil,
        retention: ComputerUseRetention = ComputerUseRetention(),
        specialist: ComputerUseSpecialistProfile = ComputerUseSpecialistProfile()
    ) {
        self.registry = registry
        self.defaults = defaults
        self.approveGrants = approveGrants
        self.approvals = approvals
        self.intentChecker = intentChecker
        self.oversight = oversight
        self.activityObserver = activityObserver
        self.retention = retention
        self.specialist = specialist
    }
}

/// One live specialist session and the user's conversation it reports to.
struct ComputerUseSessionEntry: Sendable {
    var session: ComputerUseSession
    var parentConversationID: UUID
    var lifecycleID: String
    var targetLabel: String
}

/// Live specialist sessions, keyed by the child conversation that drives them.
actor ComputerUseSessionDirectory {
    private var entries: [UUID: ComputerUseSessionEntry] = [:]

    func register(_ entry: ComputerUseSessionEntry, for conversationID: UUID) {
        entries[conversationID] = entry
    }

    func session(for conversationID: UUID) -> ComputerUseSession? {
        entries[conversationID]?.session
    }

    func remove(for conversationID: UUID) {
        entries.removeValue(forKey: conversationID)
    }

    var all: [ComputerUseSession] {
        entries.values.map(\.session)
    }

    /// Sessions working for a user's conversation.
    func entries(parent conversationID: UUID) -> [ComputerUseSessionEntry] {
        entries.values.filter { $0.parentConversationID == conversationID }.sorted { $0.lifecycleID < $1.lifecycleID }
    }
}

/// The host's computer-use configuration, shared by tool building, delegate dispatch, and the control plane.
final class ComputerUseInstallation: Sendable {
    private let state = Mutex<ComputerUseConfiguration?>(nil)
    private let coordinatorState = Mutex<ComputerUseOversightCoordinator?>(nil)
    private let publishState = Mutex<ComputerUseOversightCoordinator.Publish?>(nil)
    let sessions = ComputerUseSessionDirectory()
    let replays = ComputerUseReplayIndex()
    let blobs = ComputerUseBlobLedger()
    let nativeFailures = ComputerUseNativeFailures()

    init() {}

    var configuration: ComputerUseConfiguration? {
        state.withLock { $0 }
    }

    /// Questions and handoffs routed to the user's surfaces; set when computer use is installed.
    var coordinator: ComputerUseOversightCoordinator? {
        coordinatorState.withLock { $0 }
    }

    /// Publishes a surface intent to a conversation's events topic.
    var publish: ComputerUseOversightCoordinator.Publish? {
        publishState.withLock { $0 }
    }

    var retention: ComputerUseRetention {
        configuration?.retention ?? ComputerUseRetention()
    }

    /// When images a conversation's tool results store should expire, or `nil` for the durable lane. A live
    /// specialist's child holds them until its lease's hard expiry plus the release TTL; release moves it.
    func toolImageExpiry(conversationID: UUID) async -> Date? {
        guard let session = await sessions.session(for: conversationID) else { return nil }
        return session.lease.expiresAt.addingTimeInterval(retention.afterRelease.timeInterval)
    }

    func install(_ configuration: ComputerUseConfiguration, publish: ComputerUseOversightCoordinator.Publish? = nil) {
        state.withLock { $0 = configuration }
        if let publish {
            publishState.withLock { $0 = publish }
            coordinatorState.withLock { $0 = ComputerUseOversightCoordinator(publish: publish) }
        }
    }
}

/// Who started the run that asked for computer use. Host targets need an operator-initiated run with the user
/// present.
struct ComputerUseRunOrigin: Sendable, Equatable {
    var operatorInitiated: Bool
    var userPresent: Bool

    static let interactiveOwner = ComputerUseRunOrigin(operatorInitiated: true, userPresent: true)

    init(operatorInitiated: Bool, userPresent: Bool) {
        self.operatorInitiated = operatorInitiated
        self.userPresent = userPresent
    }

    init(laneOrigin: RunLaneOriginKind, senderIsOwner: Bool?) {
        operatorInitiated = senderIsOwner != false
        switch laneOrigin {
        case .interactive, .pendingCompletionResume, .planExitDenialResume:
            userPresent = true
        case .trigger, .subagentSpawn:
            userPresent = false
        }
    }
}
