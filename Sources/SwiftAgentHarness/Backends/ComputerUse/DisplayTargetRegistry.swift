import Foundation

public enum ComputerUseLeaseDenial: Error, Sendable, Equatable {
    case unknownTarget(DisplayTargetID)
    /// Host targets need an operator-initiated session with the user present.
    case hostTargetRequiresPresentOperator
    case foregroundUnsupported
    case permissionsMissing([DisplayPlatformPermission])
    case grantsDeclined
    case targetBusy(holder: String)
    case driverFailure(String)
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

    public init(review: ComputerUseGrantReview, lease: LeaseRequest, target: DisplayTargetManifest, purpose: String? = nil) {
        self.review = review
        self.lease = lease
        self.target = target
        self.purpose = purpose
    }

    /// The user's conversation that asked, where the dialog belongs. For a delegated specialist this is the
    /// parent conversation, not the specialist's child.
    public var conversationID: UUID? { lease.conversationID }
}

/// Presents the one start-of-session grant dialog. Returns the approved subset, or `nil` when the user declines.
public typealias ComputerUseGrantApprover = @Sendable (ComputerUseGrantRequest) async -> [ComputerUseGrant]?

public struct ComputerUseLeaseGrant: Sendable {
    public let target: any DisplayTarget
    public let lease: Lease
    public let review: ComputerUseGrantReview
}

/// The display targets available to a harness, and the policy that applies before any target is leased.
public actor DisplayTargetRegistry {
    private var targets: [DisplayTargetID: any DisplayTarget] = [:]
    public nonisolated let reviewer: ComputerUseGrantReviewer
    public nonisolated let unattendedMaxDuration: Duration
    private let now: @Sendable () -> Date

    public init(
        targets: [any DisplayTarget] = [],
        reviewer: ComputerUseGrantReviewer = ComputerUseGrantReviewer(),
        unattendedMaxDuration: Duration = .seconds(20 * 60),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        for target in targets {
            self.targets[target.manifest.id] = target
        }
        self.reviewer = reviewer
        self.unattendedMaxDuration = unattendedMaxDuration
        self.now = now
    }

    public func register(_ target: any DisplayTarget) {
        targets[target.manifest.id] = target
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
        if manifest.isolation == .host, !(request.operatorInitiated && request.userPresent) {
            throw .hostTargetRequiresPresentOperator
        }
        if request.delivery == .foregroundAllowed, !manifest.delivery.contains(.foreground) {
            throw .foregroundUnsupported
        }
        let missing = await target.permissions().missing(manifest.requires)
        if !missing.isEmpty { throw .permissionsMissing(missing) }

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
            case .leaseNotHeld, .unsupported, .driverFailure: throw .driverFailure(String(describing: error))
            }
        } catch {
            throw .driverFailure(String(describing: error))
        }
    }
}
