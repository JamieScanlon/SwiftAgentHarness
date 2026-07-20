import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("Harness checkpoint dispatch")
struct LatestCheckpointDispatchTests {
    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "chk:test",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    private func makeManager(container: ModelContainer) -> ConversationManager {
        let cm = ConversationManager(container: container)
        HarnessConversationTestFixtures.attachSharedInMemoryHarness(to: cm, container: container)
        return cm
    }

    private func makeCompactionConfig() -> ContextCompactionConfiguration {
        ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
    }

    @Test("Unknown harness kind yields nil from ConversationManager")
    func unknownKindNil() throws {
        let container = try makeContainer()
        let cm = makeManager(container: container)
        let conv = try cm.createConversation(
            with: makeModel(),
            userSystemPrompt: "s",
            topic: nil,
            description: nil,
            metadata: nil
        )
        let out = cm.latestCheckpointResponse(
            conversationID: conv.id,
            compactionConfig: makeCompactionConfig(),
            harnessCheckpointKind: "not_a_real_kind"
        )
        #expect(out == nil)
    }

    @Test("ConversationManager latestValidCheckpoint dispatches across four taxonomy kinds")
    func managerLatestValidCheckpointTaxonomyDispatch() throws {
        let container = try makeContainer()
        let cm = makeManager(container: container)
        let config = makeCompactionConfig()
        let rawID = UUID()
        let rawMessages = [Message(id: rawID, role: .user, content: "u", timestamp: Date(), toolCalls: [])]

        let compactionEvent = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 1,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [rawID],
                    syntheticMessages: [ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "s")],
                    configFingerprint: ContextCompactionCheckpointSupport.configFingerprint(config),
                    basedOnEventID: 0,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let memoryEvent = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 2,
            kind: ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                MemoryInjectionSnapshotCheckpointWire(
                    schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 0,
                    injectionFingerprint: "m-fp",
                    snapshotJSON: "{\"k\":1}",
                    scopeMessageIDs: [rawID],
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let toolTrimEvent = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 3,
            kind: ConversationEventKind.toolResultTrimCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ToolResultTrimCheckpointWire(
                    schemaVersion: ToolResultTrimCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 0,
                    coveredMessageIDs: [rawID],
                    trimmedToolCallIds: ["t1"],
                    configFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let systemPromptEvent = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 4,
            kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                SystemPromptAssemblyCheckpointWire(
                    schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 0,
                    assemblyFingerprint: "sys-fp",
                    replaySpecDigest: "replay-digest",
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )

        let compaction = cm.latestValidCheckpoint(
            kind: .contextCompaction,
            events: [compactionEvent],
            rawMiddle: rawMessages,
            compactionConfig: config,
            rawMessages: rawMessages,
            frontierEventID: 4
        )
        let memory = cm.latestValidCheckpoint(
            kind: .memoryInjectionSnapshot,
            events: [memoryEvent],
            rawMiddle: rawMessages,
            compactionConfig: config,
            rawMessages: rawMessages,
            frontierEventID: 4
        )
        let trim = cm.latestValidCheckpoint(
            kind: .toolResultTrim,
            events: [toolTrimEvent],
            rawMiddle: rawMessages,
            compactionConfig: config,
            rawMessages: rawMessages,
            frontierEventID: 4
        )
        let system = cm.latestValidCheckpoint(
            kind: .systemPromptAssembly,
            events: [systemPromptEvent],
            rawMiddle: rawMessages,
            compactionConfig: config,
            rawMessages: rawMessages,
            frontierEventID: 4
        )

        guard case .contextCompaction? = compaction else {
            Issue.record("expected compaction selection")
            return
        }
        guard case .memoryInjectionSnapshot? = memory else {
            Issue.record("expected memory injection selection")
            return
        }
        guard case .toolResultTrim? = trim else {
            Issue.record("expected tool trim selection")
            return
        }
        guard case .systemPromptAssembly? = system else {
            Issue.record("expected system prompt assembly selection")
            return
        }
    }

    @Test("Memory injection checkpoint round-trips through derived store and REST-shaped selection")
    func memoryInjectionLatest() throws {
        let container = try makeContainer()
        let cm = makeManager(container: container)
        let conv = try cm.createConversation(
            with: makeModel(),
            userSystemPrompt: "s",
            topic: nil,
            description: nil,
            metadata: nil
        )
        let rawMessageID = try #require(cm.rawMessages(conversationID: conv.id)?.first?.id)
        let derived = HarnessConversationTestFixtures.makeDerivedStore(container: container)
        let wireIn = MemoryInjectionSnapshotCheckpointWire(
            schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
            basedOnEventID: 0,
            injectionFingerprint: "test-fp",
            snapshotJSON: "{\"k\":1}",
            scopeMessageIDs: [rawMessageID],
            createdAt: Date()
        )
        try derived.appendMemoryInjectionSnapshotCheckpoint(
            conversationID: conv.id,
            wire: wireIn,
            expectedDerivedSequence: nil
        )
        let response = try #require(
            cm.latestCheckpointResponse(
                conversationID: conv.id,
                compactionConfig: makeCompactionConfig(),
                harnessCheckpointKind: HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue
            )
        )
        #expect(response.kind == HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue)
        guard case .memoryInjectionSnapshot(let w) = response.checkpoint else {
            Issue.record("expected memory injection payload")
            return
        }
        #expect(w.injectionFingerprint == "test-fp")
    }

