import Foundation

/// Unified addressing surface for the Model Pool: matches the spec's `resolve(idOrQuery: string | ModelQuery)`.
///
/// Wire callers (REST/WebSocket) flatten incoming `modelRef` strings via ``parse(_:)``; in-process callers can also
/// supply a ``ModelQuery`` for capability-driven selection.
public enum ModelReference: Sendable, Hashable {
    case id(UUID)
    case slug(String)
    case query(ModelQuery)

    /// Parses a wire-supplied string: tries UUID first, falls back to a non-empty slug.
    /// Whitespace is trimmed; empty/whitespace-only input returns `nil`.
    public static func parse(_ raw: String) -> ModelReference? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let uuid = UUID(uuidString: trimmed) {
            return .id(uuid)
        }
        return .slug(trimmed)
    }
}
