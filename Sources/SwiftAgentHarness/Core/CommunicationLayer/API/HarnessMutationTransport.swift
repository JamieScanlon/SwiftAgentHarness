import Foundation
import Vapor

/// Session context for in-process REST loopback (mirrors ``ClientSessionMiddleware`` + Bearer owner).
public struct EmbeddedHarnessAPISession: Sendable, Equatable {
    public var connectionNamespace: UUID?
    public var authorizationHeader: String?

    public init(connectionNamespace: UUID? = nil, authorizationHeader: String? = nil) {
        self.connectionNamespace = connectionNamespace
        self.authorizationHeader = authorizationHeader
    }
}

public struct EmbeddedSendMessageRequest: Sendable {
    public var message: String
    public var imageNames: [String]
    public var includeTools: Bool
    public var includeAgents: Bool
    public var expectedPreviousTailHarnessMessageID: UUID?
    public var inputTrust: String?
    public var ifMatch: String?
    public var originSurface: String?
    public var originSenderID: String?
    /// Sender-scoped **self-restriction**: `true` asserts the human behind this send is *not* the
    /// conversation owner. Deliberately negative-only — this value crosses an unauthenticated
    /// request body, so a caller may only ever lower its own privilege, never claim ownership.
    public var originSenderIsNonOwner: Bool?

    public init(
        message: String,
        imageNames: [String] = [],
        includeTools: Bool = true,
        includeAgents: Bool = true,
        expectedPreviousTailHarnessMessageID: UUID? = nil,
        inputTrust: String? = nil,
        ifMatch: String? = nil,
        originSurface: String? = nil,
        originSenderID: String? = nil,
        originSenderIsNonOwner: Bool? = nil
    ) {
        self.message = message
        self.imageNames = imageNames
        self.includeTools = includeTools
        self.includeAgents = includeAgents
        self.expectedPreviousTailHarnessMessageID = expectedPreviousTailHarnessMessageID
        self.inputTrust = inputTrust
        self.ifMatch = ifMatch
        self.originSurface = originSurface
        self.originSenderID = originSenderID
        self.originSenderIsNonOwner = originSenderIsNonOwner
    }
}

public struct EmbeddedSendMessageResult: Sendable, Equatable {
    public var runID: UUID
    public var messageID: UUID

    public init(runID: UUID, messageID: UUID) {
        self.runID = runID
        self.messageID = messageID
    }
}

public struct EmbeddedCreateConversationRequest: Sendable {
    public var modelRef: String
    public var userSystemPrompt: String
    public var topic: String?
    public var description: String?

    public init(
        modelRef: String,
        userSystemPrompt: String = "",
        topic: String? = nil,
        description: String? = nil
    ) {
        self.modelRef = modelRef
        self.userSystemPrompt = userSystemPrompt
        self.topic = topic
        self.description = description
    }
}

/// In-process mutation door: same REST routes and handler pipeline as socket clients.
public protocol HarnessMutationTransporting: Sendable {
    func createConversation(
        session: EmbeddedHarnessAPISession,
        request: EmbeddedCreateConversationRequest
    ) async throws -> UUID

    func sendMessage(
        session: EmbeddedHarnessAPISession,
        conversationID: UUID,
        request: EmbeddedSendMessageRequest
    ) async throws -> EmbeddedSendMessageResult

    func patchConversation(
        session: EmbeddedHarnessAPISession,
        conversationID: UUID,
        patch: ConversationPatch,
        ifMatch: String?
    ) async throws

    func resolveExecApproval(
        session: EmbeddedHarnessAPISession,
        approvalID: String,
        approved: Bool,
        durable: Bool,
        reason: String?
    ) async throws

    func cancelRun(
        session: EmbeddedHarnessAPISession,
        conversationID: UUID,
        runID: UUID,
        ifMatch: String?
    ) async throws
}

public enum HarnessMutationTransportError: Error, Sendable, Equatable {
    case notConfigured
    case unexpectedStatus(HTTPResponseStatus)
    case invalidResponse
}

/// Composition-root holder for the embedded mutation transport.
public actor HarnessMutationTransportHolder {
    public static let shared = HarnessMutationTransportHolder()

    private var transport: (any HarnessMutationTransporting)?

    private init() {}

    public func setTransport(_ transport: (any HarnessMutationTransporting)?) {
        self.transport = transport
    }

    public func currentTransport() -> (any HarnessMutationTransporting)? {
        transport
    }
}
