import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("Active memory NONE contract")
struct ActiveMemoryNoneContractTests {
    @Test("noteOrNil treats NONE variants and empty as miss")
    func noneIsMiss() {
        #expect(ActiveMemoryRecallOutput.noteOrNil("NONE") == nil)
        #expect(ActiveMemoryRecallOutput.noteOrNil(" none ") == nil)
        #expect(ActiveMemoryRecallOutput.noteOrNil("None.") == nil)
        #expect(ActiveMemoryRecallOutput.noteOrNil("`NONE`") == nil)
        #expect(ActiveMemoryRecallOutput.noteOrNil("") == nil)
        #expect(ActiveMemoryRecallOutput.noteOrNil("   \n") == nil)
    }

    @Test("noteOrNil returns trimmed useful notes")
    func usefulNote() {
        let note = "  User prefers Grafana for latency reviews.  "
        #expect(ActiveMemoryRecallOutput.noteOrNil(note) == "User prefers Grafana for latency reviews.")
        #expect(ActiveMemoryRecallOutput.noteOrNil("NONE of the dashboards are deprecated") != nil)
    }

    @Test("prompts encode NONE silence contract without say-so-briefly")
    func promptsEncodeContract() {
        let situational = ActiveMemoryPreReplyPrompts.prompts(for: .situational, query: "q").system
        let standing = ActiveMemoryPreReplyPrompts.prompts(for: .standing, query: nil).system
        for prompt in [situational, standing] {
            #expect(prompt.contains("NONE"))
            #expect(prompt.lowercased().contains("silence") || prompt.lowercased().contains("prefer silence"))
            #expect(prompt.lowercased().contains("third-person"))
            #expect(prompt.contains("\(MemoryConfiguration.default.activeMemoryMaxSummaryChars)"))
            #expect(prompt.contains("<memory-context>"))
            #expect(prompt.contains("[Active Memory Recall]"))
            #expect(prompt.lowercased().contains("ignore"))
            #expect(prompt.lowercased().contains("do not restate") || prompt.contains("Do not restate"))
            #expect(!prompt.contains("say so briefly"))
            #expect(prompt.contains("Bad:"))
            #expect(prompt.contains("Good:"))
        }
    }

    @Test("combined recall skips injection when lanes return NONE prose via runner")
    func noneFromRunnerDoesNotCombine() async {
        final class NoneRunner: ActiveMemoryPreReplyRunning, @unchecked Sendable {
            func blockingRecallSummary(
                session: MemorySessionContext,
                userQuery: String?,
                lane: RecallLane,
                timeoutMs: Int,
                maxSummaryChars: Int
            ) async -> String? {
                // Simulate spawn adapter already parsing NONE → nil
                ActiveMemoryRecallOutput.noteOrNil("NONE")
            }
        }
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(NoneRunner())
        let session = MemorySessionContext(
            conversationID: UUID(),
            cwd: "/tmp",
            canonicalGitRoot: nil,
            memoryDirectory: URL(fileURLWithPath: "/tmp/memory"),
            chatType: .direct
        )
        let result = await service.recallSummaryIfEnabled(session: session, userQuery: "hello")
        #expect(result == nil)
    }
}

@Suite("TurnLoop active memory NONE skip")
struct TurnLoopActiveMemoryNoneTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "turn-loop-memory-none",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("nil recall does not prepend Active Memory Recall")
    func nonePathSkipsInjection() async throws {
        let model = makeModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "find grafana notes", timestamp: Date())],
            turns: [],
            interactionMode: .chat
        )
        let state = TurnLoopConversationState(conversation: conversation)
        let capture = TurnLoopNoneStreamCapture()
        let basePorts = TurnLoopTestPorts.make(state: state)
        let memoryPort = SessionRuntimeMemoryPort(
            recallFn: { _, _ in nil },
            prefetchFn: { _, _ in }
        )
        let modelPort = SessionRuntimeModelPort(
            ensureBoundFn: { conv, _ in conv.model.id },
            streamLLM: { messages, _, _, _, _, _, _ in
                await capture.record(messages)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [])))
                    continuation.finish()
                }
            }
        )
        let ports = AgentLoopPorts(
            model: modelPort,
            context: basePorts.context,
            tools: basePorts.tools,
            conversation: basePorts.conversation,
            memory: memoryPort,
            agentHarness: basePorts.agentHarness,
            contextCompaction: basePorts.contextCompaction,
            modeRegistry: basePorts.modeRegistry,
            logger: basePorts.logger
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let streamed = await capture.messages()
        #expect(!streamed.contains(where: { $0.content.contains("[Active Memory Recall]") }))
    }
}

private actor TurnLoopNoneStreamCapture {
    private var streamed: [Message] = []

    func record(_ messages: [Message]) {
        streamed = messages
    }

    func messages() -> [Message] {
        streamed
    }
}
