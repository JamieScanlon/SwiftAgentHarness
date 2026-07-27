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
    /// Portable presentation this message was delivered as, when the surface received one.
    ///
    /// `content` always holds the text floor, so a message renders correctly whether or
    /// not the presentation survives; the terminal renders the blocks natively when it is
    /// present rather than degrading to that floor.
    public var presentation: MessagePresentation?

    public init(
        id: UUID = UUID(),
        role: TUIMessageRole,
        content: String,
        reasoning: String? = nil,
        toolName: String? = nil,
        isStreaming: Bool = false,
        presentation: MessagePresentation? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolName = toolName
        self.isStreaming = isStreaming
        self.presentation = presentation
    }
}
