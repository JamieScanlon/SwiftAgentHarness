import Foundation

/// The wire protocol between a harness and a display host: a process that owns a ``DisplayTarget`` and serves
/// it to harnesses elsewhere, so the process macOS grants screen and input permissions to need not be the one
/// running the agent.
///
/// Messages are JSON-encoded ``DisplayHostMessage`` values. The client opens with `hello`; the host answers
/// `welcome` with its manifest, or a version-mismatch failure. Requests carry ids and may be in flight
/// concurrently; responses echo the id. Leases are named by id only, and a host honours only the leases it
/// issued on the same connection.
public enum DisplayHostProtocol {
    public static let version = 2
    /// The largest message either side accepts.
    public static let maxMessageBytes = 64 * 1024 * 1024
}

/// A lease request as it travels; the host supplies holder liveness from the connection.
public struct DisplayHostLeaseRequest: Sendable, Codable, Hashable {
    public var target: DisplayTargetID
    public var conversationID: UUID?
    public var agentID: String
    public var grants: [ComputerUseGrant]
    public var budgets: ComputerUseBudgets
    public var delivery: ComputerUseDeliveryPolicy
    public var operatorInitiated: Bool
    public var userPresent: Bool

    public init(_ request: LeaseRequest) {
        self.target = request.target
        self.conversationID = request.conversationID
        self.agentID = request.agentID
        self.grants = request.grants
        self.budgets = request.budgets
        self.delivery = request.delivery
        self.operatorInitiated = request.operatorInitiated
        self.userPresent = request.userPresent
    }

    func leaseRequest(isHolderAlive: @escaping @Sendable () async -> Bool) -> LeaseRequest {
        LeaseRequest(
            target: target,
            conversationID: conversationID,
            agentID: agentID,
            grants: grants,
            budgets: budgets,
            delivery: delivery,
            operatorInitiated: operatorInitiated,
            userPresent: userPresent,
            isHolderAlive: isHolderAlive
        )
    }
}

public enum DisplayHostRequest: Sendable, Codable, Hashable {
    case hello(version: Int, client: String)
    case lease(request: DisplayHostLeaseRequest)
    case release(leaseID: UUID, reason: ReleaseReason)
    case permissions
    case describe(leaseID: UUID)
    case observe(leaseID: UUID, request: ObserveRequest)
    case act(leaseID: UUID, batch: ActionBatch)
    case liveView(leaseID: UUID)
    case takeover(leaseID: UUID, on: Bool)
}

public enum DisplayHostResponse: Sendable, Codable, Hashable {
    case welcome(version: Int, host: String, manifest: DisplayTargetManifest)
    case lease(Lease)
    case done
    case permissions(PermissionSnapshot)
    case layout(TargetLayout)
    case observation(DisplayObservation)
    case outcomes([ActionOutcome])
    case liveView(DisplayLiveView?)
    case failure(DisplayHostFailure)
}

public enum DisplayHostFailure: Sendable, Codable, Hashable {
    case target(DisplayTargetError)
    case versionMismatch(host: Int, client: Int)
    case protocolError(String)
}

/// Unsolicited news from the host.
public enum DisplayHostEvent: Sendable, Codable, Hashable {
    /// The user asked the host to stop, for example with its stop key. `nil` means every lease on the connection.
    case stopRequested(leaseID: UUID?)
}

public enum DisplayHostMessage: Sendable, Codable, Hashable {
    case request(id: UInt64, body: DisplayHostRequest)
    case response(id: UInt64, body: DisplayHostResponse)
    case event(DisplayHostEvent)
}

public enum DisplayHostError: Error, Sendable, Equatable {
    case versionMismatch(host: Int, client: Int)
    case peerRejected
    case connectionClosed
    case malformedMessage(String)
    case frameTooLarge(Int)
    case unexpectedResponse(String)
    case transportFailure(String)
}

public enum DisplayHostCodec {
    public static func encode(_ message: DisplayHostMessage) throws -> Data {
        try JSONEncoder().encode(message)
    }

    public static func decode(_ data: Data) throws -> DisplayHostMessage {
        do {
            return try JSONDecoder().decode(DisplayHostMessage.self, from: data)
        } catch {
            throw DisplayHostError.malformedMessage(String(describing: error))
        }
    }
}