    @Test("Latest memory injection selection rejects empty-scope wire")
    func memoryInjectionLatestRejectsEmptyScope() throws {
        let container = try makeContainer()
        let cm = makeManager(container: container)
        let conv = try cm.createConversation(
            with: makeModel(),
            userSystemPrompt: "s",
            topic: nil,
            description: nil,
            metadata: nil
        )
        let derived = HarnessConversationTestFixtures.makeDerivedStore(container: container)
        let wireIn = MemoryInjectionSnapshotCheckpointWire(
            schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
            basedOnEventID: 0,
            injectionFingerprint: "invalid-empty-scope",
            snapshotJSON: "{\"k\":1}",
            scopeMessageIDs: [],
            createdAt: Date()
        )
        try derived.appendMemoryInjectionSnapshotCheckpoint(
            conversationID: conv.id,
            wire: wireIn,
            expectedDerivedSequence: nil
        )
        let response = cm.latestCheckpointResponse(
            conversationID: conv.id,
            compactionConfig: makeCompactionConfig(),
            harnessCheckpointKind: HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue
        )
        #expect(response == nil)
    }

    @Test("Latest memory injection selection rejects scope IDs missing from raw transcript")
    func memoryInjectionLatestRejectsMissingRawScopeIDs() throws {
        let container = try makeContainer()
        let cm = makeManager(container: container)
        let conv = try cm.createConversation(
            with: makeModel(),
            userSystemPrompt: "s",
            topic: nil,
            description: nil,
            metadata: nil
        )
        let derived = HarnessConversationTestFixtures.makeDerivedStore(container: container)
        let missing = UUID()
        let wireIn = MemoryInjectionSnapshotCheckpointWire(
            schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
            basedOnEventID: 0,
            injectionFingerprint: "missing-raw-scope",
            snapshotJSON: "{\"k\":1}",
            scopeMessageIDs: [missing],
            createdAt: Date()
        )
        try derived.appendMemoryInjectionSnapshotCheckpoint(
            conversationID: conv.id,
            wire: wireIn,
            expectedDerivedSequence: nil
        )
        let response = cm.latestCheckpointResponse(
            conversationID: conv.id,
            compactionConfig: makeCompactionConfig(),
            harnessCheckpointKind: HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue
        )
        #expect(response == nil)
    }

