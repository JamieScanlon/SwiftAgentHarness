import Foundation

public struct ComputerUseBudgets: Sendable, Codable, Hashable {
    public var maxSteps: Int
    public var maxDuration: Duration
    public var maxUSD: Double?

    public init(maxSteps: Int, maxDuration: Duration, maxUSD: Double? = nil) {
        self.maxSteps = max(0, maxSteps)
        self.maxDuration = maxDuration
        self.maxUSD = maxUSD
    }
}

public enum ComputerUseDeliveryPolicy: String, Sendable, Codable, Hashable {
    case backgroundOnly = "background-only"
    /// Foreground delivery is a consented escalation, announced on shared targets.
    case foregroundAllowed = "foreground-allowed"
}

public struct LeaseRequest: Sendable {
    public var target: DisplayTargetID
    public var conversationID: UUID?
    public var agentID: String
    /// Requested; the user approves a subset.
    public var grants: [ComputerUseGrant]
    public var budgets: ComputerUseBudgets
    public var delivery: ComputerUseDeliveryPolicy
    /// The work was started by the operator (not a trigger or a non-owner channel arrival).
    public var operatorInitiated: Bool
    /// A person is present to watch, approve, and take over.
    public var userPresent: Bool
    /// Lets a target tell a crashed holder from a live one.
    public var isHolderAlive: @Sendable () async -> Bool

    public init(
        target: DisplayTargetID,
        conversationID: UUID? = nil,
        agentID: String,
        grants: [ComputerUseGrant],
        budgets: ComputerUseBudgets,
        delivery: ComputerUseDeliveryPolicy = .backgroundOnly,
        operatorInitiated: Bool,
        userPresent: Bool,
        isHolderAlive: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.target = target
        self.conversationID = conversationID
        self.agentID = agentID
        self.grants = grants
        self.budgets = budgets
        self.delivery = delivery
        self.operatorInitiated = operatorInitiated
        self.userPresent = userPresent
        self.isHolderAlive = isHolderAlive
    }
}

/// A single-controller hold on one display target.
public struct Lease: Sendable, Codable, Hashable {
    public var id: UUID
    public var target: DisplayTargetID
    public var holder: String
    public var conversationID: UUID?
    public var grants: [ComputerUseGrant]
    public var budgets: ComputerUseBudgets
    public var delivery: ComputerUseDeliveryPolicy
    public var operatorInitiated: Bool
    public var userPresent: Bool
    public var issuedAt: Date
    public var expiresAt: Date

    public init(request: LeaseRequest, id: UUID = UUID(), issuedAt: Date) {
        self.id = id
        self.target = request.target
        self.holder = request.agentID
        self.conversationID = request.conversationID
        self.grants = request.grants
        self.budgets = request.budgets
        self.delivery = request.delivery
        self.operatorInitiated = request.operatorInitiated
        self.userPresent = request.userPresent
        self.issuedAt = issuedAt
        self.expiresAt = issuedAt.addingTimeInterval(request.budgets.maxDuration.timeInterval)
    }
}

public enum ReleaseReason: String, Sendable, Codable, Hashable {
    case completed
    case aborted
    case killSwitch = "kill-switch"
    case budgetExhausted = "budget-exhausted"
    case expired
    case permissionRevoked = "permission-revoked"
    case error
}

public enum PermissionState: String, Sendable, Codable, Hashable {
    case granted
    case denied
    case notDetermined = "not-determined"
}

public struct PermissionSnapshot: Sendable, Codable, Hashable {
    public var states: [DisplayPlatformPermission: PermissionState]

    public init(states: [DisplayPlatformPermission: PermissionState]) {
        self.states = states
    }

    /// Required permissions that are not granted, in the order given.
    public func missing(_ required: [DisplayPlatformPermission]) -> [DisplayPlatformPermission] {
        required.filter { states[$0] != .granted }
    }
}

public struct DisplayLiveView: Sendable, Codable, Hashable {
    public var url: String
    public var viewOnly: Bool
    public var expiresAt: Date

    public init(url: String, viewOnly: Bool, expiresAt: Date) {
        self.url = url
        self.viewOnly = viewOnly
        self.expiresAt = expiresAt
    }
}

public enum DisplayTargetError: Error, Sendable, Codable, Hashable {
    case targetBusy(holder: String)
    case leaseNotHeld
    case permissionsMissing([DisplayPlatformPermission])
    case unsupported(String)
    case driverFailure(String)
}

/// One display target behind the canonical observe/act contract: a host desktop, a VM, a desktop container, a
/// managed browser, or a paired device. What differs between them is declared in the manifest.
///
/// A sibling of ``SandboxBackendHandle``, not an extension of it.
public protocol DisplayTarget: Sendable {
    var manifest: DisplayTargetManifest { get }

    /// Single controller: throws ``DisplayTargetError/targetBusy(holder:)`` while another live holder has it.
    func lease(_ request: LeaseRequest) async throws -> Lease
    /// Always restores UI state (unhide, cursor, focus). Idempotent.
    func release(_ lease: Lease, reason: ReleaseReason) async
    /// Polled before each action batch; users revoke grants mid-session.
    func permissions() async -> PermissionSnapshot

    func describe(_ lease: Lease) async throws -> TargetLayout
    func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation
    /// Re-resolves cited elements and refuses on drift. Stops at the first failure.
    func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome]

    func liveView(_ lease: Lease) async throws -> DisplayLiveView?
    /// Pauses capture and agent input while on.
    func takeover(_ lease: Lease, on: Bool) async throws
}

public extension DisplayTarget {
    func liveView(_ lease: Lease) async throws -> DisplayLiveView? { nil }
}

/// The single-controller lock a target driver holds its lease with.
public actor DisplayTargetLeaseLock {
    public struct Holder: Sendable {
        public var id: String
        public var isAlive: @Sendable () async -> Bool

        public init(id: String, isAlive: @escaping @Sendable () async -> Bool = { true }) {
            self.id = id
            self.isAlive = isAlive
        }
    }

    private var current: (leaseID: UUID, holder: Holder)?

    public init() {}

    public var holderID: String? { current?.holder.id }

    public func holds(leaseID: UUID) -> Bool {
        current?.leaseID == leaseID
    }

    public func acquire(leaseID: UUID, holder: Holder) async throws(DisplayTargetError) {
        while let existing = current, existing.leaseID != leaseID {
            let alive = await existing.holder.isAlive()
            // The liveness probe suspends; another acquire or release may have run meanwhile.
            guard current?.leaseID == existing.leaseID else { continue }
            if alive { throw .targetBusy(holder: existing.holder.id) }
            current = nil
        }
        current = (leaseID, holder)
    }

    @discardableResult
    public func release(leaseID: UUID) -> Bool {
        guard current?.leaseID == leaseID else { return false }
        current = nil
        return true
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
