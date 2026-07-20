import Foundation

/// How much conversation the situational active-memory sub-agent sees (OpenClaw-aligned).
public enum ActiveMemoryQueryMode: String, Sendable, Codable, Equatable, CaseIterable {
    /// Latest user message only.
    case message
    /// Latest user message plus a capped recent tail of prior turns.
    case recent
    /// Bounded larger window (still per-turn char-capped); may need a higher situational timeout.
    case full
}

/// How eager the situational recall prompt is about returning a note (OpenClaw-aligned).
public enum ActiveMemoryPromptStyle: String, Sendable, Codable, Equatable, CaseIterable {
    case balanced
    case strict
    case contextual
    case recallHeavy = "recall-heavy"
    case precisionHeavy = "precision-heavy"
    case preferenceOnly = "preference-only"
}
