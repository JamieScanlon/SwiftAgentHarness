import Foundation

public struct AskUserOptionPayload: Codable, Sendable, Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct AskUserPromptPayload: Codable, Sendable, Equatable {
    public let question: String
    public let options: [AskUserOptionPayload]
    public let allowMultiple: Bool
    public let defaultOptionID: String?

    public init(
        question: String,
        options: [AskUserOptionPayload],
        allowMultiple: Bool = false,
        defaultOptionID: String? = nil
    ) {
        self.question = question
        self.options = options
        self.allowMultiple = allowMultiple
        self.defaultOptionID = defaultOptionID
    }
}
