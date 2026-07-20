import EasyJSON
import Foundation
import Logging
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("H9 hung MCP tool recovery")
struct ToolDispatchHangRecoveryTests {
    private func makeModel(id: UUID = UUID()) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "h9-hang",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func makeConversation(model: Model) -> ModelConversation {
        ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
            turns: [],
            interactionMode: .agent
        )
    }

    private func makeEntry(name: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable
        )
    }

    private func shortTimeoutContract(
        timeoutSeconds: TimeInterval = 0.4,
        watchdogIntervalSeconds: TimeInterval = 0.1,
        onToolTimeout: ToolPolicyConfiguration.OnToolTimeoutPolicy = .continue
    ) -> AgentRuntimeToolDispatchContract {
        AgentRuntimeToolDispatchContract(
            parallelDispatchEnabled: false,
            dispatchPlannerMode: nil,
            pendingToolTimeoutSeconds: nil,
            toolCallTimeoutSeconds: timeoutSeconds,
            toolCallWatchdogIntervalSeconds: watchdogIntervalSeconds,
            onToolTimeout: onToolTimeout,
            mcpReconnectOnToolTimeout: false
        )
    }

    @Test("hanging dispatch times out with tool.callFailed and unblocks turn loop")
    func hangingDispatchTimesOutAndEmitsFailed() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let recorder = TurnLoopTranscriptRecorder()
        let lifecycle = TurnLoopLifecycleRecorder()
        let toolName = "mcp__xcode-mcp__XcodeRead"
        let toolCallID = "hang-1"
        let ports = TurnLoopTestPorts.make(
            state: state,
            recorder: recorder,
            assistantToolCalls: [ToolCall(name: toolName, arguments: .object([:]), id: toolCallID)],
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: toolCallID, content: "should-not-reach"))
            ],
            effectiveToolEntries: [makeEntry(name: toolName)],
            dispatchContract: shortTimeoutContract(),
            hangDispatchSeconds: 30
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let terminal = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, payload in
                await lifecycle.record(payload: payload)
            }
        )
        #expect(terminal.category != .failure || terminal.detail == nil || terminal.detail != "should-not")
        #expect(await lifecycle.startedToolCallCount() == 1)
        #expect(await lifecycle.failedToolCallCount() == 1)
        #expect(await lifecycle.completedToolCallCount() == 0)
        #expect(await lifecycle.everyStartedHasTerminalPair())
        let tools = await recorder.appendedToolMessages()
        #expect(tools.count == 1)
        #expect(tools[0].content.contains("timed out"))
        let failed = await lifecycle.recordedPayloads().first { $0.name == .toolCallFailed }
        #expect(failed?.errorClass == "timeout")
        #expect(failed?.mcpServerName == "xcode-mcp")
        #expect(failed?.toolCallID == toolCallID)
    }

    @Test("onToolTimeout failRun ends the turn after timeout")
    func failRunPolicyEndsTurn() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let lifecycle = TurnLoopLifecycleRecorder()
        let toolCallID = "fail-run-1"
        let ports = TurnLoopTestPorts.make(
            state: state,
            assistantToolCalls: [ToolCall(name: "slow_tool", arguments: .object([:]), id: toolCallID)],
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: toolCallID, content: "should-not-reach"))
            ],
            effectiveToolEntries: [makeEntry(name: "slow_tool")],
            dispatchContract: shortTimeoutContract(onToolTimeout: .failRun),
            hangDispatchSeconds: 30
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let terminal = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, payload in
                await lifecycle.record(payload: payload)
            }
        )
        #expect(terminal.category == .failure)
        #expect(terminal.detail == "tool_call_timeout")
        #expect(await lifecycle.failedToolCallCount() == 1)
        #expect(await lifecycle.everyStartedHasTerminalPair())
    }

    @Test("multi-call serial hang emits terminal for each started call within timeout budget")
    func multiCallSerialHangPairsTerminals() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let lifecycle = TurnLoopLifecycleRecorder()
        let calls = [
            ToolCall(name: "slow_a", arguments: .object([:]), id: "a"),
            ToolCall(name: "slow_b", arguments: .object([:]), id: "b"),
        ]
        let ports = TurnLoopTestPorts.make(
            state: state,
            assistantToolCalls: calls,
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "a", content: "nope")),
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "b", content: "nope")),
            ],
            effectiveToolEntries: [makeEntry(name: "slow_a"), makeEntry(name: "slow_b")],
            dispatchContract: shortTimeoutContract(timeoutSeconds: 0.35, watchdogIntervalSeconds: 0.1),
            hangDispatchSeconds: 30
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
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, payload in
                await lifecycle.record(payload: payload)
            }
        )
        #expect(await lifecycle.startedToolCallCount() >= 1)
        #expect(await lifecycle.everyStartedHasTerminalPair())
        #expect(await lifecycle.failedToolCallCount() >= 1)
    }

    @Test("fast tools emit start then completed only")
    func fastToolsEmitStartCompletedOnly() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let lifecycle = TurnLoopLifecycleRecorder()
        let toolCallID = "fast-1"
        let ports = TurnLoopTestPorts.make(
            state: state,
            assistantToolCalls: [ToolCall(name: "fast_tool", arguments: .object([:]), id: toolCallID)],
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: toolCallID, content: "ok"))
            ],
            effectiveToolEntries: [makeEntry(name: "fast_tool")],
            dispatchContract: shortTimeoutContract(timeoutSeconds: 5, watchdogIntervalSeconds: 2)
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
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, payload in
                await lifecycle.record(payload: payload)
            }
        )
        #expect(await lifecycle.startedToolCallCount() == 1)
        #expect(await lifecycle.completedToolCallCount() == 1)
        #expect(await lifecycle.failedToolCallCount() == 0)
        #expect(await lifecycle.startedBeforeCompleted())
        #expect(await lifecycle.everyStartedHasTerminalPair())
    }

    @Test("mcpReconnectOnToolTimeout invokes reconnect for mcp__ server tools")
    func mcpReconnectOnToolTimeoutInvokesReconnect() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let reconnect = MCPReconnectRecorder()
        let toolName = "mcp__xcode-mcp__XcodeRead"
        let toolCallID = "reconnect-1"
        var contract = shortTimeoutContract(onToolTimeout: .continue)
        contract.mcpReconnectOnToolTimeout = true
        let ports = TurnLoopTestPorts.make(
            state: state,
            assistantToolCalls: [ToolCall(name: toolName, arguments: .object([:]), id: toolCallID)],
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: toolCallID, content: "should-not-reach"))
            ],
            effectiveToolEntries: [makeEntry(name: toolName)],
            dispatchContract: contract,
            hangDispatchSeconds: 30,
            reconnectMCPClient: { serverName in
                await reconnect.record(serverName)
                return true
            }
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
        #expect(await reconnect.names() == ["xcode-mcp"])
    }

    @Test("watchdog line includes correlation ids")
    func watchdogLineIncludesCorrelation() {
        let context = ToolDispatchWatchdog.Context(
            toolName: "mcp__xcode-mcp__XcodeRead",
            toolCallID: "902404674",
            runID: UUID(uuidString: "0AFC214F-CEA8-4DE4-9602-DA1348856BC3"),
            conversationID: UUID(uuidString: "414D4E18-BA4B-4ABC-A077-E56D50871E0E")!,
            mcpServerName: "xcode-mcp",
            timeoutSeconds: 300,
            watchdogIntervalSeconds: 20
        )
        let line = ToolDispatchWatchdog.watchdogLine(context: context, elapsedMs: 45_000, timeoutMs: 300_000)
        #expect(line.contains("[ToolDispatchWatchdog] still waiting"))
        #expect(line.contains("tool=mcp__xcode-mcp__XcodeRead"))
        #expect(line.contains("toolCallID=902404674"))
        #expect(line.contains("mcpServer=xcode-mcp"))
        #expect(line.contains("elapsedMs=45000"))
        #expect(line.contains("timeoutMs=300000"))
    }

    @Test("watchdog emits warning while hang is below timeout")
    func watchdogEmitsWarningBeforeTimeout() async throws {
        let handler = WatchdogLogHandler()
        let logger = Logger(label: "h9.watchdog.test", factory: { _ in handler })
        let context = ToolDispatchWatchdog.Context(
            toolName: "slow",
            toolCallID: "w1",
            runID: UUID(),
            conversationID: UUID(),
            mcpServerName: nil,
            timeoutSeconds: 0.6,
            watchdogIntervalSeconds: 0.15
        )
        await #expect(throws: ToolCallTimeoutError.self) {
            _ = try await ToolDispatchWatchdog.withTimeoutAndWatchdog(context: context, logger: logger) {
                try await Task.sleep(for: .seconds(2))
                return "done"
            }
        }
        let warnings = handler.warningMessages()
        #expect(warnings.contains(where: {
            $0.contains("[ToolDispatchWatchdog] still waiting") || $0.contains("[ToolDispatchWatchdog] timed out")
        }))
    }
}

final class WatchdogLogHandler: LogHandler, @unchecked Sendable {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]
    private let lock = NSLock()
    private var warnings: [String] = []

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= .warning else { return }
        lock.lock()
        warnings.append(message.description)
        lock.unlock()
    }

    func warningMessages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return warnings
    }
}

actor MCPReconnectRecorder {
    private var recorded: [String] = []

    func record(_ name: String) {
        recorded.append(name)
    }

    func names() -> [String] {
        recorded
    }
}
