import Foundation

struct TriggerMessageRequest: Codable, Sendable {
    /// Required conversation to send into. Server selects this conversation before sending.
    let conversationID: String

    /// The message body (appears after the trigger line and blank line in stored content).
    let message: String

    /// Optional key-value metadata (e.g. name, type, source). Loosely structured; no fixed schema.
    let triggerMetadata: [String: String]?

    /// Optional image filenames (e.g. from upload), same semantics as ChatRequest.
    let imageNames: [String]?

    /// Whether to enable tools. Defaults to true when omitted.
    let includeTools: Bool?

    /// Whether to enable agents. Defaults to true when omitted.
    let includeAgents: Bool?

    init(
        conversationID: String,
        message: String,
        triggerMetadata: [String: String]? = nil,
        imageNames: [String]? = nil,
        includeTools: Bool? = nil,
        includeAgents: Bool? = nil
    ) {
        self.conversationID = conversationID
        self.message = message
        self.triggerMetadata = triggerMetadata
        self.imageNames = imageNames
        self.includeTools = includeTools
        self.includeAgents = includeAgents
    }
}

enum TriggerRESTRouteError: Error, Sendable {
    case invalidConversationID
}

struct PreparedTriggerRequest: Sendable {
    let conversationID: UUID
    let fullContent: String
    let imageNames: [String]
    let includeTools: Bool
    let includeAgents: Bool

    init(
        conversationID: UUID,
        fullContent: String,
        imageNames: [String],
        includeTools: Bool,
        includeAgents: Bool
    ) {
        self.conversationID = conversationID
        self.fullContent = fullContent
        self.imageNames = imageNames
        self.includeTools = includeTools
        self.includeAgents = includeAgents
    }
}

enum TriggerRESTRouteCore {
    /// Pure trigger request normalization and content preparation.
    static func prepare(
        request: TriggerMessageRequest,
        now: @Sendable () -> Date = Date.init
    ) throws -> PreparedTriggerRequest {
        guard let conversationID = UUID(uuidString: request.conversationID) else {
            throw TriggerRESTRouteError.invalidConversationID
        }

        let receivedAt = ISO8601DateFormatter().string(from: now())
        let fullContent = TriggerContentBuilder.buildFullContent(
            messageBody: request.message,
            triggerMetadata: request.triggerMetadata,
            serverKeys: ["received_at": receivedAt]
        )

        return PreparedTriggerRequest(
            conversationID: conversationID,
            fullContent: fullContent,
            imageNames: request.imageNames ?? [],
            includeTools: request.includeTools != false,
            includeAgents: request.includeAgents != false
        )
    }
}
