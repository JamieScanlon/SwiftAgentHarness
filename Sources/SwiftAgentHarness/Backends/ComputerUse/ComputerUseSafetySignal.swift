import Foundation

/// A vendor's safety signal on an action the model proposed. Each one is a question for the user, never
/// acknowledged on the user's behalf. A sensitive-domain signal also puts the session in watch mode.
public enum ComputerUseSafetySignal: Sendable, Hashable, Codable, RawRepresentable {
    /// The vendor saw instructions on screen that may not come from the user.
    case maliciousInstructions
    /// The page isn't one the task seems to need.
    case irrelevantDomain
    /// The page is one where mistakes are costly, such as banking or health. The session continues only while the
    /// user watches its live view.
    case sensitiveDomain
    /// The vendor asks the client to confirm the action with the user.
    case requireConfirmation
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "malicious-instructions": self = .maliciousInstructions
        case "irrelevant-domain": self = .irrelevantDomain
        case "sensitive-domain": self = .sensitiveDomain
        case "require-confirmation": self = .requireConfirmation
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .maliciousInstructions: "malicious-instructions"
        case .irrelevantDomain: "irrelevant-domain"
        case .sensitiveDomain: "sensitive-domain"
        case .requireConfirmation: "require-confirmation"
        case .other(let value): value
        }
    }

    /// A pending safety check's `code` on OpenAI's computer tool.
    public init(openAISafetyCheckCode code: String) {
        self.init(rawValue: code.replacingOccurrences(of: "_", with: "-"))
        if case .other = self { self = .other(code) }
    }

    /// A `safety_decision.decision` on Gemini's computer use, or `nil` when it asks for nothing.
    public init?(geminiSafetyDecision decision: String) {
        guard decision == "require_confirmation" else { return nil }
        self = .requireConfirmation
    }
}
