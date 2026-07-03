import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Journal stream append (raw vs derived OC)")
struct JournalStreamAppendTests {
    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func makeHarness(_ container: ModelContainer) throws -> (
        log: ConversationEventLogService,
        derived: RoutingDerivedEventStore,
        manager: ConversationManager
    ) {
        let manager = ConversationManager(container: container)
        manager.setHarnessSessionPersistenceOverride(InMemoryHarnessSessionPersistence())
        let pair = HarnessConversationTestFixtures.makeJournalPersistence(manager: manager)
        return (pair.eventLog, pair.derived, manager)
    }

    @Test("Mismatched expectedLastMessageId throws transcriptTailMismatch")
    func rawMessageIdConflict() throws {
        let container = try makeContainer()
        let (log, _, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let msg = Message(id: UUID(), role: .user, content: "a", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: cid, messages: [msg], expectedLastMessageId: nil)
        #expect(log.latestRawTailMessageID(conversationID: cid) == msg.id)
        #expect(throws: ConversationServiceError.self) {
            try log.appendMessageAppendedEvents(
                conversationID: cid,
                messages: [Message(id: UUID(), role: .user, content: "b", timestamp: Date(), toolCalls: [])],
                expectedLastMessageId: UUID()
            )
        }
    }

    @Test("Mismatched expectedRawSequence on interaction_mode_changed throws JournalStreamSequenceConflict")
    func rawSequenceConflictOnModeChange() throws {
        let container = try makeContainer()
        let (log, _, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let msg = Message(id: UUID(), role: .user, content: "a", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: cid, messages: [msg], expectedLastMessageId: nil)
        #expect(log.latestRawStreamSequence(conversationID: cid) == 1)
        #expect(throws: JournalStreamSequenceConflict.self) {
            try log.appendInteractionModeChangedEvent(
                conversationID: cid,
                payload: InteractionModeChangedEventPayload(
                    fromMode: "chat",
                    toMode: "agent",
                    fromProfileID: "chat",
                    toProfileID: "agent",
                    fromPhase: "chat",
                    toPhase: "build",
                    initiatedBy: "test",
                    reason: "stale-seq"
                ),
                expectedRawSequence: 0
            )
        }
    }

    @Test("Mismatched expectedDerivedSequence throws")
    func derivedSequenceConflict() throws {
        let container = try makeContainer()
        let (_, derived, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let payload = ConversationEventCodec.encode(
            TurnFinalizedEventPayload(basedOnEventID: 0, createdAt: Date())
        )
        #expect(throws: JournalStreamSequenceConflict.self) {
            try derived.appendTurnFinalizedEvent(
                conversationID: cid,
                payloadJSON: payload,
                basedOnEventID: nil,
                createdAt: Date(),
                expectedDerivedSequence: 1
            )
        }
    }

