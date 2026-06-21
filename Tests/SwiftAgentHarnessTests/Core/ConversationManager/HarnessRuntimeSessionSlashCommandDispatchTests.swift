import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor SlashDispatchEventRecorder: ConversationTopicPublishing {
    private var payloads: [ConversationTopicEventPayload] = []

    func publishPersistedConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        transcriptSequence: Int
    ) async {
        let _ = conversationID
        let _ = transcriptSequence
        payloads.append(payload)
    }

    func publishTransientConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        runID: UUID,
        modelCallId: UUID?
    ) async {
        let _ = conversationID
        let _ = runID
        let _ = modelCallId
        payloads.append(payload)
    }

    func publishConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload) async {
        let _ = conversationID
        payloads.append(payload)
    }

    func runtimeLifecycleEvents() -> [RuntimeLifecycleEventPayload] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return payloads.compactMap { payload in
            guard payload.semanticKind == .runtimeLifecycle,
                  let json = payload.jsonUTF8,
                  let data = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(RuntimeLifecycleEventPayload.self, from: data)
        }
    }
}

private enum HarnessRuntimeSessionSlashDispatchSupport {
    static func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    static func makeModel(name: String = "slash:test") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func transformWithToolDispatch(command: String, toolName: String) -> ConversationTransformConfiguration {
        ConversationTransformConfiguration(
            chat: .allEnabled,
            plan: .allEnabled,
            agent: .allEnabled,
            transformTimeoutSeconds: 1800,
            contextCompaction: .default,
            slashCommands: SlashCommandConfiguration(
                enabled: true,
                allowUnknownPassthrough: true,
                compactEnabled: true,
                skillSlashEnabled: true,
                toolDispatchCommands: [
                    .init(
                        command: command,
                        toolName: toolName,
                        argMode: .raw,
                        description: "Dispatch \(command) to \(toolName)"
                    ),
                ]
            )
        )
    }
}

@Suite("HarnessRuntimeSession slash command dispatch", .serialized)
struct HarnessRuntimeSessionSlashCommandDispatchTests {
    @Test("Compact slash command short-circuits before persisting user slash text")
    func compactSlashShortCircuit() async throws {
        let container = try HarnessRuntimeSessionSlashDispatchSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = HarnessRuntimeSessionSlashDispatchSupport.makeModel()

        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        _ = try await manager.sendMessageAndStreamResponse("/compact reason for compaction", images: [], conversationID: conversationID)

        let messages = try await manager.listCurrentMessages()
        #expect(!messages.contains(where: { $0.role == .user && $0.content.contains("/compact") }))
        #expect(messages.contains(where: { $0.role == .assistant && $0.content.contains("Conversation compacted:") }))
    }

