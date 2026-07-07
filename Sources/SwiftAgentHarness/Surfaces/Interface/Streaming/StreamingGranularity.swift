import Foundation

/// Per-surface streaming rung on the capability ladder (coarsest-affording to finest).
public enum StreamingGranularity: String, Sendable, Codable, CaseIterable, Hashable {
    /// Repaint on every token/delta event (terminals, native web clients).
    case tokenDelta
    /// Emit each completed coarse block as a normal message.
    case block
    /// Keep one temporary message and update it in place.
    case previewEdit
    /// Render nothing until the turn completes.
    case finalOnly
}

/// Preferred break boundary when searching for a chunk split point.
public enum BreakPreference: String, Sendable, Codable, CaseIterable, Hashable {
    case paragraph
    case newline
    case sentence
    case whitespace
    case hard

    /// Joiner used when coalescing consecutive blocks at this break level.
    public var joiner: String {
        switch self {
        case .paragraph: return "\n\n"
        case .newline: return "\n"
        case .sentence, .whitespace, .hard: return " "
        }
    }
}

/// When block streaming flushes accumulated text.
public enum BlockBreakBoundary: String, Sendable, Codable, Hashable {
    /// Flush blocks as the chunker emits them.
    case textEnd
    /// Buffer until the assistant message finishes, then flush.
    case messageEnd
}
