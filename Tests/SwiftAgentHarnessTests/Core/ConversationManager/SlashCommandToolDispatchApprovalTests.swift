import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import Testing
@testable import SwiftAgentHarness

private actor SlashApprovalDispatchEventRecorder: ConversationTopicPublishing {
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

@Suite("Slash tool-dispatch approval", .serialized)
struct SlashCommandToolDispatchApprovalTests {
    @Test("approval-gated slash dispatch registers pending approval and resumes after approve")
    func approvalGatedSlashDispatchResumesAfterApprove() async throws {
        let container = try HarnessRuntimeSessionSlashDispatchSupport.makeContainer()
        let toolName = ConversationsToolProvider.listConversationsToolName
        let manager = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(approvalRequiredToolNames: [toolName]),
            conversationTransformConfiguration: HarnessRuntimeSessionSlashDispatchSupport.transformWithToolDispatch(
                command: "queue",
                toolName: toolName
            ),
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = HarnessRuntimeSessionSlashDispatchSupport.makeModel(name: "slash:approval-resume")
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await manager.currentConversationID)
        let recorder = SlashApprovalDispatchEventRecorder()
        await manager.setConversationTopicPublisher(recorder)

        let dispatchTask = Task {
            try await manager.testing_runSlashCommandIfNeeded("/queue list all", conversationID: cid)
        }
        for _ in 0..<100 {
            let lifecycle = await recorder.runtimeLifecycleEvents()
            if lifecycle.contains(where: {
                $0.name == .toolApprovalRequired && $0.toolName == toolName
            }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let conversation = try #require(await manager.modelConversation(id: cid))
        let slashBinding = slashApprovalBinding(toolName: toolName, rawText: "/queue list all")
        await manager.toolApprovalRuntimeService.applyToolApprovalResolution(
            conversationID: cid,
            runID: conversation.currentRunID,
            binding: slashBinding,
            route: .user,
            status: .approved,
            source: "test",
            reason: nil,
            kind: .manual,
            decision: .allowOnce,
            policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
            publicationSource: "test"
        )
        let response = try await dispatchTask.value
        #expect(response != nil)

        let lifecycle = await recorder.runtimeLifecycleEvents()
        let approvalRequired = try #require(lifecycle.first(where: {
            $0.name == .toolApprovalRequired && $0.toolName == toolName
        }))
        #expect(approvalRequired.approvalState == .pending)
        #expect(approvalRequired.source == "slash.toolDispatch")
        #expect(lifecycle.contains { $0.name == .toolCallStarted && $0.toolName == toolName })
        #expect(lifecycle.contains { $0.name == .toolCallCompleted && $0.toolName == toolName })

        let messages = try await manager.listCurrentMessages()
        #expect(messages.contains { $0.role == .assistant && !$0.content.contains("Tool dispatch denied") })
        #expect(!messages.contains { $0.role == .assistant && $0.content.contains("Tool dispatch blocked by policy") })
        #expect(!messages.contains { $0.role == .assistant && $0.content.contains("requires approval before execution") })
    }

    @Test("denied approval prevents slash tool execution")
    func deniedApprovalBlocksSlashDispatch() async throws {
        let container = try HarnessRuntimeSessionSlashDispatchSupport.makeContainer()
        let toolName = ConversationsToolProvider.listConversationsToolName
        let manager = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(approvalRequiredToolNames: [toolName]),
            conversationTransformConfiguration: HarnessRuntimeSessionSlashDispatchSupport.transformWithToolDispatch(
                command: "queue",
                toolName: toolName
            ),
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = HarnessRuntimeSessionSlashDispatchSupport.makeModel(name: "slash:approval-deny")
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await manager.currentConversationID)
        let recorder = SlashApprovalDispatchEventRecorder()
        await manager.setConversationTopicPublisher(recorder)

        let dispatchTask = Task {
            try await manager.testing_runSlashCommandIfNeeded("/queue list all", conversationID: cid)
        }
        for _ in 0..<100 {
            let lifecycle = await recorder.runtimeLifecycleEvents()
            if lifecycle.contains(where: {
                $0.name == .toolApprovalRequired && $0.toolName == toolName
            }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let conversation = try #require(await manager.modelConversation(id: cid))
        await manager.toolApprovalRuntimeService.applyToolApprovalResolution(
            conversationID: cid,
            runID: conversation.currentRunID,
            binding: slashApprovalBinding(toolName: toolName, rawText: "/queue list all"),
            route: .user,
            status: .denied,
            source: "test",
            reason: "user denied",
            kind: .manual,
            policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
            publicationSource: "test"
        )
        _ = try await dispatchTask.value

        let lifecycle = await recorder.runtimeLifecycleEvents()
        #expect(lifecycle.contains { $0.name == .toolApprovalRequired && $0.toolName == toolName })
        #expect(!lifecycle.contains { $0.name == .toolCallStarted && $0.toolName == toolName })

        let messages = try await manager.listCurrentMessages()
        #expect(messages.contains { $0.role == .assistant && $0.content.contains("Tool dispatch denied") })
    }

    @Test("non-gated slash tool dispatch unchanged")
    func nonGatedSlashDispatchUnchanged() async throws {
        let container = try HarnessRuntimeSessionSlashDispatchSupport.makeContainer()
        let toolName = ConversationsToolProvider.listConversationsToolName
        let manager = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: HarnessRuntimeSessionSlashDispatchSupport.transformWithToolDispatch(
                command: "queue",
                toolName: toolName
            ),
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = HarnessRuntimeSessionSlashDispatchSupport.makeModel(name: "slash:non-gated")
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await manager.currentConversationID)
        let recorder = SlashApprovalDispatchEventRecorder()
        await manager.setConversationTopicPublisher(recorder)

        let response = try await manager.testing_runSlashCommandIfNeeded("/queue list all", conversationID: cid)
        #expect(response != nil)

        let lifecycle = await recorder.runtimeLifecycleEvents()
        #expect(!lifecycle.contains { $0.name == .toolApprovalRequired })
        #expect(lifecycle.contains { $0.name == .toolCallCompleted && $0.toolName == toolName })
    }
}

private func slashApprovalBinding(toolName: String, rawText: String) -> ToolCallApprovalBinding {
    let parsedName = rawText.split(separator: " ").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "queue"
    let argsText = rawText.split(separator: " ", maxSplits: 1).dropFirst().joined(separator: " ")
    let envelope = RawToolCommandEnvelope(
        envelopeVersion: "1",
        rawText: rawText,
        commandToken: "/\(parsedName)",
        commandName: parsedName,
        argsText: argsText,
        parsedTokens: argsText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    )
    let request = ToolInvocationRequest(
        toolName: toolName,
        argumentsPayload: .object([:]),
        argumentMode: .raw,
        rawEnvelope: envelope,
        source: .command
    )
    return ToolCallApprovalBinding.from(invocation: request)
}

private enum HarnessRuntimeSessionSlashDispatchSupport {
    static func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
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
