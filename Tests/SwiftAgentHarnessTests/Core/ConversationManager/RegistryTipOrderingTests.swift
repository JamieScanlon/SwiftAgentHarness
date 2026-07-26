import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("H14 registry tip ordering")
struct RegistryTipOrderingTests {

    private func message(
        id: UUID = UUID(),
        role: MessageRole = .user,
        content: String,
        timestamp: Date
    ) -> Message {
        Message(id: id, role: role, content: content, timestamp: timestamp)
    }

    // MARK: - Unit: merge / replace policy

    @Test("union appends missing older tip middle after newer spine (documents time-warp)")
    func unionAppendsMissingMiddleAfterNewerSpine() {
        let base = Date(timeIntervalSince1970: 1_000)
        let a = message(content: "A", timestamp: base)
        let b = message(content: "B", timestamp: base.addingTimeInterval(1))
        let c = message(content: "C", timestamp: base.addingTimeInterval(2))
        let d = message(content: "D", timestamp: base.addingTimeInterval(3))
        let e = message(content: "E", timestamp: base.addingTimeInterval(4))

        // Spine has recent tip suffix but is missing older middle C.
        let existing = [a, b, d, e]
        let tip = [a, b, c, d, e]
        let merged = RegistryTranscriptMerge.union(existing: existing, incoming: tip)
        #expect(merged.map(\.id) == [a.id, b.id, d.id, e.id, c.id])
    }

    @Test("authoritative tip replace equals tip order and membership when existing is scrambled longer")
    func authoritativeTipReplaceEqualsTipOrder() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let base = Date(timeIntervalSince1970: 2_000)
        let a = message(content: "A", timestamp: base)
        let b = message(content: "B", timestamp: base.addingTimeInterval(1))
        let c = message(content: "C", timestamp: base.addingTimeInterval(2))
        let d = message(content: "D", timestamp: base.addingTimeInterval(3))
        let orphan = message(content: "orphan", timestamp: base.addingTimeInterval(5))
        let tip = [a, b, c, d]
        let scrambled = [a, b, d, orphan, c]

        guard var existing = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        existing.messages = scrambled
        await domain.replaceConversationInRegistry(existing, transcript: .authoritativeTip)

