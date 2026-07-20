import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("MemoryInjectionSnapshot projection cache policy")
struct MemoryInjectionSnapshotProjectionPolicyTests {
  private let fingerprint = MemoryInjectionSnapshotProjectionPolicy.selectorConfigFingerprint(config: .default)

  @Test("selection context matches only on exact raw transcript equality")
  func exactContextMatch() {
    let ids = [UUID(), UUID(), UUID()]
    #expect(
      MemoryInjectionSnapshotProjectionPolicy.selectionContextMatches(
        storedContext: ids,
        currentRawMessageIDs: ids
      )
    )
    #expect(
      !MemoryInjectionSnapshotProjectionPolicy.selectionContextMatches(
        storedContext: ids,
        currentRawMessageIDs: ids + [UUID()]
      )
    )
  }

  @Test("selection context prefix helper allows growth for legacy compaction-style checks")
  func prefixMatch() {
    let ids = [UUID(), UUID(), UUID()]
    #expect(
      MemoryInjectionSnapshotProjectionPolicy.selectionContextPrefixMatches(
        storedPrefix: ids,
        currentRawMessageIDs: ids + [UUID()]
      )
    )
  }

  @Test("selection context prefix rejects truncated or altered transcript")
  func prefixMismatch() {
    let ids = [UUID(), UUID()]
    #expect(
      !MemoryInjectionSnapshotProjectionPolicy.selectionContextPrefixMatches(
        storedPrefix: ids,
        currentRawMessageIDs: [ids[0]]
      )
    )
    #expect(
      !MemoryInjectionSnapshotProjectionPolicy.selectionContextPrefixMatches(
        storedPrefix: ids,
        currentRawMessageIDs: [ids[0], UUID()]
      )
    )
  }

  @Test("decode selectedSelectionKeys from snapshot JSON")
  func decodeSelectedKeys() throws {
    let keys = ["topic-a.md", "user/prefs.md"]
    let json = MemoryStoreSnapshotJSON(
      memoryEntryIDs: [UUID()],
      memoryStoreVersion: 2,
      selectedSelectionKeys: keys,
      projectedSelectionKeys: ["topic-a.md"]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(json)
    let snapshotJSON = try #require(String(data: data, encoding: .utf8))
    let wire = MemoryInjectionSnapshotCheckpointWire(
      schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
      basedOnEventID: 1,
      injectionFingerprint: "fp",
      snapshotJSON: snapshotJSON,
      scopeMessageIDs: [UUID()],
      memoryStoreVersion: 2,
      selectorConfigFingerprint: fingerprint,
      selectionContextMessageIDs: [UUID()],
      createdAt: Date()
    )
    #expect(MemoryInjectionSnapshotProjectionPolicy.cachedSelectedSelectionKeys(from: wire) == keys)
  }

  @Test("legacy snapshot without selectedSelectionKeys is not a projection cache hit")
  func legacySnapshotMisses() {
    let contextID = UUID()
    let wire = MemoryInjectionSnapshotCheckpointWire(
      schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
      basedOnEventID: 1,
      injectionFingerprint: "legacy",
      snapshotJSON: "{\"memoryEntryIDs\":[],\"memoryStoreVersion\":1,\"projectedSelectionKeys\":[\"a.md\"]}",
      scopeMessageIDs: [UUID()],
      memoryStoreVersion: 1,
      selectorConfigFingerprint: fingerprint,
      selectionContextMessageIDs: [contextID],
      createdAt: Date()
    )
    #expect(
      !MemoryInjectionSnapshotProjectionPolicy.isProjectionCacheHit(
        wire: wire,
        currentRawMessageIDs: [contextID],
        expectedMemoryStoreVersion: 1,
        expectedSelectorConfigFingerprint: fingerprint
      )
    )
  }

  @Test("store version and selector fingerprint gate cache hits")
  func versionAndFingerprintGates() throws {
    let contextID = UUID()
    let keys = ["topic.md"]
    let snapshotJSON = try encodeSnapshot(keys: keys, version: 3)
    let wire = MemoryInjectionSnapshotCheckpointWire(
      schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
      basedOnEventID: 1,
      injectionFingerprint: "fp",
      snapshotJSON: snapshotJSON,
      scopeMessageIDs: [UUID()],
      memoryStoreVersion: 3,
      selectorConfigFingerprint: fingerprint,
      selectionContextMessageIDs: [contextID],
      createdAt: Date()
    )
    #expect(
      MemoryInjectionSnapshotProjectionPolicy.isProjectionCacheHit(
        wire: wire,
        currentRawMessageIDs: [contextID],
        expectedMemoryStoreVersion: 3,
        expectedSelectorConfigFingerprint: fingerprint
      )
    )
    #expect(
      !MemoryInjectionSnapshotProjectionPolicy.isProjectionCacheHit(
        wire: wire,
        currentRawMessageIDs: [contextID],
        expectedMemoryStoreVersion: 4,
        expectedSelectorConfigFingerprint: fingerprint
      )
    )
    #expect(
      !MemoryInjectionSnapshotProjectionPolicy.isProjectionCacheHit(
        wire: wire,
        currentRawMessageIDs: [contextID],
        expectedMemoryStoreVersion: 3,
        expectedSelectorConfigFingerprint: "other-fingerprint"
      )
    )
  }

  private func encodeSnapshot(keys: [String], version: Int) throws -> String {
    let json = MemoryStoreSnapshotJSON(
      memoryEntryIDs: [UUID()],
      memoryStoreVersion: version,
      selectedSelectionKeys: keys
    )
    let data = try JSONEncoder().encode(json)
    return try #require(String(data: data, encoding: .utf8))
  }
}
