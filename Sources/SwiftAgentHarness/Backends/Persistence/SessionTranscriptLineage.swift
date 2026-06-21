import Foundation

enum SessionTranscriptLineage {
    /// Walks `parentEntryId` from `leafEntryId` toward the root (leaf-first order).
    static func chainLeafToRoot(
        leafEntryId: SessionEntryID,
        entryById: [SessionEntryID: SessionTranscriptEntry],
        maxDepth: Int = 4096
    ) -> [SessionTranscriptEntry] {
        var chain: [SessionTranscriptEntry] = []
        var current = leafEntryId
        var seen = Set<SessionEntryID>()
        var depth = 0
        while depth < maxDepth {
            guard !seen.contains(current) else { break }
            seen.insert(current)
            guard let entry = entryById[current] else { break }
            chain.append(entry)
            guard let parent = entry.parentEntryId else { break }
            current = parent
            depth += 1
        }
        return chain
    }

    /// README `read_lineage`: root → leaf along the active branch.
    static func readLineageRootToLeaf(
        leafEntryId: SessionEntryID,
        entryById: [SessionEntryID: SessionTranscriptEntry],
        maxDepth: Int = 4096
    ) -> [SessionTranscriptEntry] {
        Array(chainLeafToRoot(leafEntryId: leafEntryId, entryById: entryById, maxDepth: maxDepth).reversed())
    }

    /// Returns true when `candidate` lies on the chain from `headEntryId` back to the root (inclusive).
    static func isAncestorOrSelf(
        candidate: SessionEntryID,
        headEntryId: SessionEntryID,
        entryById: [SessionEntryID: SessionTranscriptEntry],
        maxDepth: Int = 4096
    ) -> Bool {
        chainLeafToRoot(leafEntryId: headEntryId, entryById: entryById, maxDepth: maxDepth)
            .contains { $0.entryId == candidate }
    }

    static func chainLeafToRoot(
        leafEntryId: SessionEntryID,
        fetchEntry: (SessionEntryID) throws -> SessionTranscriptEntry?,
        maxDepth: Int = 4096
    ) throws -> [SessionTranscriptEntry] {
        var chain: [SessionTranscriptEntry] = []
        var current = leafEntryId
        var seen = Set<SessionEntryID>()
        var depth = 0
        while depth < maxDepth {
            guard !seen.contains(current) else { break }
            seen.insert(current)
            guard let entry = try fetchEntry(current) else { break }
            chain.append(entry)
            guard let parent = entry.parentEntryId else { break }
            current = parent
            depth += 1
        }
        return chain
    }

    static func readLineageRootToLeaf(
        leafEntryId: SessionEntryID,
        fetchEntry: (SessionEntryID) throws -> SessionTranscriptEntry?,
        maxDepth: Int = 4096
    ) throws -> [SessionTranscriptEntry] {
        Array(try chainLeafToRoot(leafEntryId: leafEntryId, fetchEntry: fetchEntry, maxDepth: maxDepth).reversed())
    }

    static func isAncestorOrSelf(
        candidate: SessionEntryID,
        headEntryId: SessionEntryID,
        fetchEntry: (SessionEntryID) throws -> SessionTranscriptEntry?,
        maxDepth: Int = 4096
    ) throws -> Bool {
        try chainLeafToRoot(leafEntryId: headEntryId, fetchEntry: fetchEntry, maxDepth: maxDepth)
            .contains { $0.entryId == candidate }
    }
}
