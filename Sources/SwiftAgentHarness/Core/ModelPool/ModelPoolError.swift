import Foundation

/// Errors thrown by the Model Pool resolve surface (spec: `resolve(idOrQuery)` returns or fails loudly).
///
/// Wire boundaries map cases to today's wire-error responses; in-process callers can pattern-match.
public enum ModelPoolError: Error, Sendable, Equatable {
    /// No registry entry matched the given ``ModelReference`` (id, slug, or query).
    case unavailable(reference: ModelReference)
}
