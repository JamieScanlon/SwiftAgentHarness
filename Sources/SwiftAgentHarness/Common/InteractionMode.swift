import Foundation

/// Top-level interaction style for a conversation.
public enum InteractionMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Standard back-and-forth chat (default for existing conversations).
    case chat
    /// Collaborate with the model to author `plan.md` via plan tools (planning only; no build execution in this mode).
    case plan
    /// Execute and iterate on tasks in `plan.md` (build / autonomous agent loop).
    case agent
}