        guard var incoming = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing after scramble")
            return
        }
        #expect(incoming.messages.map(\.id) == scrambled.map(\.id))

        incoming.messages = tip
        await domain.replaceConversationInRegistry(incoming, transcript: .authoritativeTip)

        let result = await domain.modelConversation(id: conv.id)
        #expect(result?.messages.map(\.id) == tip.map(\.id))
        #expect(result?.messages.contains(where: { $0.id == orphan.id }) == false)
    }

    @Test("concurrentUnion still preserves longer transcript on stale shorter metadata write")
    func concurrentUnionPreservesLongerOnStaleShorter() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let assistant = Message(id: UUID(), role: .assistant, content: "final", timestamp: Date())
        _ = try await domain.routingSaveMessage(
            assistant,
            for: conv.id,
            resourceManager: nil,
            logger: nil,
            expectedPreviousTailHarnessMessageID: nil,
            transcriptRunID: nil
        )

        guard var stale = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        stale.messages.removeLast()
        stale.state = .idle
        await domain.replaceConversationInRegistry(stale, transcript: .concurrentUnion)

        let conversation = await domain.modelConversation(id: conv.id)
        #expect(conversation?.messages.contains(where: { $0.id == assistant.id }) == true)
        #expect(conversation?.state == .idle)
    }

    // MARK: - Integration: tip reload repairs time warp

    @Test("registry spine missing tip middle; authoritative tip reload restores tip order")
    func tipReloadRepairsMissingMiddleTimeWarp() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let base = Date()
        let middle = message(role: .user, content: "middle", timestamp: base.addingTimeInterval(1))
        let late1 = message(role: .assistant, content: "late1", timestamp: base.addingTimeInterval(2))
        let late2 = message(role: .user, content: "late2", timestamp: base.addingTimeInterval(3))
        for msg in [middle, late1, late2] {
            _ = try await domain.routingSaveMessage(
                msg,
                for: conv.id,
                resourceManager: nil,
                logger: nil,
                expectedPreviousTailHarnessMessageID: nil,
                transcriptRunID: nil
            )
        }

        let tip = try ConversationTranscriptLineage.activeMessages(
            conversationID: conv.id,
            harness: await domain.harnessSessionPersistence
        )
        #expect(tip.contains(where: { $0.id == middle.id }))

        // Corrupt registry: recent tip suffix without the older middle (H14 incident shape).
        guard var warped = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        let withoutMiddle = tip.filter { $0.id != middle.id }
        #expect(withoutMiddle.count == tip.count - 1)
        warped.messages = withoutMiddle
        await domain.replaceConversationInRegistry(warped, transcript: .authoritativeTip)

        // Concurrent union of full tip onto corrupted spine would time-warp; authoritative reload must not.
        guard var incomingTip = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing after warp")
            return
        }
        incomingTip.messages = tip
        let unioned = RegistryTranscriptMerge.union(existing: withoutMiddle, incoming: tip)
        #expect(unioned.map(\.id) != tip.map(\.id))
        #expect(unioned.last?.id == middle.id)

        await domain.replaceConversationInRegistry(incomingTip, transcript: .authoritativeTip)
        let repaired = await domain.modelConversation(id: conv.id)
        #expect(repaired?.messages.map(\.id) == tip.map(\.id))
    }

    @Test("reloadRegistryTranscriptFromActiveTip restores tip after scrambled registry")
    func reloadFromActiveTipRestoresOrder() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let u1 = message(role: .user, content: "one", timestamp: Date())
        let u2 = message(role: .user, content: "two", timestamp: Date().addingTimeInterval(1))
        let u3 = message(role: .user, content: "three", timestamp: Date().addingTimeInterval(2))
        for msg in [u1, u2, u3] {
            _ = try await domain.routingSaveMessage(
                msg,
                for: conv.id,
                resourceManager: nil,
                logger: nil,
                expectedPreviousTailHarnessMessageID: nil,
                transcriptRunID: nil
            )
        }

        let tip = try ConversationTranscriptLineage.activeMessages(
            conversationID: conv.id,
            harness: await domain.harnessSessionPersistence
        )

        guard var scrambled = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        scrambled.messages = tip.reversed()
        await domain.replaceConversationInRegistry(scrambled, transcript: .authoritativeTip)

        await domain.reloadRegistryTranscriptFromActiveTip(conversationID: conv.id)
        let restored = await domain.modelConversation(id: conv.id)
        #expect(restored?.messages.map(\.id) == tip.map(\.id))
    }

    // MARK: - Orphans + projection

    @Test("UI projection excludes off-tip sibling orphan")
    func projectionExcludesOffTipSibling() async throws {
        let (stack, local, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "h14-orphan")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(
            container: container,
            logger: nil,
            harnessSessionPersistenceOverride: local
        )
        let compactionCoordinator = CompactionConcurrencyCoordinator()
        let contextAssemblyRuntime = ContextAssemblyRuntimeFacade(
            persistenceDomain: domain,
            conversationTransformConfiguration: .default
        )
        let deps = ConversationRuntimeDependencies(
            persistenceDomain: domain,
            compactionCoordinator: compactionCoordinator,
            contextEngine: DefaultContextEngine(compactionCoordinator: compactionCoordinator, logger: nil),
            contextAssemblyRuntime: contextAssemblyRuntime,
            modeRegistry: ModeRegistryTestSupport.makePort(),
            llmFactory: StandardModelLLMFactory(),
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            runtimeLaneCoordinator: RuntimeLaneCoordinator(configuration: .default),
            toolPolicy: .unrestricted,
            trustPolicyConfiguration: .disabled,
            agentHarness: .default,
            thinkingPolicyConfiguration: .default,
            conversationTransformConfiguration: .default,
            conversationTransformer: NoOpConversationTransformer(),
            registryEntryProvider: nil,
            rankedRegistryEntriesProvider: nil,
            delegateCostTracker: nil,
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.defaultInternal,
            logger: nil
        )
        let services = ReplayProjectionTestSupport.makeReplayProjectionServices(deps: deps)
        let model = HarnessConversationTestFixtures.makeTestModel(name: "h14-orphan")

        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let parent = message(role: .user, content: "parent", timestamp: Date())
        let tipChild = message(role: .assistant, content: "on-tip", timestamp: Date().addingTimeInterval(1))
        _ = try await domain.routingSaveMessage(
            parent,
            for: conv.id,
            resourceManager: nil,
            logger: nil,
            expectedPreviousTailHarnessMessageID: nil,
            transcriptRunID: nil
        )
        _ = try await domain.routingSaveMessage(
            tipChild,
            for: conv.id,
            resourceManager: nil,
            logger: nil,
            expectedPreviousTailHarnessMessageID: nil,
            transcriptRunID: nil
        )

        let orphan = message(role: .assistant, content: "off-tip-sibling", timestamp: Date().addingTimeInterval(2))
        let seq = try local.nextTranscriptSequence(conversationID: conv.id)
        let orphanEntry = try SessionTranscriptMapping.entry(
            from: orphan,
            sequence: seq,
            parentEntryId: SessionEntryID.fromMessageUUID(parent.id)
        )
        try local.appendTranscriptEntry(conversationID: conv.id, entry: orphanEntry)
        // Head advanced to orphan; force tip back to the on-branch child so orphan is off-tip.
        _ = try local.forceActiveHeadEntryId(
            conversationID: conv.id,
            entryId: SessionEntryID.fromMessageUUID(tipChild.id)
        )

        let tip = try ConversationTranscriptLineage.activeMessages(
            conversationID: conv.id,
            harness: local
        )
        #expect(tip.contains(where: { $0.id == tipChild.id }))
        #expect(tip.contains(where: { $0.id == orphan.id }) == false)

        guard var poisoned = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        poisoned.messages = tip + [orphan]
        await domain.replaceConversationInRegistry(poisoned, transcript: .authoritativeTip)

        await services.conversationMessagingRuntimeService.refreshProjectedConversationMessages(
            conversationID: conv.id,
            baseMessagesOverride: poisoned.messages
        )
        let projected = await services.sessionProjectionRuntimeService.projectedMessages(
            for: try #require(await domain.modelConversation(id: conv.id))
        )
        #expect(projected.contains(where: { $0.id == orphan.id }) == false)
        #expect(projected.contains(where: { $0.id == tipChild.id }))
        #expect(projected.map(\.id) == tip.map(\.id))
        _ = stack
    }

    @Test("projected messages match activeMessages order and IDs after registry race")
    func projectedMatchesActiveMessagesAfterRace() async throws {
        let (deps, _) = try ReplayProjectionTestSupport.makeReplayProjectionDependencies()
        let services = ReplayProjectionTestSupport.makeReplayProjectionServices(deps: deps)
        let domain = deps.persistenceDomain
        let model = ReplayProjectionTestSupport.makeTestModel()

        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let msgs = (0..<5).map { index in
            message(
                role: index % 2 == 0 ? .user : .assistant,
                content: "m\(index)",
                timestamp: Date().addingTimeInterval(Double(index))
            )
        }
        for msg in msgs {
            _ = try await domain.routingSaveMessage(
                msg,
                for: conv.id,
                resourceManager: nil,
                logger: nil,
                expectedPreviousTailHarnessMessageID: nil,
                transcriptRunID: nil
            )
        }

        let tip = try ConversationTranscriptLineage.activeMessages(
            conversationID: conv.id,
            harness: await domain.harnessSessionPersistence
        )

        guard var race = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        // Simulate concurrent partial: drop a middle tip message and append an in-memory-only extra.
        let middle = tip[tip.count / 2]
        let extra = message(content: "race-extra", timestamp: Date().addingTimeInterval(100))
        race.messages = tip.filter { $0.id != middle.id } + [extra]
        await domain.replaceConversationInRegistry(race, transcript: .concurrentUnion)

        // Authoritative tip writer wins for registry; projection always prefers tip.
        var tipSnapshot = race
        tipSnapshot.messages = tip
        await domain.replaceConversationInRegistry(tipSnapshot, transcript: .authoritativeTip)
        await services.conversationMessagingRuntimeService.refreshProjectedConversationMessages(
            conversationID: conv.id,
            baseMessagesOverride: race.messages
        )

        let projected = await services.sessionProjectionRuntimeService.projectedMessages(
            for: try #require(await domain.modelConversation(id: conv.id))
        )
        let registry = await domain.modelConversation(id: conv.id)
        #expect(registry?.messages.map(\.id) == tip.map(\.id))
        #expect(projected.map(\.id) == tip.map(\.id))
        #expect(projected.contains(where: { $0.id == extra.id }) == false)
    }
}
