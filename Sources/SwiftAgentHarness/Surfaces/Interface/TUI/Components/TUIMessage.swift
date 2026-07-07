import Foundation

public enum TUIMessageRole: String, Sendable, Equatable {
    case user
    case assistant
    case system
    case tool
}

public struct TUIMessage: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: TUIMessageRole
    public var content: String
    public var reasoning: String?
    public var toolName: String?
    public var isStreaming: Bool

    public init(
        id: UUID = UUID(),
        role: TUIMessageRole,
        content: String,
        reasoning: String? = nil,
        toolName: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolName = toolName
        self.isStreaming = isStreaming
    }
}
