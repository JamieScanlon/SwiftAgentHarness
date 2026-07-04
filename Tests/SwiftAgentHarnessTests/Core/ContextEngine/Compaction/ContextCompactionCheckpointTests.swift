import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Behavioral tests for compaction checkpoints: invalid data must never produce a “half-applied” incremental view.
@Suite("ContextCompactionCheckpoint")
struct ContextCompactionCheckpointTests {
    private func makeConfig() -> ContextCompactionConfiguration {
        ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
    }

    private func syn(_ id: UUID = UUID(), _ content: String = "s") -> ContextCompactionMessageDTO {
        ContextCompactionMessageDTO(id: id, role: "assistant", content: content)
    }

    private func assertToolCallPairIntegrity(_ messages: [Message]) {
        var outstanding: [String: Int] = [:]
        for message in messages {
            if message.role == .assistant {
                for toolCall in message.toolCalls {
                    if let id = toolCall.id, !id.isEmpty {
                        outstanding[id, default: 0] += 1
                    }
                }
            } else if message.role == .tool, let toolCallID = message.toolCallId, !toolCallID.isEmpty {
                #expect((outstanding[toolCallID] ?? 0) > 0, "Tool message without matching assistant tool_call id \(toolCallID)")
                outstanding[toolCallID, default: 0] -= 1
            }
        }
        let leftover = outstanding.filter { $0.value != 0 }
        #expect(leftover.isEmpty, "Unmatched assistant tool_calls: \(leftover)")
    }

    // MARK: - Selection / validity

