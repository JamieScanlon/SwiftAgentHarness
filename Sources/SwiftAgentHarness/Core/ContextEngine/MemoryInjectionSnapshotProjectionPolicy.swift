import Foundation

/// Validity and fingerprint helpers for Tier-2 `MemoryInjectionSnapshot` projection cache (MI6).
enum MemoryInjectionSnapshotProjectionPolicy {
    /// Bump when selector rules or post-filter semantics change materially.
    private static let policyRevision = "memory_recall_selector_v1"
    private static let llmThreshold = 30

    static func selectorConfigFingerprint(config: MemoryConfiguration) -> String {
        [
            policyRevision,
            String(config.recallSelectorHeuristicMinScore),
            String(llmThreshold),
            config.recallSelectorModel,
            config.recallSelectorOllamaServerURL.absoluteString,
        ].joined(separator: "|")
    }

    static func decodeStoreSnapshot(from snapshotJSON: String) -> MemoryStoreSnapshotJSON? {
        guard let data = snapshotJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MemoryStoreSnapshotJSON.self, from: data)
    }

    /// Stored selection context must match the current raw transcript exactly (new user messages invalidate).
    static func selectionContextMatches(
        storedContext: [UUID],
        currentRawMessageIDs: [UUID]
    ) -> Bool {
        !storedContext.isEmpty && storedContext == currentRawMessageIDs
    }

    /// Legacy prefix helper retained for tests documenting compaction-style semantics.
    static func selectionContextPrefixMatches(
        storedPrefix: [UUID],
        currentRawMessageIDs: [UUID]
    ) -> Bool {
        guard !storedPrefix.isEmpty else { return false }
        let k = storedPrefix.count
        guard currentRawMessageIDs.count >= k else { return false }
        return Array(currentRawMessageIDs.prefix(k)) == storedPrefix
    }

    static func resolvedSelectionContextPrefix(from wire: MemoryInjectionSnapshotCheckpointWire) -> [UUID]? {
        if let ids = wire.selectionContextMessageIDs, !ids.isEmpty {
            return ids
        }
        return nil
    }

    static func cachedSelectedSelectionKeys(from wire: MemoryInjectionSnapshotCheckpointWire) -> [String]? {
        guard let snapshot = decodeStoreSnapshot(from: wire.snapshotJSON) else { return nil }
        if let keys = snapshot.selectedSelectionKeys, !keys.isEmpty {
            return keys
        }
        return nil
    }

    static func isProjectionCacheHit(
        wire: MemoryInjectionSnapshotCheckpointWire,
        currentRawMessageIDs: [UUID],
        expectedMemoryStoreVersion: Int,
        expectedSelectorConfigFingerprint: String
    ) -> Bool {
        guard wire.memoryStoreVersion == expectedMemoryStoreVersion else { return false }
        guard wire.selectorConfigFingerprint == expectedSelectorConfigFingerprint else { return false }
        guard let context = resolvedSelectionContextPrefix(from: wire) else { return false }
        guard selectionContextMatches(storedContext: context, currentRawMessageIDs: currentRawMessageIDs) else {
            return false
        }
        return cachedSelectedSelectionKeys(from: wire) != nil
    }

    static func injectionFingerprintInput(
        phaseRaw: String,
        conversationID: UUID,
        memoryStoreVersion: Int,
        injectedMemoryEntryIDs: [UUID],
        selectedSelectionKeys: [String],
        projectedSelectionKeys: [String],
        selectionContextMessageIDs: [UUID],
        selectorConfigFingerprint: String
    ) -> String {
        let entrySig = injectedMemoryEntryIDs.map(\.uuidString).joined(separator: ",")
        let selectedSig = selectedSelectionKeys.joined(separator: ",")
        let projectedSig = projectedSelectionKeys.joined(separator: ",")
        let contextSig = selectionContextMessageIDs.map(\.uuidString).joined(separator: ",")
        return [
            "v4",
            phaseRaw,
            conversationID.uuidString,
            String(memoryStoreVersion),
            entrySig,
            selectedSig,
            projectedSig,
            contextSig,
            selectorConfigFingerprint,
        ].joined(separator: "|")
    }
}
