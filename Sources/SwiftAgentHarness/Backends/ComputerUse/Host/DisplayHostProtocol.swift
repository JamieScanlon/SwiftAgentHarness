import Foundation

/// The wire protocol between a harness and a display host: a process that owns a ``DisplayTarget`` and serves
/// it to harnesses elsewhere, so the process macOS grants screen and input permissions to need not be the one
/// running the agent.
///
/// Messages are JSON-encoded ``DisplayHostMessage`` values. The client opens with `hello`, giving its version and
/// capabilities; the host answers `welcome` with its own and its manifest. A different major version is refused
/// with a version-mismatch failure; a different minor version proceeds with the capabilities both sides have.
/// Adding a field is a minor change; changing or removing one is a major change.
///
/// Requests carry ids and may be in flight concurrently; responses echo the id. Leases are named by id only, and
/// a host honours only the leases it issued on the same connection, or that the connection reattached. The host
/// also sends events unprompted.
public enum DisplayHostProtocol {
    public static let version = DisplayHostVersion(major: 6, minor: 0)
    /// What this build of the protocol supports.
    public static let capabilities: Set<DisplayHostCapability> = [.liveView, .downloads, .events, .reattach, .imageFiles]
    /// The largest message either side accepts.
    public static let maxMessageBytes = 64 * 1024 * 1024
}

public struct DisplayHostVersion: Sendable, Codable, Hashable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public var description: String { "\(major).\(minor)" }
}

/// A feature one side of a connection supports. Unknown capabilities decode, so a newer peer's don't fail the
/// handshake.
public struct DisplayHostCapability: RawRepresentable, Sendable, Codable, Hashable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// Live-view links, viewers, frames, and input.
    public static let liveView = Self(rawValue: "live-view")
    public static let downloads = Self(rawValue: "downloads")
    /// Target events: the stop key, permission changes, takeover, the user typing.
    public static let events = Self(rawValue: "events")
    /// A lease outlives a dropped connection for a grace period, and a new connection can take it back.
    public static let reattach = Self(rawValue: "reattach")
    /// Images travel as files the host wrote, not inline. Offered only on transports that share a filesystem.
    public static let imageFiles = Self(rawValue: "image-files")
}

/// A lease request as it travels; the host supplies holder liveness from the connection.
public struct DisplayHostLeaseRequest: Sendable, Codable, Hashable {
    public var target: DisplayTargetID
    public var conversationID: UUID?
    public var agentID: String
    public var grants: [ComputerUseGrant]
    public var budgets: ComputerUseBudgets
    public var delivery: ComputerUseDeliveryPolicy
    public var initiator: ComputerUseInitiator
    public var userPresent: Bool

    public init(_ request: LeaseRequest) {
        self.target = request.target
        self.conversationID = request.conversationID
        self.agentID = request.agentID
        self.grants = request.grants
        self.budgets = request.budgets
        self.delivery = request.delivery
        self.initiator = request.initiator
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
            initiator: initiator,
            userPresent: userPresent,
            isHolderAlive: isHolderAlive
        )
    }
}

public enum DisplayHostRequest: Sendable, Codable, Hashable {
    case hello(version: DisplayHostVersion, client: String, capabilities: [DisplayHostCapability])
    case lease(request: DisplayHostLeaseRequest)
    /// Takes back a lease whose connection dropped, within the host's grace period.
    case reattach(leaseID: UUID, token: String)
    case downloads(leaseID: UUID)
    case release(leaseID: UUID, reason: ReleaseReason)
    case permissions
    case describe(leaseID: UUID)
    case observe(leaseID: UUID, request: ObserveRequest)
    case act(leaseID: UUID, batch: ActionBatch)
    case liveView(leaseID: UUID, role: DisplayLiveViewRole)
    case endObservers(leaseID: UUID)
    case liveViewers(leaseID: UUID)
    case liveConnections(leaseID: UUID)
    case revokeLiveView(leaseID: UUID, id: UUID)
    case takeover(leaseID: UUID, on: Bool)
    case liveFrame(leaseID: UUID)
    case liveInput(leaseID: UUID, input: DisplayLiveViewInput)
}

public enum DisplayHostResponse: Sendable, Codable, Hashable {
    /// `imageDirectory` is where the host writes image files, when the connection agreed to them.
    case welcome(
        version: DisplayHostVersion,
        host: String,
        manifest: DisplayTargetManifest,
        capabilities: [DisplayHostCapability],
        imageDirectory: String?
    )
    /// `reattachToken` takes the lease back from a new connection after this one drops.
    case lease(Lease, reattachToken: String?)
    case downloads([DisplayDownload])
    case done
    case permissions(PermissionSnapshot)
    case layout(TargetLayout)
    /// With `imageFile`, the image's bytes are in that file instead of the observation; the client reads and
    /// deletes it.
    case observation(DisplayObservation, imageFile: String?)
    case outcomes([ActionOutcome])
    case liveView(DisplayLiveView?)
    case liveViewers(Int)
    case liveConnections([DisplayLiveViewConnection])
    case revoked(Bool)
    /// With `imageFile`, the frame's JPEG is in that file instead.
    case liveFrame(DisplayLiveViewFrame?, imageFile: String?)
    case failure(DisplayHostFailure)
}

public enum DisplayHostFailure: Sendable, Codable, Hashable {
    case target(DisplayTargetError)
    case versionMismatch(host: DisplayHostVersion, client: DisplayHostVersion)
    /// The request needs a capability the connection didn't agree on.
    case unsupported(DisplayHostCapability)
    case protocolError(String)
}

/// Unsolicited news from the host.
public enum DisplayHostEvent: Sendable, Codable, Hashable {
    case target(leaseID: UUID, event: DisplayTargetEvent)
}

public enum DisplayHostMessage: Sendable, Codable, Hashable {
    case request(id: UInt64, body: DisplayHostRequest)
    case response(id: UInt64, body: DisplayHostResponse)
    case event(DisplayHostEvent)
}

public enum DisplayHostError: Error, Sendable, Equatable {
    case versionMismatch(host: DisplayHostVersion, client: DisplayHostVersion)
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