    @Test("Idempotency helper finds matching valid checkpoint by coverage and synthesis")
    func idempotentHelperMatchesDuplicateProposal() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID()
        let syn1 = ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "syn")
        let checkpoint = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 10,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1, id2],
                    syntheticMessages: [syn1, syn1],
                    configFingerprint: fp,
                    basedOnEventID: 9,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let match = ContextCompactionCheckpointSupport.matchingIdempotentContextCompactionCheckpointEventID(
            events: [checkpoint],
            coveredMessageIDs: [id1, id2],
            syntheticMessages: [syn1, syn1],
            kind: .summarized,
            configFingerprint: fp
        )
        #expect(match == 10)
    }

    @Test("Idempotency helper returns nil when synthesis differs")
    func idempotentHelperNilWhenSyntheticDiffers() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID()
        let synA = ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "a")
        let synB = ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "b")
        let checkpoint = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 10,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [synA],
                    configFingerprint: fp,
                    basedOnEventID: 9,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let match = ContextCompactionCheckpointSupport.matchingIdempotentContextCompactionCheckpointEventID(
            events: [checkpoint],
            coveredMessageIDs: [id1],
            syntheticMessages: [synB],
            kind: .summarized,
            configFingerprint: fp
        )
        #expect(match == nil)
    }

    @Test("Idempotency helper ignores checkpoints at or below invalidation floor")
    func idempotentHelperNilWhenFloored() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID()
        let syn1 = ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "syn")
        let checkpoint = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [syn1],
                    configFingerprint: fp,
                    basedOnEventID: 4,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let invalidation = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 20,
            kind: ConversationEventKind.checkpointInvalidated.rawValue,
            payloadJSON: ConversationEventCodec.encode(CheckpointInvalidatedEventPayload(kinds: ["context_compaction"])),
            createdAt: Date()
        )
        let match = ContextCompactionCheckpointSupport.matchingIdempotentContextCompactionCheckpointEventID(
            events: [checkpoint, invalidation],
            coveredMessageIDs: [id1],
            syntheticMessages: [syn1],
            kind: .summarized,
            configFingerprint: fp
        )
        #expect(match == nil)
    }

    @Test("Selects highest eventID among valid checkpoints")
    func latestValidCheckpointSelectsNewestValid() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
            Message(id: id3, role: .user, content: "c", timestamp: Date(), toolCalls: []),
        ]
        let older = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [syn()],
                    configFingerprint: fp,
                    basedOnEventID: 4,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let newer = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 10,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1, id2],
                    syntheticMessages: [syn(), syn()],
                    configFingerprint: fp,
                    basedOnEventID: 9,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let result = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [older, newer],
            rawMiddle: middle,
            config: config
        )
        #expect(result?.eventID == 10)
        #expect(result?.payload.coveredMessageIDs == [id1, id2])
    }

    @Test("checkpoint_invalidated floors older compaction checkpoints but keeps newer ones")
    func invalidationEventIgnoresCheckpointsAtOrBelowFloor() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
            Message(id: id3, role: .user, content: "c", timestamp: Date(), toolCalls: []),
        ]
        let superseded = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [syn()],
                    configFingerprint: fp,
                    basedOnEventID: 4,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let invalidation = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 8,
            kind: ConversationEventKind.checkpointInvalidated.rawValue,
            payloadJSON: ConversationEventCodec.encode(CheckpointInvalidatedEventPayload(kinds: ["context_compaction"])),
            createdAt: Date()
        )
        let afterInvalidation = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 12,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1, id2],
                    syntheticMessages: [syn(), syn()],
                    configFingerprint: fp,
                    basedOnEventID: 10,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let result = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [superseded, invalidation, afterInvalidation],
            rawMiddle: middle,
            config: config
        )
        #expect(result?.eventID == 12)
    }

    @Test("When all compaction checkpoints are before invalidation floor, selection is nil")
    func invalidationEliminatesCheckpoints() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
        ]
        let checkpoint = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [syn()],
                    configFingerprint: fp,
                    basedOnEventID: 4,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let invalidation = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 20,
            kind: ConversationEventKind.checkpointInvalidated.rawValue,
            payloadJSON: ConversationEventCodec.encode(CheckpointInvalidatedEventPayload(kinds: ["context_compaction"])),
            createdAt: Date()
        )
        let result = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [checkpoint, invalidation],
            rawMiddle: middle,
            config: config
        )
        #expect(result == nil)
    }

    @Test("cache_aware_pruning invalidation supersedes compaction checkpoints")
    func cacheAwareInvalidationEliminatesCompactionCheckpoint() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
        ]
        let checkpoint = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [syn()],
                    configFingerprint: fp,
                    basedOnEventID: 4,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let invalidation = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 8,
            kind: ConversationEventKind.checkpointInvalidated.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                CheckpointInvalidatedEventPayload(kinds: [HarnessCheckpointInvalidationKind.cacheAwarePruning])
            ),
            createdAt: Date()
        )
        let result = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [checkpoint, invalidation],
            rawMiddle: middle,
            config: config
        )
        #expect(result == nil)
    }

    @Test("Latest checkpoint selection is parity-stable after superseded rows are physically pruned")
    func latestCheckpointParityAfterSupersededPrune() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
            Message(id: id3, role: .user, content: "c", timestamp: Date(), toolCalls: []),
        ]
        let superseded = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [syn()],
                    configFingerprint: fp,
                    basedOnEventID: 4,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let invalidation = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 8,
            kind: ConversationEventKind.checkpointInvalidated.rawValue,
            payloadJSON: ConversationEventCodec.encode(CheckpointInvalidatedEventPayload(kinds: [HarnessCheckpointInvalidationKind.contextCompaction])),
            createdAt: Date()
        )
        let latest = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 12,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1, id2],
                    syntheticMessages: [syn(), syn()],
                    configFingerprint: fp,
                    basedOnEventID: 10,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let withSuperseded = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [superseded, invalidation, latest],
            rawMiddle: middle,
            config: config
        )
        let afterPhysicalPrune = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [invalidation, latest],
            rawMiddle: middle,
            config: config
        )
        #expect(withSuperseded?.eventID == 12)
        #expect(afterPhysicalPrune?.eventID == 12)
        #expect(withSuperseded?.payload.coveredMessageIDs == afterPhysicalPrune?.payload.coveredMessageIDs)
    }

    @Test("Wrong config fingerprint rejects checkpoint so caller uses full raw middle")
    func wrongFingerprintIgnored() {
        var config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
        ]
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 99,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1, id2],
                    syntheticMessages: [syn(), syn()],
                    configFingerprint: fp,
                    basedOnEventID: 1,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        config.model = "different-model"
        let result = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [event],
            rawMiddle: middle,
            config: config
        )
        #expect(result == nil)
    }

    @Test("Covered IDs must match raw prefix order — subset in wrong order is rejected")
    func wrongOrderPrefixRejected() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
            Message(id: id3, role: .user, content: "c", timestamp: Date(), toolCalls: []),
        ]
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 1,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id2, id1],
                    syntheticMessages: [syn(), syn()],
                    configFingerprint: fp,
                    basedOnEventID: 0,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let result = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [event],
            rawMiddle: middle,
            config: config
        )
        #expect(result == nil)
    }

    @Test("Malformed payload skips event and can still match an older valid checkpoint")
    func malformedPayloadSkipsToOlderValid() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
        ]
        let bad = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 20,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: "{not json",
            createdAt: Date()
        )
        let good = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 15,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1, id2],
                    syntheticMessages: [syn(), syn()],
                    configFingerprint: fp,
                    basedOnEventID: 1,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let result = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [bad, good],
            rawMiddle: middle,
            config: config
        )
        #expect(result?.eventID == 15)
    }

    @Test("Synthetic count must match covered ID count or checkpoint is ignored")
    func mismatchedSyntheticVsCoveredCountRejected() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID(), id2 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
        ]
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 3,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1, id2],
                    syntheticMessages: [syn()],
                    configFingerprint: fp,
                    basedOnEventID: 1,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        #expect(
            ContextCompactionCheckpointSupport.latestValidCheckpoint(
                events: [event],
                rawMiddle: middle,
                config: config
            ) == nil
        )
    }

    @Test("Schema version mismatch rejects checkpoint")
    func wrongSchemaVersionRejected() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
        ]
        let valid = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [id1],
            syntheticMessages: [syn()],
            configFingerprint: fp,
            basedOnEventID: 0,
            createdAt: Date()
        )
        let json = ConversationEventCodec.encode(valid)
            .replacingOccurrences(of: "\"schemaVersion\":\(ContextCompactionCheckpointPayload.currentSchemaVersion)", with: "\"schemaVersion\":999")
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 1,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: json,
            createdAt: Date()
        )
        #expect(
            ContextCompactionCheckpointSupport.latestValidCheckpoint(
                events: [event],
                rawMiddle: middle,
                config: config
            ) == nil
        )
    }

    // MARK: - effectiveMiddle

    @Test("Effective middle prepends one synthetic per covered raw message, then raw tail")
    func effectiveMiddleIncremental() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let rawMiddle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
            Message(id: id3, role: .user, content: "c", timestamp: Date(), toolCalls: []),
        ]
        let synId1 = UUID(), synId2 = UUID()
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [id1, id2],
            syntheticMessages: [
                ContextCompactionMessageDTO(id: synId1, role: "assistant", content: "S1"),
                ContextCompactionMessageDTO(id: synId2, role: "user", content: "S2"),
            ],
            configFingerprint: ContextCompactionCheckpointSupport.configFingerprint(makeConfig()),
            basedOnEventID: 1,
            createdAt: Date()
        )
        let (mid, inc) = ContextCompactionCheckpointSupport.effectiveMiddle(
            rawMiddle: rawMiddle,
            checkpoint: payload
        )
        #expect(inc == true)
        #expect(mid.count == 3)
        #expect(mid[0].content == "S1")
        #expect(mid[1].content == "S2")
        #expect(mid[2].id == id3)
    }

    @Test("When synthetic count does not match covered count, effectiveMiddle falls back to raw (no incremental)")
    func effectiveMiddleMismatchedCountsFallsBack() {
        let id1 = UUID(), id2 = UUID()
        let rawMiddle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
        ]
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [id1, id2],
            syntheticMessages: [syn()],
            configFingerprint: ContextCompactionCheckpointSupport.configFingerprint(makeConfig()),
            basedOnEventID: 1,
            createdAt: Date()
        )
        let (mid, inc) = ContextCompactionCheckpointSupport.effectiveMiddle(
            rawMiddle: rawMiddle,
            checkpoint: payload
        )
        #expect(inc == false)
        #expect(mid.map(\.id) == rawMiddle.map(\.id))
    }

    @Test("Full coverage (tail empty) yields only synthetic messages")
    func effectiveMiddleFullCoverage() {
        let id1 = UUID(), id2 = UUID()
        let rawMiddle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
        ]
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [id1, id2],
            syntheticMessages: [
                ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "only"),
                ContextCompactionMessageDTO(id: UUID(), role: "user", content: "syn"),
            ],
            configFingerprint: ContextCompactionCheckpointSupport.configFingerprint(makeConfig()),
            basedOnEventID: 1,
            createdAt: Date()
        )
        let (mid, inc) = ContextCompactionCheckpointSupport.effectiveMiddle(
            rawMiddle: rawMiddle,
            checkpoint: payload
        )
        #expect(inc == true)
        #expect(mid.count == 2)
        #expect(mid[0].content == "only")
        #expect(mid[1].content == "syn")
    }

    @Test("Empty raw middle: no checkpoint applies; effectiveMiddle stays empty")
    func emptyRawMiddle() {
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [UUID()],
            syntheticMessages: [syn()],
            configFingerprint: ContextCompactionCheckpointSupport.configFingerprint(makeConfig()),
            basedOnEventID: 1,
            createdAt: Date()
        )
        let (mid, inc) = ContextCompactionCheckpointSupport.effectiveMiddle(
            rawMiddle: [],
            checkpoint: payload
        )
        #expect(inc == false)
        #expect(mid.isEmpty)
    }

    @Test("effectiveMiddle preserves tool-pair integrity across synthetic prefix and raw tail")
    func effectiveMiddlePreservesToolPairsWithSyntheticPrefix() {
        let toolCallID = "tc-effective-middle-1"
        let coveredAssistantID = UUID()
        let coveredToolID = UUID()
        let rawTailUserID = UUID()
        let rawMiddle = [
            Message(
                id: coveredAssistantID,
                role: .assistant,
                content: "calling",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "web-fetch", arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: coveredToolID,
                role: .tool,
                content: "payload",
                timestamp: Date(),
                toolCalls: [],
                toolCallId: toolCallID
            ),
            Message(id: rawTailUserID, role: .user, content: "tail", timestamp: Date(), toolCalls: []),
        ]
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .pruned,
            coveredMessageIDs: [coveredAssistantID, coveredToolID],
            syntheticMessages: [
                ContextCompactionMessageDTO.prunedDTO(from: rawMiddle[0]),
                ContextCompactionMessageDTO.prunedDTO(from: rawMiddle[1]),
            ],
            configFingerprint: ContextCompactionCheckpointSupport.configFingerprint(makeConfig()),
            basedOnEventID: 1,
            createdAt: Date()
        )
        let (effective, incremental) = ContextCompactionCheckpointSupport.effectiveMiddle(
            rawMiddle: rawMiddle,
            checkpoint: payload
        )
        #expect(incremental == true)
        #expect(effective.count == 3)
        assertToolCallPairIntegrity(effective)
    }

    // MARK: - Gates

    @Test("Gate: skips when under minimum character budget")
    func gateMinCharacters() {
        var config = makeConfig()
        config.middleMinCharactersForCompactionLLM = 1000
        let tiny = [
            Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: []),
        ]
        let allow = ContextCompactionCheckpointSupport.shouldRunCompactionLLM(
            rawMiddle: tiny,
            config: config,
            conversationID: UUID(),
            lastLLMDateByConversationID: [:]
        )
        #expect(allow == false)
    }

    @Test("Gate: allows when character count meets threshold exactly")
    func gateMinCharactersBoundaryAllows() {
        var config = makeConfig()
        config.middleMinCharactersForCompactionLLM = 10
        let content = String(repeating: "x", count: 10)
        let mid = [
            Message(id: UUID(), role: .user, content: content, timestamp: Date(), toolCalls: []),
        ]
        let allow = ContextCompactionCheckpointSupport.shouldRunCompactionLLM(
            rawMiddle: mid,
            config: config,
            conversationID: UUID(),
            lastLLMDateByConversationID: [:]
        )
        #expect(allow == true)
    }

    @Test("Gate: cooldown blocks until interval elapsed")
    func gateCooldown() {
        var config = makeConfig()
        config.compactionLLMCooldownSeconds = 10_000
        let cid = UUID()
        let mid = [
            Message(id: UUID(), role: .user, content: String(repeating: "a", count: 100), timestamp: Date(), toolCalls: []),
        ]
        let recent: [UUID: Date] = [cid: Date()]
        #expect(
            ContextCompactionCheckpointSupport.shouldRunCompactionLLM(
                rawMiddle: mid,
                config: config,
                conversationID: cid,
                lastLLMDateByConversationID: recent
            ) == false
        )
        let old: [UUID: Date] = [cid: Date(timeIntervalSince1970: 0)]
        #expect(
            ContextCompactionCheckpointSupport.shouldRunCompactionLLM(
                rawMiddle: mid,
                config: config,
                conversationID: cid,
                lastLLMDateByConversationID: old
            ) == true
        )
    }

    // MARK: - Fingerprint & codec

    @Test("Config fingerprint changes when compaction-shaping fields change")
    func fingerprintReflectsCompactionShape() {
        let a = makeConfig()
        var b = makeConfig()
        b.proactiveSafetyBufferTokens = 99_000
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.maxCompactedMiddleMessages = 7
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.ollamaServerURL = URL(string: "http://127.0.0.1:11434")!
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.toolResultPruneReplacementMode = b.toolResultPruneReplacementMode == .blankMarker ? .oneLineSummary : .blankMarker
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.compactionToolResultPruneNames = ["web-search"]
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.maxRecentToolResults = 20
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.maxRecentPerNameToolResults = 11
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.compactionSummarizerContextLimitTokens = 99_000
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.deterministicToolResultPruningEnabled = false
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.deterministicAttachmentDocumentHygieneEnabled = true
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.deterministicMaxImagesPerMessage = 1
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.deterministicDocumentCharacterThreshold = 321
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.deterministicDocumentPlaceholder = "[doc-h]"
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
        b = makeConfig()
        b.deterministicImagePlaceholder = "[img-h]"
        #expect(ContextCompactionCheckpointSupport.configFingerprint(a) != ContextCompactionCheckpointSupport.configFingerprint(b))
    }

    @Test("Checkpoint with basedOnEventID above loaded frontier is rejected")
    func checkpointCausalityRejectsAheadOfFrontier() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
        ]
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [syn()],
                    configFingerprint: fp,
                    basedOnEventID: 100,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        #expect(
            ContextCompactionCheckpointSupport.latestValidCheckpoint(
                events: [event],
                rawMiddle: middle,
                config: config
            ) == nil
        )
    }

    @Test("Explicit frontier can admit basedOn above batch max eventID")
    func latestValidCheckpointExplicitFrontierAdmitsCausalTail() {
        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let id1 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
        ]
        let syntheticID = UUID()
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [syn(syntheticID)],
                    configFingerprint: fp,
                    basedOnEventID: 100,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        #expect(
            ContextCompactionCheckpointSupport.latestValidCheckpoint(
                events: [event],
                rawMiddle: middle,
                config: config
            ) == nil
        )
        let admitted = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [event],
            rawMiddle: middle,
            config: config,
            frontierEventID: 100
        )
        #expect(admitted?.eventID == 5)
        #expect(admitted?.payload.basedOnEventID == 100)
    }

    @Test("Payload round-trips through ConversationEventCodec")
    func payloadCodecRoundTrip() throws {
        let id1 = UUID()
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [id1],
            syntheticMessages: [ContextCompactionMessageDTO(id: UUID(), role: "tool", content: "τ")],
            configFingerprint: "fp",
            basedOnEventID: 42,
            createdAt: Date()
        )
        let json = ConversationEventCodec.encode(payload)
        let decoded = try #require(ConversationEventCodec.decode(ContextCompactionCheckpointPayload.self, from: json))
        #expect(decoded.coveredMessageIDs == [id1])
        #expect(decoded.syntheticMessages.count == 1)
        #expect(decoded.syntheticMessages[0].role == "tool")
        #expect(decoded.syntheticMessages[0].content == "τ")
        #expect(decoded.basedOnEventID == 42)
    }

    // MARK: - Kind round-trip

    @Test("Current-schema payload with kind = .summarized round-trips through encode/decode")
    func v2SummarizedKindRoundTrip() throws {
        // ISO8601 with default decoding strategy truncates fractional seconds; pin to whole-second
        // resolution so the round-tripped Date compares equal under the synthesized Equatable.
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let dto = ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "summary")
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [UUID()],
            syntheticMessages: [dto],
            configFingerprint: "fp",
            basedOnEventID: 11,
            createdAt: createdAt
        )
        let json = ConversationEventCodec.encode(payload)
        let decoded = try #require(ConversationEventCodec.decode(ContextCompactionCheckpointPayload.self, from: json))
        #expect(decoded.kind == .summarized)
        #expect(decoded.schemaVersion == ContextCompactionCheckpointPayload.currentSchemaVersion)
        #expect(decoded == payload)
    }

    @Test("Current-schema payload with kind = .pruned round-trips through encode/decode")
    func v2PrunedKindRoundTrip() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let dto = ContextCompactionMessageDTO(id: UUID(), role: "tool", content: "[pruned]", toolCallId: "tc-1")
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .pruned,
            coveredMessageIDs: [UUID()],
            syntheticMessages: [dto],
            configFingerprint: "fp",
            basedOnEventID: 21,
            createdAt: createdAt
        )
        let json = ConversationEventCodec.encode(payload)
        let decoded = try #require(ConversationEventCodec.decode(ContextCompactionCheckpointPayload.self, from: json))
        #expect(decoded.kind == .pruned)
        #expect(decoded == payload)
    }

    @Test("ContextCompactionMessageDTO with toolCalls and toolCallId round-trips through JSON")
    func dtoToolCallsAndToolCallIdRoundTrip() throws {
        let tool = ToolCall(
            name: "web-fetch",
            arguments: .object(["url": .string("https://example.com")]),
            id: "tc-abc"
        )
        let dto = ContextCompactionMessageDTO(
            id: UUID(),
            role: "assistant",
            content: "calling tool",
            toolCalls: [tool],
            toolCallId: nil
        )
        let toolDTO = ContextCompactionMessageDTO(
            id: UUID(),
            role: "tool",
            content: "[pruned]",
            toolCalls: nil,
            toolCallId: "tc-abc"
        )
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .pruned,
            coveredMessageIDs: [dto.id, toolDTO.id],
            syntheticMessages: [dto, toolDTO],
            configFingerprint: "fp",
            basedOnEventID: 31,
            createdAt: Date()
        )
        let json = ConversationEventCodec.encode(payload)
        let decoded = try #require(ConversationEventCodec.decode(ContextCompactionCheckpointPayload.self, from: json))
        #expect(decoded.syntheticMessages.count == 2)
        let assistantOut = decoded.syntheticMessages[0]
        let toolOut = decoded.syntheticMessages[1]
        #expect(assistantOut == dto)
        #expect(toolOut == toolDTO)
        #expect(assistantOut.toolCalls?.count == 1)
        #expect(assistantOut.toolCalls?.first?.name == "web-fetch")
        #expect(assistantOut.toolCalls?.first?.id == "tc-abc")
        #expect(toolOut.toolCallId == "tc-abc")
    }

    @Test("ContextCompactionMessageDTO without toolCalls/toolCallId encodes minimally and round-trips")
    func dtoMinimalShapeRoundTrip() throws {
        let dto = ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "text")
        let encoder = JSONEncoder()
        let data = try encoder.encode(dto)
        let json = try #require(String(data: data, encoding: .utf8))
        // Optional fields should not be emitted (default JSONEncoder strategy omits nil for optional Codable fields)
        #expect(json.contains("\"toolCalls\"") == false)
        #expect(json.contains("\"toolCallId\"") == false)
        let decoded = try JSONDecoder().decode(ContextCompactionMessageDTO.self, from: data)
        #expect(decoded == dto)
        #expect(decoded.toolCalls == nil)
        #expect(decoded.toolCallId == nil)
    }

    @Test("prunedDTO factory preserves toolCalls and toolCallId from source Message")
    func prunedDTOPreservesToolFields() {
        let toolCall = ToolCall(name: "web-search", arguments: .object(["q": .string("hello")]), id: "tc-42")
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "calling search",
            timestamp: Date(),
            toolCalls: [toolCall]
        )
        let toolMsg = Message(
            id: UUID(),
            role: .tool,
            content: "[pruned]",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: "tc-42"
        )
        let assistantDTO = ContextCompactionMessageDTO.prunedDTO(from: assistant)
        let toolDTO = ContextCompactionMessageDTO.prunedDTO(from: toolMsg)
        #expect(assistantDTO.toolCalls?.count == 1)
        #expect(assistantDTO.toolCalls?.first?.id == "tc-42")
        #expect(assistantDTO.toolCallId == nil)
        #expect(toolDTO.toolCalls == nil)
        #expect(toolDTO.toolCallId == "tc-42")
        // Round-trip the rehydrated message preserves both sides of the tool call/result link.
        let rehydratedAssistant = assistantDTO.toMessage()
        let rehydratedTool = toolDTO.toMessage()
        #expect(rehydratedAssistant.toolCalls.first?.id == "tc-42")
        #expect(rehydratedTool.toolCallId == "tc-42")
    }

    @Test("syntheticMessagesForPersistence emits stripped DTOs for .summarized and rich DTOs for .pruned")
    func syntheticPersistenceVariesByKind() {
        let toolCall = ToolCall(name: "web-fetch", arguments: .object([:]), id: "tc-99")
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "x",
            timestamp: Date(),
            toolCalls: [toolCall]
        )
        let summarizedDTOs = ContextCompactionCheckpointSupport.syntheticMessagesForPersistence(
            from: [assistant],
            kind: .summarized
        )
        let prunedDTOs = ContextCompactionCheckpointSupport.syntheticMessagesForPersistence(
            from: [assistant],
            kind: .pruned
        )
        #expect(summarizedDTOs.count == 1)
        #expect(summarizedDTOs[0].toolCalls == nil)
        #expect(summarizedDTOs[0].toolCallId == nil)
        #expect(prunedDTOs.count == 1)
        #expect(prunedDTOs[0].toolCalls?.count == 1)
        #expect(prunedDTOs[0].toolCalls?.first?.id == "tc-99")
    }

    @Test("summarizedSyntheticDTOsForPersistence fans out single summary across covered raw middle")
    func summarizedSyntheticFanOutForPersistence() {
        let id1 = UUID(), id2 = UUID()
        let rawMiddle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
        ]
        let summary = Message(
            id: UUID(),
            role: .assistant,
            content: "## Active Task\nsummary body",
            timestamp: Date(),
            toolCalls: []
        )
        let dtos = ContextCompactionCheckpointSupport.summarizedSyntheticDTOsForPersistence(
            summaryMessages: [summary],
            coveredRawMiddle: rawMiddle,
            kind: .summarized
        )
        #expect(dtos.count == 2)
        #expect(dtos[0].content == summary.content)
        #expect(dtos[0].role == MessageRole.user.rawValue)
        #expect(dtos[1].role == MessageRole.assistant.rawValue)

        let config = makeConfig()
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [id1, id2],
            syntheticMessages: dtos,
            configFingerprint: fp,
            basedOnEventID: 1,
            createdAt: Date()
        )
        let (effective, incremental) = ContextCompactionCheckpointSupport.effectiveMiddle(
            rawMiddle: rawMiddle + [
                Message(id: UUID(), role: .user, content: "c", timestamp: Date(), toolCalls: []),
            ],
            checkpoint: payload
        )
        #expect(incremental == true)
        #expect(effective.count == 3)
        #expect(effective[0].content == summary.content)
        #expect(effective[1].content == summary.content)
        #expect(effective[2].content == "c")
    }

    @Test("rawMiddle is empty when transcript is not compressible")
    func rawMiddleIsEmptyWhenTranscriptIsNotCompressible() {
        let sys = UUID(), u1 = UUID(), a1 = UUID(), u2 = UUID(), a2 = UUID(), u3 = UUID()
        let messages = [
            Message(id: sys, role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: u1, role: .user, content: "1", timestamp: Date(), toolCalls: []),
            Message(id: a1, role: .assistant, content: "2", timestamp: Date(), toolCalls: []),
            Message(id: u2, role: .user, content: "3", timestamp: Date(), toolCalls: []),
            Message(id: a2, role: .assistant, content: "4", timestamp: Date(), toolCalls: []),
            Message(id: u3, role: .user, content: "5", timestamp: Date(), toolCalls: []),
        ]
        let config = ContextCompactionConfiguration.default
        let mid = ContextCompactionCheckpointSupport.rawMiddle(
            from: messages,
            config: config,
            modelContextLimitTokens: 200_000
        )
        #expect(mid.isEmpty)
        let segs = ContextCompactionCheckpointSupport.splitForCompaction(
            messages,
            config: config,
            modelContextLimitTokens: 200_000
        )
        #expect(segs.head.map(\.id) == [sys, u1, a1, u2, a2, u3])
        #expect(segs.middle.isEmpty)
        #expect(segs.tail.isEmpty)
    }

    @Test("meetsPromptTokenSavingsThreshold accepts savings at or above fraction")
    func meetsPromptTokenSavingsThresholdBoundary() {
        var config = makeConfig()
        config.compactionMinPromptTokenSavingsFraction = 0.1
        #expect(
            ContextCompactionCheckpointSupport.meetsPromptTokenSavingsThreshold(
                tokensBefore: 1000,
                tokensAfter: 899,
                config: config
            )
        )
        #expect(
            ContextCompactionCheckpointSupport.meetsPromptTokenSavingsThreshold(
                tokensBefore: 1000,
                tokensAfter: 900,
                config: config
            )
        )
        #expect(
            ContextCompactionCheckpointSupport.meetsPromptTokenSavingsThreshold(
                tokensBefore: 1000,
                tokensAfter: 901,
                config: config
            ) == false
        )
    }

    @Test("meetsPromptTokenSavingsThreshold disabled when fraction is zero")
    func meetsPromptTokenSavingsThresholdDisabled() {
        var config = makeConfig()
        config.compactionMinPromptTokenSavingsFraction = 0
        #expect(
            ContextCompactionCheckpointSupport.meetsPromptTokenSavingsThreshold(
                tokensBefore: 1000,
                tokensAfter: 1000,
                config: config
            )
        )
    }
}
