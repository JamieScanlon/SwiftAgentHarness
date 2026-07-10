#if canImport(Darwin)
import Darwin
#endif
import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftData
import Testing

@testable import SwiftAgentHarness

private enum ConversationBulkMirrorTestSupport {
    static func enableV2BootstrapForTests() {
    }

    static func makeContainer() throws -> ModelContainer {
        enableV2BootstrapForTests()
                return try HarnessTestModelContainer.makeInMemory()
    }

    static func makeModel(modelName: String) -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: modelName,
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func messageShapedEntries(_ entries: [SessionTranscriptEntry]) -> [SessionTranscriptEntry] {
        entries.filter { $0.type == .system || $0.type == .message }
    }
}

@Suite("Conversation persistence coordinator (v2 bulk mirror parity)", .serialized)
struct ConversationPersistenceCoordinatorRoutingTests {

    @Test func createConversationMirrorsSystemMessageToV2Transcript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-create-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let model = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-create-model")
        let chat = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: local)
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: chat)

        try await chat.createConversation(with: model, userSystemPrompt: "bulkMirrorSystemToken")
        let cid = try #require(await chat.currentConversationID)
        let messageCount = (try await conversationAPI.apiListMessagesThrowing(conversationID: cid)).count
        #expect(messageCount > 0)

        let entries = try local.readTranscriptEntries(conversationID: cid, request: .full)
        let shaped = ConversationBulkMirrorTestSupport.messageShapedEntries(entries)
        #expect(shaped.count == messageCount)
        #expect(entries.contains { $0.payloadJSON.contains("bulkMirrorSystemToken") })
    }

    @Test func copyConversationMirrorsCopiedMessagesToV2Transcript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-copy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let modelA = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-copy-a")
        let chat = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: local)
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: chat)

        try await chat.createConversation(with: modelA, userSystemPrompt: "bulkMirrorSystemToken")
        let sourceId = try #require(await chat.currentConversationID)

        let userMessage = Message(
            id: UUID(),
            role: .user,
            content: "bulkMirrorUserToken",
            timestamp: Date(),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )
        await chat.appendMessagesToConversation([userMessage], conversationID: sourceId)

        let sourceConversationID = try #require(
            await chat.listConversationInfo().first(where: { $0.modelName == "coord-copy-a" })?.id
        )

        let modelB = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-copy-b")
        try await chat.copyConversation(from: sourceConversationID, to: modelB, systemPrompt: "bulkMirrorSystemToken")

        let destId = try #require(await chat.currentConversationID)
        let destMessageCount = (try await conversationAPI.apiListMessagesThrowing(conversationID: destId)).count

        let entries = try local.readTranscriptEntries(conversationID: destId, request: .full)
        let shaped = ConversationBulkMirrorTestSupport.messageShapedEntries(entries)
        #expect(shaped.count == destMessageCount)
        #expect(shaped.contains { $0.payloadJSON.contains("bulkMirrorUserToken") })
    }

    @Test func splitConversationRoutesThroughBackendForkWithoutDuplicateMirrorRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-split-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let model = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-split")
        let chat = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: local)

        try await chat.createConversation(with: model, userSystemPrompt: "bulkMirrorSystemToken")
        let sourceID = try #require(await chat.currentConversationID)
        let anchorUser = Message(
            id: UUID(),
            role: .user,
            content: "splitForkAnchorToken",
            timestamp: Date(),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )
        await chat.appendMessagesToConversation([anchorUser], conversationID: sourceID)

        let sourceEntries = try local.readTranscriptEntries(conversationID: sourceID, request: .full)
        let sourceAnchorEntry = try #require(sourceEntries.first(where: { $0.entryId == SessionEntryID.fromMessageUUID(anchorUser.id) }))
        let expectedPrefixMessageCount = ConversationBulkMirrorTestSupport.messageShapedEntries(
            sourceEntries.filter { $0.sequence <= sourceAnchorEntry.sequence }
        ).count

        let splitID = try await chat.testing_persistSplitConversationAtUserMessage(
            sourceConversationID: sourceID,
            messageID: anchorUser.id
        )
        let childEntries = try local.readTranscriptEntries(conversationID: splitID, request: .full)
        let childShaped = ConversationBulkMirrorTestSupport.messageShapedEntries(childEntries)
        #expect(childShaped.count == expectedPrefixMessageCount)
        #expect(childEntries.filter { $0.payloadJSON.contains("splitForkAnchorToken") }.count == 1)
    }

    @Test func splitConversationCopiesInteractionModeChangedPayloadWithProfileIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-split-mode-marker-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let model = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-split-mode-marker")
        let modeConfig = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "custom-chat-profile",
                    extends: InteractionMode.chat.rawValue,
                    hooks: .object([
                        "onExit": .array([]),
                        "onEnter": .array([]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let modeRegistry = ModeRegistryTestSupport.makePort(seedingBuiltIns: true, modeProfileConfiguration: modeConfig)
        let chat = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: local,
            modeRegistry: modeRegistry
        )

        try await chat.createConversation(with: model, userSystemPrompt: "bulkMirrorSystemToken")
        let sourceID = try #require(await chat.currentConversationID)
        let anchorUser = Message(
            id: UUID(),
            role: .user,
            content: "splitModeMarkerAnchor",
            timestamp: Date(),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )

        try await chat.updateConversationMetadata(
            conversationID: sourceID,
            topic: nil,
            description: nil,
            modeProfileID: "custom-chat-profile"
        )
        await chat.appendMessagesToConversation([anchorUser], conversationID: sourceID)

        let splitID = try await chat.testing_persistSplitConversationAtUserMessage(
            sourceConversationID: sourceID,
            messageID: anchorUser.id
        )

        let sourceEntries = try local.readTranscriptEntries(conversationID: sourceID, request: .full)
        let sourceModeEnvelope = try #require(
            sourceEntries
                .filter { $0.type == .conversationJournal }
                .compactMap { try? SessionTranscriptJournalEnvelopeCodec.decode($0.payloadJSON) }
                .first { $0.kind == ConversationEventKind.interactionModeChanged.rawValue }
        )
        let childEntries = try local.readTranscriptEntries(conversationID: splitID, request: .full)
        let childModeEnvelope = try #require(
            childEntries
                .filter { $0.type == .conversationJournal }
                .compactMap { try? SessionTranscriptJournalEnvelopeCodec.decode($0.payloadJSON) }
                .first { $0.kind == ConversationEventKind.interactionModeChanged.rawValue }
        )

        #expect(childModeEnvelope.innerPayloadJSON == sourceModeEnvelope.innerPayloadJSON)
        let payload = try #require(
            ConversationEventCodec.decode(
                InteractionModeChangedEventPayload.self,
                from: childModeEnvelope.innerPayloadJSON
            )
        )
        #expect(payload.fromMode == InteractionMode.chat.rawValue)
        #expect(payload.toMode == InteractionMode.chat.rawValue)
        #expect(payload.fromProfileID == InteractionMode.chat.rawValue)
        #expect(payload.toProfileID == "custom-chat-profile")
    }

    @Test func splitConversationBeforeLaterModeChangeInheritsAnchorTimeMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-split-anchor-before-mode-change-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let model = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-split-anchor-before")
        let modeConfig = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "custom-plan-profile",
                    extends: InteractionMode.plan.rawValue
                ),
            ],
            diagnostics: []
        )
        let modeRegistry = ModeRegistryTestSupport.makePort(seedingBuiltIns: true, modeProfileConfiguration: modeConfig)
        let chat = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: local,
            modeRegistry: modeRegistry
        )

        try await chat.createConversation(with: model, userSystemPrompt: "branch-before-mode-change")
        let sourceID = try #require(await chat.currentConversationID)
        let anchorBefore = Message(
            id: UUID(),
            role: .user,
            content: "anchor-before-mode-change",
            timestamp: Date(),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )
        await chat.appendMessagesToConversation([anchorBefore], conversationID: sourceID)
        try await chat.updateConversationMetadata(
            conversationID: sourceID,
            topic: nil,
            description: nil,
            interactionMode: .plan,
            modeProfileID: "custom-plan-profile"
        )

        let splitID = try await chat.testing_persistSplitConversationAtUserMessage(
            sourceConversationID: sourceID,
            messageID: anchorBefore.id
        )
        let child = try #require(await chat.listConversationInfo().first(where: { $0.id == splitID }))
        #expect(child.interactionMode == .chat)
        #expect(child.modeProfileID == InteractionMode.chat.rawValue)

        let childEntries = try local.readTranscriptEntries(conversationID: splitID, request: .full)
        let childModeMarkers = childEntries
            .filter { $0.type == .conversationJournal }
            .compactMap { try? SessionTranscriptJournalEnvelopeCodec.decode($0.payloadJSON) }
            .filter { $0.kind == ConversationEventKind.interactionModeChanged.rawValue }
        #expect(childModeMarkers.isEmpty)
    }

    @Test func splitConversationAfterModeChangeInheritsSwitchedModeAndScopesMarkers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-split-anchor-after-mode-change-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let model = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-split-anchor-after")
        let modeConfig = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "custom-plan-profile",
                    extends: InteractionMode.plan.rawValue
                ),
            ],
            diagnostics: []
        )
        let modeRegistry = ModeRegistryTestSupport.makePort(seedingBuiltIns: true, modeProfileConfiguration: modeConfig)
        let chat = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: local,
            modeRegistry: modeRegistry
        )

        try await chat.createConversation(with: model, userSystemPrompt: "branch-after-mode-change")
        let sourceID = try #require(await chat.currentConversationID)
        let anchorBefore = Message(
            id: UUID(),
            role: .user,
            content: "anchor-before-switch",
            timestamp: Date(),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )
        await chat.appendMessagesToConversation([anchorBefore], conversationID: sourceID)
        try await chat.updateConversationMetadata(
            conversationID: sourceID,
            topic: nil,
            description: nil,
            interactionMode: .plan,
            modeProfileID: "custom-plan-profile"
        )
        let anchorAfter = Message(
            id: UUID(),
            role: .user,
            content: "anchor-after-switch",
            timestamp: Date(),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )
        await chat.appendMessagesToConversation([anchorAfter], conversationID: sourceID)

        let splitID = try await chat.testing_persistSplitConversationAtUserMessage(
            sourceConversationID: sourceID,
            messageID: anchorAfter.id
        )
        let child = try #require(await chat.listConversationInfo().first(where: { $0.id == splitID }))
        #expect(child.interactionMode == .plan)
        #expect(child.modeProfileID == "custom-plan-profile")

        let childEntries = try local.readTranscriptEntries(conversationID: splitID, request: .full)
        let childModeMarkers = childEntries
            .filter { $0.type == .conversationJournal }
            .compactMap { try? SessionTranscriptJournalEnvelopeCodec.decode($0.payloadJSON) }
            .filter { $0.kind == ConversationEventKind.interactionModeChanged.rawValue }
        #expect(childModeMarkers.count == 1)
        let modePayload = try #require(
            ConversationEventCodec.decode(
                InteractionModeChangedEventPayload.self,
                from: childModeMarkers[0].innerPayloadJSON
            )
        )
        #expect(modePayload.toMode == InteractionMode.plan.rawValue)
        #expect(modePayload.toProfileID == "custom-plan-profile")

        try await chat.updateConversationMetadata(
            conversationID: splitID,
            topic: nil,
            description: nil,
            interactionMode: .agent
        )
        let updatedChild = try #require(await chat.listConversationInfo().first(where: { $0.id == splitID }))
        let updatedParent = try #require(await chat.listConversationInfo().first(where: { $0.id == sourceID }))
        #expect(updatedChild.interactionMode == .agent)
        #expect(updatedParent.interactionMode == .plan)
        #expect(updatedParent.modeProfileID == "custom-plan-profile")
    }

    @Test func isolatedSpawnPersistsChildModeProfileIDFromParentSeed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-subagent-child-mode-profile-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let model = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-subagent-mode-profile")
        let modeConfig = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "parent-seeded-chat",
                    extends: InteractionMode.chat.rawValue,
                    subAgents: .object([
                        "childModeOnSpawn": .string("child-plan-profile"),
                    ])
                ),
                .init(
                    id: "child-plan-profile",
                    extends: InteractionMode.plan.rawValue
                ),
            ],
            diagnostics: []
        )
        let modeRegistry = ModeRegistryTestSupport.makePort(seedingBuiltIns: true, modeProfileConfiguration: modeConfig)
        let chat = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: local,
            modeRegistry: modeRegistry
        )
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: chat)

        try await chat.createConversation(
            with: model,
            userSystemPrompt: "parent-seeded",
            interactionMode: .chat,
            modeProfileID: "parent-seeded-chat"
        )
        let parentConversationID = try #require(await chat.currentConversationID)
        let childID = try await conversationAPI.apiSpawnSubAgent(
            parentConversationID: parentConversationID,
            request: SubAgentSpawnRequest(context: .isolated, taskDescription: "spawn child"),
            modelOverride: model
        )
        let child = try #require(await chat.listConversationInfo().first(where: { $0.id == childID }))
        #expect(child.interactionMode == .plan)
        #expect(child.modeProfileID == "child-plan-profile")
    }

    @Test func isolatedSpawnExplicitModePersistsCanonicalBuiltInProfileID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-subagent-explicit-mode-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let model = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-subagent-explicit-mode")
        let modeConfig = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "parent-seeded-chat",
                    extends: InteractionMode.chat.rawValue,
                    subAgents: .object([
                        "childModeOnSpawn": .string("child-plan-profile"),
                    ])
                ),
                .init(
                    id: "child-plan-profile",
                    extends: InteractionMode.plan.rawValue
                ),
            ],
            diagnostics: []
        )
        let modeRegistry = ModeRegistryTestSupport.makePort(seedingBuiltIns: true, modeProfileConfiguration: modeConfig)
        let chat = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: local,
            modeRegistry: modeRegistry
        )
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: chat)

        try await chat.createConversation(
            with: model,
            userSystemPrompt: "parent-seeded",
            interactionMode: .chat,
            modeProfileID: "parent-seeded-chat"
        )
        let parentConversationID = try #require(await chat.currentConversationID)
        let childID = try await conversationAPI.apiSpawnSubAgent(
            parentConversationID: parentConversationID,
            request: SubAgentSpawnRequest(
                context: .isolated,
                taskDescription: "spawn explicit mode child",
                interactionMode: InteractionMode.chat.rawValue
            ),
            modelOverride: model
        )
        let child = try #require(await chat.listConversationInfo().first(where: { $0.id == childID }))
        #expect(child.interactionMode == .chat)
        #expect(child.modeProfileID == InteractionMode.chat.rawValue)
    }

    @Test func isolatedSpawnDeniedWhenModeSubAgentAllowListIsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-subagent-allowlist-denied-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let model = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-subagent-allowlist-denied")
        let modeConfig = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "no-subagents-chat",
                    extends: InteractionMode.chat.rawValue,
                    subAgents: .object([
                        "allow": .array([]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let modeRegistry = ModeRegistryTestSupport.makePort(seedingBuiltIns: true, modeProfileConfiguration: modeConfig)
        let chat = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: local,
            modeRegistry: modeRegistry
        )
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: chat)

        try await chat.createConversation(
            with: model,
            userSystemPrompt: "no-subagents",
            interactionMode: .chat,
            modeProfileID: "no-subagents-chat"
        )
        let parentConversationID = try #require(await chat.currentConversationID)
        do {
            _ = try await conversationAPI.apiSpawnSubAgent(
                parentConversationID: parentConversationID,
                request: SubAgentSpawnRequest(context: .isolated, taskDescription: "denied spawn"),
                modelOverride: model
            )
            Issue.record("Expected sub-agent spawn to be rejected by mode allow-list")
        } catch let ConversationServiceError.runtimeLaneUnavailable(reason) {
            #expect(reason == "subagent_delegate_not_allowed_by_mode_profile")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func isolatedSpawnToolsAllowSetsChildRoutingExplicitToolPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-coord-subagent-tools-allow-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try ConversationBulkMirrorTestSupport.makeContainer()
        let model = ConversationBulkMirrorTestSupport.makeModel(modelName: "coord-subagent-tools-allow")
        let modeRegistry = ModeRegistryTestSupport.makePort(seedingBuiltIns: true)
        let chat = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: local,
            modeRegistry: modeRegistry
        )
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: chat)

        try await chat.createConversation(
            with: model,
            userSystemPrompt: "parent",
            interactionMode: .chat
        )
        let parentConversationID = try #require(await chat.currentConversationID)
        let toolsAllow = [
            MemorySearchToolProvider.searchToolName,
            MemorySearchToolProvider.getToolName,
        ]
        let childID = try await conversationAPI.apiSpawnSubAgent(
            parentConversationID: parentConversationID,
            request: SubAgentSpawnRequest(
                context: .isolated,
                taskDescription: "memory-active-recall",
                interactionMode: "memory-active-recall",
                toolsAllow: toolsAllow
            ),
            modelOverride: model
        )
        let child = try #require(await chat.listConversationInfo().first(where: { $0.id == childID }))
        #expect(child.modeProfileID == "memory-active-recall")
        guard case .allowlist(let tools, let skills)? = child.routingPrefs?.explicitToolPolicy else {
            Issue.record("Expected child routingPrefs.explicitToolPolicy allowlist")
            return
        }
        #expect(tools == toolsAllow)
        #expect(skills.isEmpty)

        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let profile = try await registry.resolve(modeId: "memory-active-recall")
        let gateway = DefaultToolSystemGateway()
        let candidates = ["memory_search", "memory_get", "write_file", "bash", "read_file"]
        let entries = candidates.map {
            ToolRegistryEntry(
                definition: ToolDefinition(name: $0, description: "", parameters: [], type: .function),
                source: .local
            )
        }
        let modeCtx = ModePolicyContext(conversation: child, resolvedProfile: profile)
        let effective = gateway.effectiveToolsForConversation(
            entries: entries,
            conversation: child,
            modePolicyContext: modeCtx,
            configuration: AgentRuntimeTurnConfiguration(
                managerConfiguration: HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)
            ),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        let effectiveNames = Set(effective.map(\.name))
        #expect(effectiveNames == Set(toolsAllow))
        #expect(!effectiveNames.contains("write_file"))
        #expect(!effectiveNames.contains("bash"))
    }
}
