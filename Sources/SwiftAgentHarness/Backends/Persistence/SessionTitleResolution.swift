//
//  Shared README `resolve_by_title` + `next_title_in_lineage` matching and ordering (Gap 3).
//

import Foundation

enum SessionTitleResolution {
    /// Trim Unicode whitespace and apply NFC so composed/decomposed titles collapse before catalog index lookup.
    static func sanitizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    /// Leading/trailing Unicode whitespace trimmed and NFC-normalized before comparison (aligns with Gap 3 reference).
    static func normalizedTitleForLookup(_ title: String) -> String {
        sanitizedTitle(title)
    }

    /// NFC-normalizes optional catalog ``title``/``topic`` values before persistence (clears empty-after-trim).
    static func normalizedStoredTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = sanitizedTitle(value)
        return normalized.isEmpty ? nil : normalized
    }

    /// ``baseTitle`` must already be normalized. Stored catalog titles are compared as persisted (no trim of stored value).
    static func storedTitleMatchesLineage(baseTitle: String, storedTitle: String) -> Bool {
        if storedTitle == baseTitle { return true }
        let pattern = "^\(NSRegularExpression.escapedPattern(for: baseTitle)) #\\d+$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(location: 0, length: (storedTitle as NSString).length)
        return regex.firstMatch(in: storedTitle, options: [], range: range) != nil
    }

    static func resolveSessionID(records: [SessionCatalogRecord], normalizedTitle: String, lifecycleState: String?) throws -> UUID? {
        let matches = records.filter { record in
            guard let t = record.title, t == normalizedTitle else { return false }
            if let lifecycleState {
                guard record.lifecycleStateRaw == lifecycleState else { return false }
            }
            return true
        }
        if matches.count > 1 {
            throw SessionPersistenceError.titleAmbiguous(title: normalizedTitle, lifecycleState: lifecycleState)
        }
        return matches.first?.id
    }

    /// README `resolve_latest_in_lineage` / `next_title_in_lineage`: newest harness `started_at` → ``SessionCatalogRecord.createdAt``; tie-break `total` → ``messageCount``; then ``id`` lexicographic DESC.
    static func newestLineageRecord(records: [SessionCatalogRecord], baseTitle normalizedBase: String, lifecycleState: String?) -> SessionCatalogRecord? {
        let candidates = records.filter { record in
            guard let t = record.title else { return false }
            guard storedTitleMatchesLineage(baseTitle: normalizedBase, storedTitle: t) else { return false }
            if let lifecycleState {
                guard record.lifecycleStateRaw == lifecycleState else { return false }
            }
            return true
        }
        return candidates.max(by: { lineageIsLess($0, $1) })
    }

    /// README `next_title_in_lineage`: stored title of the winning lineage row (optional lifecycle filter matches ``resolveSessionByTitle``).
    static func newestLineageTitle(records: [SessionCatalogRecord], baseTitle normalizedBase: String, lifecycleState: String? = nil) -> String? {
        newestLineageRecord(records: records, baseTitle: normalizedBase, lifecycleState: lifecycleState)?.title
    }

    private static func lineageIsLess(_ a: SessionCatalogRecord, _ b: SessionCatalogRecord) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        if a.messageCount != b.messageCount { return a.messageCount < b.messageCount }
        return a.id.uuidString < b.id.uuidString
    }
}

/// Ensures a non-null catalog ``SessionCatalogRecord/title`` is unique per harness ``SessionCatalogRecord/agentId`` (v6 partial unique index), without failing the operation.
enum SessionCatalogTitleDisambiguation {
    /// Trims Unicode whitespace, clears null-like titles, or appends a random suffix until `title` is not in `occupiedNonNullTitles`.
    static func apply(to row: inout SessionCatalogRecord, occupiedNonNullTitles: Set<String>) {
        let source = row.title ?? row.topic
        guard let source else { return }
        let trimmed = SessionTitleResolution.sanitizedTitle(source)
        if trimmed.isEmpty {
            row.title = nil
            row.topic = nil
            return
        }
        var candidate = trimmed
        if occupiedNonNullTitles.contains(candidate) {
            repeat {
                candidate = "\(trimmed) \(UInt64.random(in: 0 ... UInt64.max))"
            } while occupiedNonNullTitles.contains(candidate)
        }
        row.title = candidate
        row.topic = candidate
    }
}
