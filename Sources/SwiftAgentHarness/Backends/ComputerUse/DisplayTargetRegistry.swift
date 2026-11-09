import Foundation
import Logging

public enum ComputerUseLeaseDenial: Error, Sendable, Equatable {
    case unknownTarget(DisplayTargetID)
    /// Host targets need an operator-initiated session with the user present.
    case hostTargetRequiresPresentOperator
    case foregroundUnsupported
    case permissionsMissing([DisplayPlatformPermission])
    case grantsDeclined
    case targetBusy(holder: String)
    case driverFailure(String)
    /// The target can't be used until the user does something at it; the reason says what.
    case targetUnavailable(String)
}

/// What the start-of-session grant dialog asks the user to approve, and on whose behalf.
public struct ComputerUseGrantRequest: Sendable {
    /// The requested grants after app policy: what can be granted, with caps, and what is blocked.
    public var review: ComputerUseGrantReview
    /// The lease being requested, with its agent, budgets, delivery, and presence.
    public var lease: LeaseRequest
    public var target: DisplayTargetManifest
    /// What the session is for, such as a delegated task's goal.
    public var purpose: String?

    /// The target's screen is locked, so a plain approval would fail at the lease: the dialog can offer to unlock
    /// it first, which only the user can do, at the target. A lease waits for that unlock only as long as the target
    /// is configured to.
    public var targetLocked: Bool { lease.foundLocked }

    /// What the dialog must tell the user when it offers to unlock the target.
    public var unlockNotice: String? {
        guard targetLocked else { return nil }
        return "\(target.label) is locked. Unlock it to approve: it then stays unlocked and awake until the run ends, and anyone at it can use it."
    }

    public init(review: ComputerUseGrantReview, lease: LeaseRequest, target: DisplayTargetManifest, purpose: String? = nil) {
        self.review = review
        self.lease = lease
        self.target = target
        self.purpose = purpose
    }

    /// The user's conversation that asked, where the dialog belongs. For a delegated specialist this is the
    /// parent conversation, not the specialist's child.
    public var conversationID: UUID? { lease.conversationID }

    /// What the dialog must tell the user when the target is their own screen and serves a live view: the view
    /// shows the granted apps, and takes input for the app a handoff is for, during the handoff.
    public var liveViewNotice: String? {
        guard target.humanPresence == .shared, target.observerAccess != .none else { return nil }
        return "Your granted apps' windows can be watched from a live view, and the app a handoff is for can be controlled from it during the handoff."
    }
}

/// Presents the one start-of-session grant dialog. Returns the approved subset, or `nil` when the user declines.
public typealias ComputerUseGrantApprover = @Sendable (ComputerUseGrantRequest) async -> [ComputerUseGrant]?

public struct ComputerUseLeaseGrant: Sendable {
    public let target: any DisplayTarget
    public let lease: Lease
    public let review: ComputerUseGrantReview
}

public enum DisplayTargetRegistrationError: Error, Sendable, Equatable {
    /// Display targets and sandbox backends share one id namespace.
    case idTakenBySandboxBackend(DisplayTargetID)
    case idTakenByTarget(DisplayTargetID)
}

/// The display targets available to a harness, and the policy that applies before any target is leased.
public actor DisplayTargetRegistry {
    private var targets: [DisplayTargetID: any DisplayTarget] = [:]
    public nonisolated let reviewer: ComputerUseGrantReviewer
    public nonisolated let unattendedMaxDuration: Duration
    private let sandboxBackendIDs: @Sendable () -> Set<String>
    private let now: @Sendable () -> Date
    private let logger = Logger(label: "SwiftAgentHarness.ComputerUse.Registry")

    /// Throws when a target's id is already a sandbox backend's or another target's.
    public init(
        targets: [any DisplayTarget] = [],
        reviewer: ComputerUseGrantReviewer = ComputerUseGrantReviewer(),
        unattendedMaxDuration: Duration = .seconds(20 * 60),
        sandboxBackendIDs: @escaping @Sendable () -> Set<String> = { Set(SandboxBackendRegistry.allManifests().map(\.id)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws(DisplayTargetRegistrationError) {
        self.reviewer = reviewer
        self.unattendedMaxDuration = unattendedMaxDuration
        self.sandboxBackendIDs = sandboxBackendIDs
        self.now = now
        let reserved = sandboxBackendIDs()
        var registered: [DisplayTargetID: any DisplayTarget] = [:]
        for target in targets {
            let id = target.manifest.id
            if reserved.contains(id) { throw .idTakenBySandboxBackend(id) }
            if registered[id] != nil { throw .idTakenByTarget(id) }
            registered[id] = target
        }
        self.targets = registered
    }

    /// Throws when the target's id is already a sandbox backend's or another target's.
    public func register(_ target: any DisplayTarget) throws(DisplayTargetRegistrationError) {
        let id = target.manifest.id
        if sandboxBackendIDs().contains(id) { throw .idTakenBySandboxBackend(id) }
        if targets[id] != nil { throw .idTakenByTarget(id) }
        targets[id] = target
    }

    public func target(for id: DisplayTargetID) -> (any DisplayTarget)? {
        targets[id]
    }

    public var manifests: [DisplayTargetManifest] {
        targets.values.map(\.manifest).sorted { $0.id < $1.id }
    }

    public func lease(
        _ request: LeaseRequest,
        purpose: String? = nil,
        approve: ComputerUseGrantApprover
    ) async throws(ComputerUseLeaseDenial) -> ComputerUseLeaseGrant {
        guard let target = targets[request.target] else { throw .unknownTarget(request.target) }
        let manifest = target.manifest
        if manifest.isolation == .host || manifest.humanPresence == .shared, !(request.initiator == .operator && request.userPresent) {
            throw .hostTargetRequiresPresentOperator
        }
        if request.delivery == .foregroundAllowed, !manifest.delivery.contains(.foreground) {
            throw .foregroundUnsupported
        }
        let missing = await target.permissions().missing(manifest.requires)
        if !missing.isEmpty { throw .permissionsMissing(missing) }

        var request = request
        request.foundLocked = await target.isLocked()
        logger.info("Display target lock state before the grant dialog", metadata: [
            "target": "\(manifest.id)", "locked": "\(request.foundLocked)",
        ])

        let review = reviewer.review(request.grants)
        guard let answer = await approve(ComputerUseGrantRequest(review: review, lease: request, target: manifest, purpose: purpose)) else {
            throw .grantsDeclined
        }
        let approved = reviewer.clamp(answer, to: review)
        if approved.isEmpty { throw .grantsDeclined }

        var granted = request
        granted.grants = approved
        if !request.userPresent {
            granted.budgets.grantExpiry = min(granted.budgets.grantExpiry ?? unattendedMaxDuration, unattendedMaxDuration)
        }
        do {
            let lease = try await target.lease(granted)
            return ComputerUseLeaseGrant(target: target, lease: lease, review: review)
        } catch let error as DisplayTargetError {
            switch error {
            case .targetBusy(let holder): throw .targetBusy(holder: holder)
            case .permissionsMissing(let permissions): throw .permissionsMissing(permissions)
            case .targetUnavailable(let reason): throw .targetUnavailable(reason)
            case .leaseNotHeld, .unsupported, .driverFailure: throw .driverFailure(String(describing: error))
            }
        } catch {
            throw .driverFailure(String(describing: error))
        }
    }
}