    @Test("Raw and derived streamSequence tails advance independently")
    func independentTails() throws {
        let container = try makeContainer()
        let (log, derived, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let m1 = Message(id: UUID(), role: .user, content: "a", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: cid, messages: [m1], expectedLastMessageId: nil)
        #expect(log.latestRawStreamSequence(conversationID: cid) == 1)
        #expect(derived.latestDerivedStreamSequence(conversationID: cid) == 0)

        let finPayload = ConversationEventCodec.encode(
            TurnFinalizedEventPayload(basedOnEventID: 1, createdAt: Date())
        )
        try derived.appendTurnFinalizedEvent(
            conversationID: cid,
            payloadJSON: finPayload,
            basedOnEventID: 1,
            createdAt: Date(),
            expectedDerivedSequence: nil
        )
        #expect(log.latestRawStreamSequence(conversationID: cid) == 1)
        #expect(derived.latestDerivedStreamSequence(conversationID: cid) == 1)

        try log.appendMessageAppendedEvents(
            conversationID: cid,
            messages: [Message(id: UUID(), role: .user, content: "b", timestamp: Date(), toolCalls: [])],
            expectedLastMessageId: m1.id
        )
        #expect(log.latestRawStreamSequence(conversationID: cid) == 2)
        #expect(derived.latestDerivedStreamSequence(conversationID: cid) == 1)
    }

    @Test("Global eventID ordering is preserved across raw and derived appends")
    func globalEventIDOrderingAcrossStreams() throws {
        let container = try makeContainer()
        let (log, derived, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)

        let m1 = Message(id: UUID(), role: .user, content: "m1", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: cid, messages: [m1], expectedLastMessageId: nil)

        let fin1 = ConversationEventCodec.encode(
            TurnFinalizedEventPayload(basedOnEventID: 1, createdAt: Date())
        )
        try derived.appendTurnFinalizedEvent(
            conversationID: cid,
            payloadJSON: fin1,
            basedOnEventID: 1,
            createdAt: Date(),
            expectedDerivedSequence: nil
        )

        let m2 = Message(id: UUID(), role: .assistant, content: "m2", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: cid, messages: [m2], expectedLastMessageId: m1.id)

        let fin2 = ConversationEventCodec.encode(
            TurnFinalizedEventPayload(basedOnEventID: 3, createdAt: Date())
        )
        try derived.appendTurnFinalizedEvent(
            conversationID: cid,
            payloadJSON: fin2,
            basedOnEventID: 3,
            createdAt: Date(),
            expectedDerivedSequence: 1
        )

        let (events, _) = log.loadConversationEventsWithFrontier(conversationID: cid)
        #expect(events.map(\.eventID) == [1, 2, 3, 4])
        #expect(events.map(\.kind) == [
            ConversationEventKind.messageAppended.rawValue,
            ConversationEventKind.turnFinalized.rawValue,
            ConversationEventKind.messageAppended.rawValue,
            ConversationEventKind.turnFinalized.rawValue,
        ])
    }

    @Test("Duplicate context compaction checkpoint append is idempotent (derived tail unchanged)")
    func compactionCheckpointIdempotentRetry() throws {
        let container = try makeContainer()
        let (_, derived, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let cfg = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
        let mid = UUID()
        let compacted = Message(id: UUID(), role: .assistant, content: "compact", timestamp: Date(), toolCalls: [])
        try derived.appendContextCompactionCheckpoint(
            conversationID: cid,
            rawMiddleMessageIDs: [mid],
            compactedMiddleMessages: [compacted],
            kind: .summarized,
            config: cfg,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        #expect(derived.latestDerivedStreamSequence(conversationID: cid) == 1)
        try derived.appendContextCompactionCheckpoint(
            conversationID: cid,
            rawMiddleMessageIDs: [mid],
            compactedMiddleMessages: [compacted],
            kind: .summarized,
            config: cfg,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        #expect(derived.latestDerivedStreamSequence(conversationID: cid) == 1)
    }

    @Test("After checkpoint invalidation, same coverage may append again")
    func compactionCheckpointAfterInvalidationNotIdempotent() throws {
        let container = try makeContainer()
        let (_, derived, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let cfg = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
        let mid = UUID()
        let compacted = Message(id: UUID(), role: .assistant, content: "compact", timestamp: Date(), toolCalls: [])
        try derived.appendContextCompactionCheckpoint(
            conversationID: cid,
            rawMiddleMessageIDs: [mid],
            compactedMiddleMessages: [compacted],
            kind: .summarized,
            config: cfg,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        try derived.appendCheckpointInvalidation(
            conversationID: cid,
            kinds: [HarnessCheckpointInvalidationKind.contextCompaction],
            expectedDerivedSequence: nil
        )
        #expect(derived.latestDerivedStreamSequence(conversationID: cid) == 2)
        try derived.appendContextCompactionCheckpoint(
            conversationID: cid,
            rawMiddleMessageIDs: [mid],
            compactedMiddleMessages: [compacted],
            kind: .summarized,
            config: cfg,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        #expect(derived.latestDerivedStreamSequence(conversationID: cid) == 3)
    }

    @Test("Compaction writer drops checkpoint after derived sequence conflict")
    func compactionWriterDropsOnConflict() async throws {
        let container = try makeContainer()
        let stack = ConversationPersistenceStack.makeForTesting(container: container, logger: nil)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(
            manager: stack.conversationManager,
            conversationID: cid
        )
        let cfg = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
        let firstSpec = ContextCompactionCheckpointPersistenceSpec(
            conversationID: cid,
            rawMiddleMessageIDs: [UUID()],
            compactedMiddleMessages: [Message(id: UUID(), role: .assistant, content: "first", timestamp: Date(), toolCalls: [])],
            kind: .summarized,
            config: cfg,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: 0,
            firstKeptTailMessageID: nil,
            summaryBodyForTranscript: nil,
            promptTokensBeforeCompaction: nil
        )
        let firstPersisted = await ContextCheckpointWriter.persistCompactionCheckpointIfNeeded(
            spec: firstSpec,
            persistence: stack,
            logger: nil
        )
        #expect(firstPersisted == true)
        #expect(stack.derivedEventStore.latestDerivedStreamSequence(conversationID: cid) == 1)

        let staleExpectedSpec = ContextCompactionCheckpointPersistenceSpec(
            conversationID: cid,
            rawMiddleMessageIDs: [UUID()],
            compactedMiddleMessages: [Message(id: UUID(), role: .assistant, content: "second", timestamp: Date(), toolCalls: [])],
            kind: .summarized,
            config: cfg,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: 0,
            firstKeptTailMessageID: nil,
            summaryBodyForTranscript: nil,
            promptTokensBeforeCompaction: nil
        )
        let persistedAfterConflict = await ContextCheckpointWriter.persistCompactionCheckpointIfNeeded(
            spec: staleExpectedSpec,
            persistence: stack,
            logger: nil
        )
        #expect(persistedAfterConflict == false)
        #expect(stack.derivedEventStore.latestDerivedStreamSequence(conversationID: cid) == 1)
    }

    @Test("Memory snapshot invalidation supersedes stale store-version checkpoints")
    func memorySnapshotInvalidationSupersedesStaleVersion() throws {
        let container = try makeContainer()
        let (_, derived, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let scopeID = UUID()
        try derived.appendMemoryInjectionSnapshotCheckpoint(
            conversationID: cid,
            wire: MemoryInjectionSnapshotCheckpointWire(
                schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
                basedOnEventID: 1,
                injectionFingerprint: "mem-v1",
                snapshotJSON: "{\"v\":1}",
                scopeMessageIDs: [scopeID],
                memoryStoreVersion: 1,
                memoryStoreNamespaceKey: cid.uuidString,
                memoryEntryIDs: [scopeID],
                createdAt: Date()
            ),
            expectedDerivedSequence: nil
        )
        let beforeInvalidation = manager.loadConversationEventsWithFrontier(conversationID: cid).0
        #expect(
            SuiteCheckpointSupport.latestValidMemoryInjectionSnapshot(
                events: beforeInvalidation,
                expectedMemoryStoreVersion: 2
            ) == nil
        )
        try derived.appendCheckpointInvalidation(
            conversationID: cid,
            kinds: [HarnessCheckpointInvalidationKind.memoryInjectionSnapshot],
            expectedDerivedSequence: nil
        )
        let afterInvalidation = manager.loadConversationEventsWithFrontier(conversationID: cid).0
        #expect(
            SuiteCheckpointSupport.latestValidMemoryInjectionSnapshot(
                events: afterInvalidation
            ) == nil
        )
    }

    @Test("Concurrent derived appends with same expectedDerivedSequence allow exactly one winner")
    func concurrentDerivedAppendsSameExpected() async throws {
        let container = try makeContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let manager = ConversationManager(container: container)
        manager.setHarnessSessionPersistenceOverride(harness)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)

        let workerCount = 8
        let results = try await withThrowingTaskGroup(of: Result<Void, Error>.self) { group in
            for index in 0..<workerCount {
                group.addTask {
                    let scopeID = UUID()
                    let wire = MemoryInjectionSnapshotCheckpointWire(
                        schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
                        basedOnEventID: 1,
                        injectionFingerprint: "mem-\(index)",
                        snapshotJSON: "{\"v\":\(index)}",
                        scopeMessageIDs: [scopeID],
                        memoryStoreVersion: 1,
                        memoryStoreNamespaceKey: cid.uuidString,
                        memoryEntryIDs: [scopeID],
                        createdAt: Date()
                    )
                    do {
                        try TranscriptConversationJournalWriter.appendDerivedJournalEntry(
                            harness: harness,
                            conversationID: cid,
                            kind: .memoryInjectionSnapshotCheckpoint,
                            payloadJSON: ConversationEventCodec.encode(wire),
                            basedOnEventID: 1,
                            coversStartEventID: nil,
                            coversEndEventID: nil,
                            createdAt: wire.createdAt,
                            expectedDerivedSequence: 0
                        )
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<Void, Error>] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        let successes = results.filter {
            if case .success = $0 { return true }
            return false
        }
        let conflicts = results.compactMap { result -> JournalStreamSequenceConflict? in
            if case let .failure(error) = result, let conflict = error as? JournalStreamSequenceConflict {
                return conflict
            }
            return nil
        }
        #expect(successes.count == 1)
        #expect(conflicts.count == workerCount - 1)
        #expect(TranscriptConversationJournalWriter.latestDerivedStreamSequence(harness: harness, conversationID: cid) == 1)

        let (events, _) = TranscriptConversationJournalWriter.loadEventsWithFrontier(
            harness: harness,
            conversationID: cid
        )
        let derivedSequences = events
            .filter { $0.kind == ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue }
            .map(\.streamSequence)
        #expect(Set(derivedSequences).count == derivedSequences.count)
        #expect(derivedSequences == [1])
    }

    @Test("Concurrent derived appends with nil expected serialize under lock")
    func concurrentDerivedAppendsNilExpected() async throws {
        let container = try makeContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let manager = ConversationManager(container: container)
        manager.setHarnessSessionPersistenceOverride(harness)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)

        let workerCount = 8
        let results = try await withThrowingTaskGroup(of: Result<Void, Error>.self) { group in
            for index in 0..<workerCount {
                group.addTask {
                    let scopeID = UUID()
                    let wire = MemoryInjectionSnapshotCheckpointWire(
                        schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
                        basedOnEventID: 1,
                        injectionFingerprint: "nil-expected-\(index)",
                        snapshotJSON: "{\"v\":\(index)}",
                        scopeMessageIDs: [scopeID],
                        memoryStoreVersion: 1,
                        memoryStoreNamespaceKey: cid.uuidString,
                        memoryEntryIDs: [scopeID],
                        createdAt: Date()
                    )
                    do {
                        try TranscriptConversationJournalWriter.appendDerivedJournalEntry(
                            harness: harness,
                            conversationID: cid,
                            kind: .memoryInjectionSnapshotCheckpoint,
                            payloadJSON: ConversationEventCodec.encode(wire),
                            basedOnEventID: 1,
                            coversStartEventID: nil,
                            coversEndEventID: nil,
                            createdAt: wire.createdAt,
                            expectedDerivedSequence: nil
                        )
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<Void, Error>] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        let successes = results.filter {
            if case .success = $0 { return true }
            return false
        }
        #expect(successes.count == workerCount)
        #expect(TranscriptConversationJournalWriter.latestDerivedStreamSequence(harness: harness, conversationID: cid) == workerCount)

        let (events, _) = TranscriptConversationJournalWriter.loadEventsWithFrontier(
            harness: harness,
            conversationID: cid
        )
        let derivedSequences = events
            .filter { $0.kind == ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue }
            .map(\.streamSequence)
        #expect(Set(derivedSequences).count == derivedSequences.count)
        #expect(derivedSequences == Array(1...workerCount))
    }

    @Test("Concurrent raw single-entry appends with same stale expected allow exactly one winner")
    func concurrentRawSingleEntryAppendsStaleExpected() async throws {
        let container = try makeContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let manager = ConversationManager(container: container)
        manager.setHarnessSessionPersistenceOverride(harness)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let msg = Message(id: UUID(), role: .user, content: "seed", timestamp: Date(), toolCalls: [])
        try TranscriptConversationJournalWriter.appendMessageAppendedEvents(
            harness: harness,
            conversationID: cid,
            messages: [msg],
            expectedLastMessageId: nil
        )
        #expect(TranscriptConversationJournalWriter.latestRawStreamSequence(harness: harness, conversationID: cid) == 1)

        let workerCount = 8
        let results = try await withThrowingTaskGroup(of: Result<Void, Error>.self) { group in
            for index in 0..<workerCount {
                group.addTask {
                    do {
                        try TranscriptConversationJournalWriter.appendRawJournalEntry(
                            harness: harness,
                            conversationID: cid,
                            kind: .interactionModeChanged,
                            innerPayloadJSON: ConversationEventCodec.encode(
                                InteractionModeChangedEventPayload(
                                    fromMode: "chat",
                                    toMode: "agent",
                                    fromProfileID: "chat",
                                    toProfileID: "agent",
                                    fromPhase: "chat",
                                    toPhase: "build",
                                    initiatedBy: "test",
                                    reason: "concurrent-\(index)"
                                )
                            ),
                            createdAt: Date(),
                            expectedRawSequence: 1
                        )
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<Void, Error>] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        let successes = results.filter {
            if case .success = $0 { return true }
            return false
        }
        let conflicts = results.compactMap { result -> JournalStreamSequenceConflict? in
            if case let .failure(error) = result, let conflict = error as? JournalStreamSequenceConflict {
                return conflict
            }
            return nil
        }
        #expect(successes.count == 1)
        #expect(conflicts.count == workerCount - 1)
        #expect(TranscriptConversationJournalWriter.latestRawStreamSequence(harness: harness, conversationID: cid) == 2)
    }

    @Test("Message-id anchor survives interaction_mode_changed between appends")
    func rawMessageIdSurvivesInteractionModeChange() throws {
        let container = try makeContainer()
        let (log, _, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let m1 = Message(id: UUID(), role: .user, content: "a", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: cid, messages: [m1], expectedLastMessageId: nil)
        try log.appendInteractionModeChangedEvent(
            conversationID: cid,
            payload: InteractionModeChangedEventPayload(
                fromMode: "chat",
                toMode: "agent",
                fromProfileID: "chat",
                toProfileID: "agent",
                fromPhase: "chat",
                toPhase: "build",
                initiatedBy: "test",
                reason: "mode-switch"
            ),
            expectedRawSequence: 1
        )
        #expect(log.latestRawStreamSequence(conversationID: cid) == 2)
        #expect(log.latestRawTailMessageID(conversationID: cid) == m1.id)
        let m2 = Message(id: UUID(), role: .assistant, content: "b", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: cid, messages: [m2], expectedLastMessageId: m1.id)
        #expect(log.latestRawStreamSequence(conversationID: cid) == 3)
        #expect(log.latestRawTailMessageID(conversationID: cid) == m2.id)
    }

    @Test("latestRawTailMessageID tracks last message_appended across mixed raw events")
    func latestRawTailMessageIDAfterMixedRawAppends() throws {
        let container = try makeContainer()
        let (log, _, manager) = try makeHarness(container)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let m1 = Message(id: UUID(), role: .user, content: "a", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: cid, messages: [m1], expectedLastMessageId: nil)
        try log.appendInteractionModeChangedEvent(
            conversationID: cid,
            payload: InteractionModeChangedEventPayload(
                fromMode: "chat",
                toMode: "agent",
                fromProfileID: "chat",
                toProfileID: "agent",
                fromPhase: "chat",
                toPhase: "build",
                initiatedBy: "test",
                reason: "mode-switch"
            ),
            expectedRawSequence: nil
        )
        #expect(log.latestRawTailMessageID(conversationID: cid) == m1.id)
    }

    @Test("Concurrent raw message appends with same stale message-id anchor allow exactly one winner")
    func concurrentRawMessageAppendsStaleMessageId() async throws {
        let container = try makeContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let manager = ConversationManager(container: container)
        manager.setHarnessSessionPersistenceOverride(harness)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: manager, conversationID: cid)
        let seed = Message(id: UUID(), role: .user, content: "seed", timestamp: Date(), toolCalls: [])
        try TranscriptConversationJournalWriter.appendMessageAppendedEvents(
            harness: harness,
            conversationID: cid,
            messages: [seed],
            expectedLastMessageId: nil
        )

        let workerCount = 8
        let results = try await withThrowingTaskGroup(of: Result<Void, Error>.self) { group in
            for index in 0..<workerCount {
                group.addTask {
                    do {
                        let msg = Message(id: UUID(), role: .user, content: "worker-\(index)", timestamp: Date(), toolCalls: [])
                        try TranscriptConversationJournalWriter.appendMessageAppendedEvents(
                            harness: harness,
                            conversationID: cid,
                            messages: [msg],
                            expectedLastMessageId: seed.id
                        )
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<Void, Error>] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        let successes = results.filter {
            if case .success = $0 { return true }
            return false
        }
        let mismatches = results.compactMap { result -> ConversationServiceError? in
            if case let .failure(error) = result,
               let mismatch = error as? ConversationServiceError,
               case .transcriptTailMismatch = mismatch
            {
                return mismatch
            }
            return nil
        }
        #expect(successes.count == 1)
        #expect(mismatches.count == workerCount - 1)
        #expect(TranscriptConversationJournalWriter.latestRawStreamSequence(harness: harness, conversationID: cid) == 2)
        #expect(TranscriptConversationJournalWriter.latestRawTailMessageID(harness: harness, conversationID: cid) != seed.id)
    }

    @Test("Branch copy allows subsequent message append with tail CAS")
    func branchCopyAllowsSubsequentMessageAppendWithTailCAS() throws {
        let container = try makeContainer()
        let (log, _, manager) = try makeHarness(container)
        let harness = manager.harnessSessionPersistence
        let model = Model(
            protocol: .openAIAPI,
            modelName: "branch-tail-cas",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let parent = try manager.createConversation(with: model, userSystemPrompt: "sys")
        let parentID = parent.id
        let userMsg = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: parentID, messages: [userMsg], expectedLastMessageId: nil)
        let parentEntryId = try ConversationTranscriptLineage.resolvedHeadEntryId(
            conversationID: parentID,
            harness: harness
        )
        let sequence = try harness.nextTranscriptSequence(conversationID: parentID)
        let thinEntry = try SessionTranscriptMapping.entry(
            from: userMsg,
            sequence: sequence,
            parentEntryId: parentEntryId,
            transcriptRunID: nil
        )
        try harness.appendTranscriptEntries(conversationID: parentID, entries: [thinEntry])
        try manager.resetConversationsFromCatalog(availableModels: [model])

        let child = try manager.copyConversation(from: parentID, to: model, systemPrompt: "sys")
        let childID = child.id
        let childTail = try #require(log.latestRawTailMessageID(conversationID: childID))

        let followUp = Message(id: UUID(), role: .user, content: "next", timestamp: Date(), toolCalls: [])
        try log.appendMessageAppendedEvents(conversationID: childID, messages: [followUp], expectedLastMessageId: childTail)
        #expect(log.latestRawTailMessageID(conversationID: childID) == followUp.id)
    }
}
