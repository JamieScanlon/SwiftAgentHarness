import Foundation
import Synchronization

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
    /// Who started the work, by trust.
    public var initiator: ComputerUseInitiator
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
        initiator: ComputerUseInitiator,
        userPresent: Bool,
        isHolderAlive: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.target = target
        self.conversationID = conversationID
        self.agentID = agentID
        self.grants = grants
        self.budgets = budgets
        self.delivery = delivery
        self.initiator = initiator
        self.userPresent = userPresent
        self.isHolderAlive = isHolderAlive
    }
}

/// Who started the work a lease serves, by trust. Host targets need the operator; nothing else gets one.
public enum ComputerUseInitiator: String, Sendable, Codable, Hashable {
    /// The owner, working with the harness.
    case `operator`
    /// A channel arrival from someone other than the owner.
    case nonOwner = "non-owner"
    /// A scheduled trigger or other automation.
    case trigger
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
    public var initiator: ComputerUseInitiator
    public var userPresent: Bool
    public var issuedAt: Date
    /// When the session must end; see ``ComputerUseBudgets/endsAt(start:)``.
    public var endsAt: Date

    public init(request: LeaseRequest, id: UUID = UUID(), issuedAt: Date) {
        self.id = id
        self.target = request.target
        self.holder = request.agentID
        self.conversationID = request.conversationID
        self.grants = request.grants
        self.budgets = request.budgets
        self.delivery = request.delivery
        self.initiator = request.initiator
        self.userPresent = request.userPresent
        self.issuedAt = issuedAt
        self.endsAt = request.budgets.endsAt(start: issuedAt)
    }
}

/// Why a lease ended. A session's terminal reason releases with the same-named value; the step and cost ceilings
/// release as `budgetExhausted`, and the time ceiling and grant expiry as `expired`.
public enum ReleaseReason: String, Sendable, Codable, Hashable {
    case completed
    case cancelled
    case budgetExhausted = "budget-exhausted"
    case noProgress = "no-progress"
    case deadline
    /// The time ceiling or the absolute grant expiry.
    case expired
    case idleTimeout = "idle-timeout"
    case killSwitch = "kill-switch"
    /// An operating-system permission was revoked; the user must grant it again.
    case permissionRevoked = "permission-revoked"
    /// A mode over the session started denying computer use; don't retry.
    case policyRevoked = "policy-revoked"
    /// The lease holder's connection died.
    case holderLost = "holder-lost"
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

/// Who a live-view link is for.
public enum DisplayLiveViewRole: String, Sendable, Codable, Hashable, CaseIterable {
    /// The user's own link: view-only, except that it carries their input during takeover.
    case user
    /// A link for someone else to watch. It never carries input, and shows nothing while the user has control.
    case observer
}

/// A link to a live view. It connects once, before `expiresAt`; the connection it makes is listed and revoked
/// under the link's `id`.
public struct DisplayLiveView: Sendable, Codable, Hashable {
    public var id: UUID
    public var url: String
    public var viewOnly: Bool
    public var expiresAt: Date
    public var role: DisplayLiveViewRole

    public init(id: UUID = UUID(), url: String, viewOnly: Bool, expiresAt: Date, role: DisplayLiveViewRole = .user) {
        self.id = id
        self.url = url
        self.viewOnly = viewOnly
        self.expiresAt = expiresAt
        self.role = role
    }
}

/// A viewer connected to a live view, under the id of the link it connected with.
public struct DisplayLiveViewConnection: Sendable, Codable, Hashable {
    public var id: UUID
    public var role: DisplayLiveViewRole
    public var connectedAt: Date

