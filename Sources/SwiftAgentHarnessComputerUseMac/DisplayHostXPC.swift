#if os(macOS)
import Foundation
import SwiftAgentHarness
import XPC

/// Display-host connections over XPC, for hosts launchd runs as a Mach service (for example an
/// `SMAppService.agent` login item) or that hand out an anonymous listener's endpoint. Both ends enforce a
/// peer code-signing requirement.
@available(macOS 26.0, *)
public enum DisplayHostXPC {
    /// Serves the launchd Mach service `name`.
    public static func listen(machService name: String, requirement: XPCPeerRequirement) throws -> DisplayHostXPCListener {
        try DisplayHostXPCListener(service: name, requirement: requirement)
    }

    /// An unnamed listener; give clients its ``DisplayHostXPCListener/endpoint``.
    public static func anonymousListener(requirement: XPCPeerRequirement) throws -> DisplayHostXPCListener {
        try DisplayHostXPCListener(service: nil, requirement: requirement)
    }

    public static func connect(machService name: String, requirement: XPCPeerRequirement) throws -> DisplayHostXPCConnection {
        try DisplayHostXPCConnection.open(requirement: requirement) { handler, cancellation in
            try XPCSession(machService: name, options: .inactive, incomingMessageHandler: handler, cancellationHandler: cancellation)
        }
    }

    public static func connect(endpoint: XPCEndpoint, requirement: XPCPeerRequirement) throws -> DisplayHostXPCConnection {
        try DisplayHostXPCConnection.open(requirement: requirement) { handler, cancellation in
            try XPCSession(endpoint: endpoint, options: .inactive, incomingMessageHandler: handler, cancellationHandler: cancellation)
        }
    }
}

/// One protocol message per XPC message.
struct DisplayHostXPCFrame: Codable, Sendable {
    var message: Data
}

@available(macOS 26.0, *)
public final class DisplayHostXPCListener: DisplayHostListener {
    public let connections: AsyncThrowingStream<any DisplayHostConnection, any Error>
    private let continuation: AsyncThrowingStream<any DisplayHostConnection, any Error>.Continuation
    private let listener: XPCListener

    public var endpoint: XPCEndpoint { listener.endpoint }

    init(service: String?, requirement: XPCPeerRequirement) throws {
        let (connections, continuation) = AsyncThrowingStream.makeStream(
            of: (any DisplayHostConnection).self,
            throwing: (any Error).self
        )
        self.connections = connections
        self.continuation = continuation
        let accept: @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision = { request in
            let (inbound, inboundContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
            let (decision, session) = request.accept(
                incomingMessageHandler: { (message: XPCReceivedMessage) -> (any Encodable)? in
                    // Anonymous listeners have no listener-level requirement, so every message is checked.
                    guard message.senderSatisfies(requirement) else {
                        inboundContinuation.finish(throwing: DisplayHostError.peerRejected)
                        return nil
                    }
                    DisplayHostXPCConnection.deliver(message, to: inboundContinuation)
                    return nil
                },
                cancellationHandler: { _ in inboundContinuation.finish() }
            )
            continuation.yield(DisplayHostXPCConnection(session: session, inbound: inbound, inboundContinuation: inboundContinuation))
            return decision
        }
        if let service {
            listener = try XPCListener(service: service, options: .inactive, requirement: requirement, incomingSessionHandler: accept)
        } else {
            listener = XPCListener(options: .inactive, incomingSessionHandler: accept)
        }
        try listener.activate()
    }

    public func close() async {
        listener.cancel()
        continuation.finish()
    }
}

@available(macOS 26.0, *)
public final class DisplayHostXPCConnection: DisplayHostConnection {
    /// XPC checks the peer itself, so there are no credentials to report.
    public let peer = DisplayHostPeer()
    public let inbound: AsyncThrowingStream<Data, any Error>
    private let inboundContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let session: XPCSession

    init(session: XPCSession, inbound: AsyncThrowingStream<Data, any Error>, inboundContinuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.session = session
        self.inbound = inbound
        self.inboundContinuation = inboundContinuation
    }

    static func open(
        requirement: XPCPeerRequirement,
        session make: (
            _ handler: @escaping @Sendable (XPCReceivedMessage) -> (any Encodable)?,
            _ cancellation: @escaping @Sendable (XPCRichError) -> Void
        ) throws -> XPCSession
    ) throws -> DisplayHostXPCConnection {
        let (inbound, inboundContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        let session = try make(
            { message in
                deliver(message, to: inboundContinuation)
                return nil
            },
            { _ in inboundContinuation.finish() }
        )
        session.setPeerRequirement(requirement)
        try session.activate()
        return DisplayHostXPCConnection(session: session, inbound: inbound, inboundContinuation: inboundContinuation)
    }

    static func deliver(_ message: XPCReceivedMessage, to continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        do {
            continuation.yield(try message.decode(as: DisplayHostXPCFrame.self).message)
        } catch {
            continuation.finish(throwing: DisplayHostError.malformedMessage(String(describing: error)))
        }
    }

    public func send(_ message: Data) async throws {
        guard message.count <= DisplayHostProtocol.maxMessageBytes else {
            throw DisplayHostError.frameTooLarge(message.count)
        }
        do {
            try session.send(DisplayHostXPCFrame(message: message))
        } catch {
            throw DisplayHostError.connectionClosed
        }
    }

    public func close() async {
        session.cancel(reason: "closed")
        inboundContinuation.finish()
    }
}
#endif