    @Test("listSlashCommandsForAPI includes builtin /compact with metadata")
    func listSlashCommandsIncludesCompact() async throws {
        let container = try HarnessRuntimeSessionSlashDispatchSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = HarnessRuntimeSessionSlashDispatchSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await manager.currentConversationID)
        let rows = try await manager.conversationToolModePolicyRuntimeService.listSlashCommandsForAPI(conversationID: cid)
        let compact = try #require(rows.first { $0.name == "/compact" })
        #expect(compact.description.contains("Compact"))
        #expect(compact.hiddenKeywords.contains("shrink"))
        #expect(compact.bypassTier == .queued)
    }

    @Test("toolDispatch slash executes via direct tool invocation path")
    func toolDispatchSlashExecutes() async throws {
        let container = try HarnessRuntimeSessionSlashDispatchSupport.makeContainer()
        let manager = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: HarnessRuntimeSessionSlashDispatchSupport.transformWithToolDispatch(
                command: "queue",
                toolName: ConversationsToolProvider.listConversationsToolName
            )
        )
        let model = HarnessRuntimeSessionSlashDispatchSupport.makeModel(name: "slash:tool-dispatch")
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await manager.currentConversationID)

        let response = try await manager.testing_runSlashCommandIfNeeded("/queue list all", conversationID: cid)
        #expect(response != nil)

        let rows = try await manager.conversationToolModePolicyRuntimeService.listSlashCommandsForAPI(conversationID: cid)
        #expect(rows.contains { $0.name == "/queue" })
        let messages = try await manager.listCurrentMessages()
        #expect(!messages.contains { $0.role == .user && $0.content.contains("/queue") })
        #expect(messages.contains { $0.role == .assistant && !$0.content.isEmpty })
    }

    @Test("toolDispatch slash fans out runtime lifecycle into derived audit and trace")
    func toolDispatchLifecycleFanout() async throws {
        let container = try HarnessRuntimeSessionSlashDispatchSupport.makeContainer()
        let manager = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: HarnessRuntimeSessionSlashDispatchSupport.transformWithToolDispatch(
                command: "queue",
                toolName: ConversationsToolProvider.listConversationsToolName
            )
        )
        let model = HarnessRuntimeSessionSlashDispatchSupport.makeModel(name: "slash:tool-fanout")
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await manager.currentConversationID)
        let recorder = SlashDispatchEventRecorder()
        await manager.setConversationTopicPublisher(recorder)

        _ = try await manager.testing_runSlashCommandIfNeeded("/queue list all", conversationID: cid)

        let runtimeEvents = await recorder.runtimeLifecycleEvents()
        let topicCompleted = try #require(runtimeEvents.last(where: { $0.name == .toolCallCompleted }))

        let kind = ConversationEventKind.toolAuditLifecycleEvent.rawValue
        let rows = await HarnessConversationTestFixtures.journalEvents(
            host: manager,
            conversationID: cid,
            kind: kind
        )
        #expect(!rows.isEmpty)
        let decoded = rows.compactMap {
            ConversationEventCodec.decode(ToolAuditLifecycleEventPayload.self, from: $0.payloadJSON)
        }
        #expect(decoded.contains { $0.name == .toolCallStarted })
        let auditCompleted = try #require(decoded.last(where: { $0.name == .toolCallCompleted }))

        let trace = await manager.traceSnapshotForConversationAPI(conversationID: cid)
        let traceCompleted = try #require(trace.spans.last(where: {
            $0.name == RuntimeLifecycleEventName.toolCallCompleted.rawValue
        }))

        #expect(topicCompleted.toolCallID == auditCompleted.toolCallID)
        #expect(topicCompleted.toolCallID == traceCompleted.attributes?["toolCallID"])
        #expect(topicCompleted.toolName == auditCompleted.toolName)
        #expect(topicCompleted.toolName == traceCompleted.attributes?["toolName"])
        #expect(topicCompleted.argumentDigest == auditCompleted.argumentDigest)
        #expect(topicCompleted.argumentDigest == traceCompleted.attributes?["argumentDigest"])
        #expect(topicCompleted.executionEnvironmentKind == auditCompleted.executionEnvironmentKind)
        #expect(topicCompleted.executionEnvironmentKind == traceCompleted.attributes?["executionEnvironmentKind"])
    }

    @Test("toolDispatch deny behavior matches model availability gate")
    func toolDispatchDenyParityWithModelAvailability() async throws {
        let container = try HarnessRuntimeSessionSlashDispatchSupport.makeContainer()
        let manager = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration.unrestricted,
            conversationTransformConfiguration: HarnessRuntimeSessionSlashDispatchSupport.transformWithToolDispatch(
                command: "queue",
                toolName: ConversationsToolProvider.listConversationsToolName
            )
        )
        let model = HarnessRuntimeSessionSlashDispatchSupport.makeModel(name: "slash:deny-parity")
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: manager)
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await manager.currentConversationID)
        let patch = ConversationPatch(
            expectedRevision: try #require(await conversationAPI.apiGetConversation(id: cid)).controlPlaneRevision,
            routingToolPolicy: .denylist(
                tools: [ConversationsToolProvider.listConversationsToolName],
                skills: []
            )
        )
        try await conversationAPI.apiPatchConversation(conversationID: cid, patch: patch)
        let conversation = try #require(await conversationAPI.apiGetConversation(id: cid))
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(
                name: ConversationsToolProvider.listConversationsToolName,
                description: "",
                parameters: [],
                type: .function
            ),
            source: .local
        )
        let snapshots = await manager.orchestratorRuntimeService.toolAvailabilitySnapshots(
            allEntries: [entry],
            conversation: conversation,
            configuration: HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)
        )
        #expect(snapshots.first?.decision.blockReason == .routingToolWhitelist)

        let response = try await manager.testing_runSlashCommandIfNeeded("/queue list all", conversationID: cid)
        #expect(response != nil)
        let messages = try await manager.listCurrentMessages()
        #expect(messages.contains { message in
            message.role == .assistant && message.content.contains("Tool dispatch blocked by policy")
        })
    }
}