    public init(id: UUID, role: DisplayLiveViewRole, connectedAt: Date) {
        self.id = id
        self.role = role
        self.connectedAt = connectedAt
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

    /// A new link to watch the target. `nil` when it serves no live view.
    func liveView(_ lease: Lease, role: DisplayLiveViewRole) async throws -> DisplayLiveView?
    /// Ends every observer's stream and revokes the observer links; the user's are kept.
    func endObservers(_ lease: Lease) async throws
    /// How many viewers are connected to the lease's live view now, the user's and observers' alike.
    func liveViewers(_ lease: Lease) async throws -> Int
    /// The viewers connected to the lease's live view.
    func liveConnections(_ lease: Lease) async throws -> [DisplayLiveViewConnection]
    /// Ends one viewer's connection, or revokes its link if unused. `false` when there is no such link.
    func revokeLiveView(_ lease: Lease, id: UUID) async throws -> Bool

    /// The whole screen as a live-view frame, for a target whose live view something else serves, such as the
    /// harness serving a VM guest's. Unlike an observation it works during takeover. `nil` when the target gives
    /// none out.
    func liveFrame(_ lease: Lease) async throws -> DisplayLiveViewFrame?
    /// A live viewer's input, in the coordinate space of ``liveFrame(_:)``. Delivered only during takeover.
    func liveInput(_ lease: Lease, _ input: DisplayLiveViewInput) async throws

    /// Files the lease downloaded, into a folder of its own. Read before release.
    func downloads(_ lease: Lease) async -> [DisplayDownload]

    /// News about the lease the holder didn't ask for, finishing at release.
    func events(_ lease: Lease) async -> AsyncStream<DisplayTargetEvent>

    /// Pauses capture and agent input while on.
    func takeover(_ lease: Lease, on: Bool) async throws
}

public extension DisplayTarget {
    func liveView(_ lease: Lease, role: DisplayLiveViewRole) async throws -> DisplayLiveView? { nil }
    func endObservers(_ lease: Lease) async throws {}
    func liveViewers(_ lease: Lease) async throws -> Int { 0 }
    func liveConnections(_ lease: Lease) async throws -> [DisplayLiveViewConnection] { [] }
    func revokeLiveView(_ lease: Lease, id: UUID) async throws -> Bool { false }
    func liveFrame(_ lease: Lease) async throws -> DisplayLiveViewFrame? { nil }
    func liveInput(_ lease: Lease, _ input: DisplayLiveViewInput) async throws {}
    func downloads(_ lease: Lease) async -> [DisplayDownload] { [] }
    func events(_ lease: Lease) async -> AsyncStream<DisplayTargetEvent> { AsyncStream { $0.finish() } }

    func liveView(_ lease: Lease) async throws -> DisplayLiveView? {
        try await liveView(lease, role: .user)
    }
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

/// A file a lease downloaded, into the lease's own folder. Never opened.
public struct DisplayDownload: Sendable, Codable, Hashable {
    public var name: String
    public var path: String
    public var completed: Bool
    /// Deleted when the session ends unless the specialist keeps it; otherwise always kept. Listed either way.
    public var disposable: Bool

    public init(name: String, path: String, completed: Bool, disposable: Bool) {
        self.name = name
        self.path = path
        self.completed = completed
        self.disposable = disposable
    }
}

/// What a target tells its lease holder unprompted.
public enum DisplayTargetEvent: Sendable, Codable, Hashable {
    /// The user pressed the target's stop key.
    case stopRequested
    case permissionsChanged(PermissionSnapshot)
    /// The user started or ended a takeover from the target's own controls.
    case takeoverChanged(on: Bool)
    /// The user is typing on a shared desktop.
    case userTyping
    /// A value the user typed during a takeover, which helper models must never be shown.
    case typedDuringTakeover(String)
    /// The lease ended without the holder releasing it, such as a stop pressed while a remote target was
    /// unreachable, or a holder that couldn't get its lease back.
    case leaseEnded(ReleaseReason)
}

/// Fans a target's events out to the streams of the leases they concern.
public final class DisplayTargetEventHub: Sendable {
    private let streams = Mutex<[UUID: [UUID: AsyncStream<DisplayTargetEvent>.Continuation]]>([:])

    public init() {}

    /// A stream of the lease's events, finishing when ``finish(_:)`` is called for it.
    public func stream(for leaseID: UUID) -> AsyncStream<DisplayTargetEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DisplayTargetEvent.self, bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        streams.withLock { $0[leaseID, default: [:]][id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.streams.withLock { _ = $0[leaseID]?.removeValue(forKey: id) }
        }
        return stream
    }

    /// Sends `event` to the lease's streams, or to every lease's when `leaseID` is `nil`.
    public func post(_ event: DisplayTargetEvent, to leaseID: UUID? = nil) {
        let targets = streams.withLock { all in
            leaseID.map { Array((all[$0] ?? [:]).values) } ?? all.values.flatMap(\.values)
        }
        for continuation in targets { continuation.yield(event) }
    }

    public func finish(_ leaseID: UUID) {
        let ended = streams.withLock { $0.removeValue(forKey: leaseID) } ?? [:]
        for continuation in ended.values { continuation.finish() }
    }
}

