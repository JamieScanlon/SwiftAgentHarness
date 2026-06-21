import Foundation

public struct CachedToolCall: Sendable, Equatable {
    public var id: String?
    public var name: String
    public var argumentsJson: String
    public var instructions: String

    public init(id: String? = nil, name: String, argumentsJson: String = "{}", instructions: String = "") {
        self.id = id
        self.name = name
        self.argumentsJson = argumentsJson
        self.instructions = instructions
    }
}

public struct CachedResource: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var resourceDescription: String?
    public var fileType: String
    public var filePath: String?
    public var thumbnailPath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        resourceDescription: String? = nil,
        fileType: String = "other",
        filePath: String? = nil,
        thumbnailPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.resourceDescription = resourceDescription
        self.fileType = fileType
        self.filePath = filePath
        self.thumbnailPath = thumbnailPath
    }
}

public struct CachedMessage: Sendable, Equatable {
    public var id: UUID
    public var role: String
    public var content: String
    public var timestamp: Date
    public var resources: [CachedResource]
    public var toolCalls: [String]
    public var toolCallItems: [CachedToolCall]
    public var responseFormat: String?
    public var toolCallId: String?
    public var excludedFromActiveTranscript: Bool
    public var logicalMessageID: UUID?
    public var inputTrustRaw: String?

    public init(
        id: UUID,
        role: String,
        content: String,
        timestamp: Date = Date(),
        resources: [CachedResource] = [],
        toolCalls: [String] = [],
        toolCallItems: [CachedToolCall] = [],
        responseFormat: String? = nil,
        toolCallId: String? = nil,
        excludedFromActiveTranscript: Bool = false,
        logicalMessageID: UUID? = nil,
        inputTrustRaw: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.resources = resources
        self.toolCalls = toolCalls
        self.toolCallItems = toolCallItems
        self.responseFormat = responseFormat
        self.toolCallId = toolCallId
        self.excludedFromActiveTranscript = excludedFromActiveTranscript
        self.logicalMessageID = logicalMessageID
        self.inputTrustRaw = inputTrustRaw
    }
}
