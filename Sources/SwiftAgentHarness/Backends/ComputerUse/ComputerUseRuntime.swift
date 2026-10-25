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

    public init(modeProfileID: String = "subagent-minimal", modelRef: String? = nil, runTimeoutSeconds: TimeInterval = 1_800) {
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
    public var specialist: ComputerUseSpecialistProfile

    public init(
        registry: DisplayTargetRegistry,
        defaults: ComputerUseSpecialistDefaults,
        approveGrants: @escaping ComputerUseGrantApprover,
        approvals: (any ExecApprovalDelivering)? = nil,
        intentChecker: ComputerUseIntentChecker? = nil,
        oversight: (any ComputerUseOversight)? = nil,
        specialist: ComputerUseSpecialistProfile = ComputerUseSpecialistProfile()
    ) {
        self.registry = registry
        self.defaults = defaults
        self.approveGrants = approveGrants
        self.approvals = approvals
        self.intentChecker = intentChecker
        self.oversight = oversight
        self.specialist = specialist
    }
}

/// Live specialist sessions, keyed by the child conversation that drives them.
actor ComputerUseSessionDirectory {
    private var sessions: [UUID: ComputerUseSession] = [:]

    func register(_ session: ComputerUseSession, for conversationID: UUID) {
        sessions[conversationID] = session
    }

    func session(for conversationID: UUID) -> ComputerUseSession? {
        sessions[conversationID]
    }

    func remove(for conversationID: UUID) {
        sessions.removeValue(forKey: conversationID)
    }

    var all: [ComputerUseSession] {
        Array(sessions.values)
    }
}

/// The host's computer-use configuration, shared by tool building and delegate dispatch.
final class ComputerUseInstallation: Sendable {
    private let state = Mutex<ComputerUseConfiguration?>(nil)
    let sessions = ComputerUseSessionDirectory()

    init() {}

    var configuration: ComputerUseConfiguration? {
        state.withLock { $0 }
    }

    func install(_ configuration: ComputerUseConfiguration) {
        state.withLock { $0 = configuration }
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