    @Test("Latest memory injection selection applies expected memory store version filter")
    func memoryInjectionLatestExpectedStoreVersionFilter() {
        let rawMessageID = UUID()
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 10,
            kind: ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                MemoryInjectionSnapshotCheckpointWire(
                    schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    injectionFingerprint: "v-filter",
                    snapshotJSON: "{\"k\":1}",
                    scopeMessageIDs: [rawMessageID],
                    memoryStoreVersion: 7,
                    memoryStoreNamespaceKey: "ns",
                    memoryEntryIDs: [rawMessageID],
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let matched = LatestValidConversationCheckpoint.latestCheckpointSelection(
            kind: .memoryInjectionSnapshot,
            events: [event],
            rawMiddle: [],
            compactionConfig: makeCompactionConfig(),
            toolTrimConfigFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            rawMessages: [Message(id: rawMessageID, role: .user, content: "u", timestamp: Date(), toolCalls: [])],
            expectedMemoryStoreVersion: 7,
            frontierEventID: 10
        )
        guard case .memoryInjectionSnapshot(let wire, _) = matched else {
            Issue.record("expected memory selection with matching store version")
            return
        }
        #expect(wire.memoryStoreVersion == 7)

        let mismatched = LatestValidConversationCheckpoint.latestCheckpointSelection(
            kind: .memoryInjectionSnapshot,
            events: [event],
            rawMiddle: [],
            compactionConfig: makeCompactionConfig(),
            toolTrimConfigFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            rawMessages: [Message(id: rawMessageID, role: .user, content: "u", timestamp: Date(), toolCalls: [])],
            expectedMemoryStoreVersion: 99,
            frontierEventID: 10
        )
        #expect(mismatched == nil)
    }

    @Test("Latest tool-trim selection rejects empty checkpoint coverage")
    func toolTrimLatestRejectsEmptyCoverage() throws {
        let container = try makeContainer()
        let cm = makeManager(container: container)
        let conv = try cm.createConversation(
            with: makeModel(),
            userSystemPrompt: "s",
            topic: nil,
            description: nil,
            metadata: nil
        )
        let derived = HarnessConversationTestFixtures.makeDerivedStore(container: container)
        let wireIn = ToolResultTrimCheckpointWire(
            schemaVersion: ToolResultTrimCheckpointWire.currentSchemaVersion,
            basedOnEventID: 0,
            coveredMessageIDs: [],
            trimmedToolCallIds: [],
            configFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            createdAt: Date()
        )
        try derived.appendToolResultTrimCheckpoint(
            conversationID: conv.id,
            wire: wireIn,
            expectedDerivedSequence: nil
        )
        let response = cm.latestCheckpointResponse(
            conversationID: conv.id,
            compactionConfig: makeCompactionConfig(),
            harnessCheckpointKind: HarnessCheckpointWireKind.toolResultTrim.rawValue
        )
        #expect(response == nil)
    }

    @Test("Latest tool-trim selection rejects covered IDs missing from raw transcript")
    func toolTrimLatestRejectsMissingRawCoverage() throws {
        let container = try makeContainer()
        let cm = makeManager(container: container)
        let conv = try cm.createConversation(
            with: makeModel(),
            userSystemPrompt: "s",
            topic: nil,
            description: nil,
            metadata: nil
        )
        let derived = HarnessConversationTestFixtures.makeDerivedStore(container: container)
        let wireIn = ToolResultTrimCheckpointWire(
            schemaVersion: ToolResultTrimCheckpointWire.currentSchemaVersion,
            basedOnEventID: 0,
            coveredMessageIDs: [UUID()],
            trimmedToolCallIds: ["tool-call-1"],
            configFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            createdAt: Date()
        )
        try derived.appendToolResultTrimCheckpoint(
            conversationID: conv.id,
            wire: wireIn,
            expectedDerivedSequence: nil
        )
        let response = cm.latestCheckpointResponse(
            conversationID: conv.id,
            compactionConfig: makeCompactionConfig(),
            harnessCheckpointKind: HarnessCheckpointWireKind.toolResultTrim.rawValue
        )
        #expect(response == nil)
    }

    @Test("System prompt assembly selection supports expected fingerprint filtering")
    func systemPromptAssemblyExpectedFingerprintFilter() {
        let expected = "expected-fp"
        let matched = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 2,
            kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                SystemPromptAssemblyCheckpointWire(
                    schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    assemblyFingerprint: expected,
                    replaySpecDigest: "replay-digest",
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let mismatched = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 3,
            kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                SystemPromptAssemblyCheckpointWire(
                    schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    assemblyFingerprint: "other-fp",
                    replaySpecDigest: "replay-digest",
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let selected = LatestValidConversationCheckpoint.latestCheckpointSelection(
            kind: .systemPromptAssembly,
            events: [matched, mismatched],
            rawMiddle: [],
            compactionConfig: makeCompactionConfig(),
            toolTrimConfigFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            rawMessages: [],
            expectedSystemPromptAssemblyFingerprint: expected,
            frontierEventID: 3
        )
        guard case .systemPromptAssembly(let wire, let eventID) = selected else {
            Issue.record("expected system prompt assembly selection")
            return
        }
        #expect(eventID == 2)
        #expect(wire.assemblyFingerprint == expected)
    }

    @Test("System prompt assembly v2 wire preserves assembledPromptDigest")
    func systemPromptAssemblyV2DigestRoundTrip() {
        let digest = "abc123digest"
        let wire = SystemPromptAssemblyCheckpointWire(
            schemaVersion: 2,
            basedOnEventID: 1,
            assemblyFingerprint: "fp",
            assembledPromptDigest: digest,
            createdAt: Date()
        )
        let encoded = ConversationEventCodec.encode(wire)
        let decoded = ConversationEventCodec.decode(SystemPromptAssemblyCheckpointWire.self, from: encoded)
        #expect(decoded?.schemaVersion == 2)
        #expect(decoded?.assembledPromptDigest == digest)
        let events = [
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 1,
                kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
                payloadJSON: encoded,
                createdAt: Date()
            ),
        ]
        let latest = SuiteCheckpointSupport.latestValidSystemPromptAssembly(events: events, frontierEventID: 1)
        #expect(latest?.wire.assembledPromptDigest == digest)
    }

    @Test("ConversationCheckpoint.load decodes all durable kinds")
    func conversationCheckpointLoadAllKinds() throws {
        let id1 = UUID()
        let compactPayload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [id1],
            syntheticMessages: [ContextCompactionMessageDTO(id: UUID(), role: "a", content: "x")],
            configFingerprint: "fp",
            basedOnEventID: 1,
            createdAt: Date()
        )
        let mem = MemoryInjectionSnapshotCheckpointWire(
            schemaVersion: 1,
            basedOnEventID: 1,
            injectionFingerprint: "m",
            snapshotJSON: "{}",
            scopeMessageIDs: [],
            createdAt: Date()
        )
        let trim = ToolResultTrimCheckpointWire(
            schemaVersion: 1,
            basedOnEventID: 1,
            coveredMessageIDs: [id1],
            trimmedToolCallIds: ["t1"],
            configFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            createdAt: Date()
        )
        let prompt = SystemPromptAssemblyCheckpointWire(
            schemaVersion: 1,
            basedOnEventID: 1,
            assemblyFingerprint: "p",
            createdAt: Date()
        )
        let attachmentProjection = AttachmentProjectionCheckpointWire(
            schemaVersion: AttachmentProjectionCheckpointWire.currentSchemaVersion,
            basedOnEventID: 1,
            projectionFingerprint: "att-fp",
            decisions: [
                ConversationAttachmentProjectionDecision(
                    attachmentID: UUID(),
                    attachmentName: "doc.pdf",
                    attachmentKind: "document",
                    disposition: .summarize,
                    reason: "within_summary_budget"
                ),
            ],
            createdAt: Date()
        )
        let events: [CachedConversationEvent] = [
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 1,
                kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
                payloadJSON: ConversationEventCodec.encode(compactPayload)
            ),
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 2,
                kind: ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue,
                payloadJSON: ConversationEventCodec.encode(mem)
            ),
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 3,
                kind: ConversationEventKind.toolResultTrimCheckpoint.rawValue,
                payloadJSON: ConversationEventCodec.encode(trim)
            ),
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 4,
                kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
                payloadJSON: ConversationEventCodec.encode(prompt)
            ),
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 5,
                kind: ConversationEventKind.attachmentProjectionCheckpoint.rawValue,
                payloadJSON: ConversationEventCodec.encode(attachmentProjection)
            ),
        ]
        let loaded = ConversationCheckpoint.load(from: events)
        #expect(loaded.count == 5)
    }

    @Test("Attachment projection selection supports expected fingerprint filtering")
    func attachmentProjectionExpectedFingerprintFilter() {
        let expected = "projection-fp"
        let matched = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 2,
            kind: ConversationEventKind.attachmentProjectionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                AttachmentProjectionCheckpointWire(
                    schemaVersion: AttachmentProjectionCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    projectionFingerprint: expected,
                    decisions: [
                        ConversationAttachmentProjectionDecision(
                            attachmentID: UUID(),
                            attachmentName: "a.txt",
                            attachmentKind: "document",
                            disposition: .summarize,
                            reason: "within_summary_budget"
                        ),
                    ],
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let mismatched = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 3,
            kind: ConversationEventKind.attachmentProjectionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                AttachmentProjectionCheckpointWire(
                    schemaVersion: AttachmentProjectionCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    projectionFingerprint: "other-fp",
                    decisions: [
                        ConversationAttachmentProjectionDecision(
                            attachmentID: UUID(),
                            attachmentName: "b.txt",
                            attachmentKind: "document",
                            disposition: .searchOnly,
                            reason: "over_budget"
                        ),
                    ],
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let selected = LatestValidConversationCheckpoint.latestCheckpointSelection(
            kind: .attachmentProjection,
            events: [matched, mismatched],
            rawMiddle: [],
            compactionConfig: makeCompactionConfig(),
            toolTrimConfigFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            rawMessages: [],
            expectedAttachmentProjectionFingerprint: expected,
            frontierEventID: 3
        )
        guard case .attachmentProjection(let wire, let eventID) = selected else {
            Issue.record("expected attachment projection selection")
            return
        }
        #expect(eventID == 2)
        #expect(wire.projectionFingerprint == expected)
        #expect(wire.decisions.count == 1)
    }

    @Test("Context-compaction selection honors cache-aware invalidation floor")
    func contextCompactionSelectionCacheAwareInvalidation() {
        let config = makeCompactionConfig()
        let rawID = UUID()
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: [rawID],
            syntheticMessages: [ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "s")],
            configFingerprint: ContextCompactionCheckpointSupport.configFingerprint(config),
            basedOnEventID: 1,
            createdAt: Date()
        )
        let checkpoint = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 2,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload),
            createdAt: Date()
        )
        let invalidation = CachedConversationEvent(
            conversationID: checkpoint.conversationID,
            eventID: 3,
            kind: ConversationEventKind.checkpointInvalidated.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                CheckpointInvalidatedEventPayload(kinds: [HarnessCheckpointInvalidationKind.cacheAwarePruning])
            ),
            createdAt: Date()
        )
        let selected = LatestValidConversationCheckpoint.latestCheckpointSelection(
            kind: .contextCompaction,
            events: [checkpoint, invalidation],
            rawMiddle: [Message(id: rawID, role: .user, content: "u", timestamp: Date(), toolCalls: [])],
            compactionConfig: config,
            toolTrimConfigFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            rawMessages: [],
            frontierEventID: 3
        )
        #expect(selected == nil)
    }
}
