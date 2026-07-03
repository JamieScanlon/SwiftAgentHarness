import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum WebSocketCoverageHarnessSupport {
    private final class ContainerHarnessBinding {
        weak var container: ModelContainer?
        let harness: InMemoryHarnessSessionPersistence

        init(container: ModelContainer, harness: InMemoryHarnessSessionPersistence) {
            self.container = container
            self.harness = harness
        }
    }

    private final class Registry: @unchecked Sendable {
        private var bindingsByContainerID: [ObjectIdentifier: ContainerHarnessBinding] = [:]
        private let lock = NSLock()

        func shared(for container: ModelContainer) -> InMemoryHarnessSessionPersistence {
            lock.lock()
            defer { lock.unlock() }
            pruneDeadBindings()
            let key = ObjectIdentifier(container)
            if let binding = bindingsByContainerID[key], binding.container === container {
                return binding.harness
            }
            let created = InMemoryHarnessSessionPersistence()
            bindingsByContainerID[key] = ContainerHarnessBinding(container: container, harness: created)
            return created
        }

        private func pruneDeadBindings() {
            bindingsByContainerID = bindingsByContainerID.filter { $0.value.container != nil }
        }
    }

    private static let registry = Registry()

    static func sharedHarness(for container: ModelContainer) -> InMemoryHarnessSessionPersistence {
        registry.shared(for: container)
    }
}

private final class WebSocketStubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]

    init(models: [Model]) {
        self.models = models
    }

    func getAvailableModels() async -> [Model] {
        models
    }
}

private actor WebSocketScriptedToolThenAnswerLLM: LLMProtocol {
    private var streamCallCount: Int = 0
    private let toolName: String
    private let toolCallID: String
    private let finalAssistantText: String

    init(toolName: String, toolCallID: String, finalAssistantText: String) {
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.finalAssistantText = finalAssistantText
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "ws-tool-roundtrip-llm" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion, .tools] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        if streamCallCount == 0 {
            streamCallCount += 1
            return LLMResponse(
                content: "",
                toolCalls: [ToolCall(name: toolName, arguments: .object([:]), id: toolCallID)]
            )
        }
        streamCallCount += 1
        return MessageOutputTestSupport.messageToolLLMResponse(
            text: finalAssistantText,
            toolCallID: "call_message_\(streamCallCount)"
        )
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            Task {
                let response = await self.nextResponse()
                continuation.yield(.complete(response))
                continuation.finish()
            }
        }
    }

    private func nextResponse() -> LLMResponse {
        if streamCallCount == 0 {
            streamCallCount += 1
            return LLMResponse(
                content: "",
                toolCalls: [ToolCall(name: toolName, arguments: .object([:]), id: toolCallID)]
            )
        }
        streamCallCount += 1
        return MessageOutputTestSupport.messageToolLLMResponse(
            text: finalAssistantText,
            toolCallID: "call_message_\(streamCallCount)"
        )
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor WebSocketScriptedToolErrorThenAnswerLLM: LLMProtocol {
    private var streamCallCount: Int = 0

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "ws-tool-error-llm" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion, .tools] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        if streamCallCount == 0 {
            streamCallCount += 1
            return LLMResponse(
                content: "",
                toolCalls: [
                    ToolCall(
                        name: ConversationsToolProvider.getConversationToolName,
                        arguments: .object(["conversationID": .string("not-a-uuid")]),
                        id: "call_ws_tool_error_1"
                    ),
                ]
            )
        }
        streamCallCount += 1
        return LLMResponse(content: "Handled tool failure.", toolCalls: [])
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.send([], config: LLMRequestConfig())
                    continuation.yield(.complete(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor WebSocketSlowToolThenAnswerLLM: LLMProtocol {
    private var streamCallCount: Int = 0

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "ws-tool-cancel-llm" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion, .tools] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        if streamCallCount == 0 {
            streamCallCount += 1
            return LLMResponse(
                content: "",
                toolCalls: [
                    ToolCall(
                        name: ConversationsToolProvider.listConversationsToolName,
                        arguments: .object([:]),
                        id: "call_ws_cancel_tool_1"
                    ),
                ]
            )
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        streamCallCount += 1
        return LLMResponse(content: "This should be cancelled.", toolCalls: [])
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.send([], config: LLMRequestConfig())
                    continuation.yield(.complete(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor WebSocketToolThenTimeoutLLM: LLMProtocol {
    private var streamCallCount: Int = 0

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "ws-tool-timeout-llm" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion, .tools] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        if streamCallCount == 0 {
            streamCallCount += 1
            return LLMResponse(
                content: "",
                toolCalls: [
                    ToolCall(
                        name: ConversationsToolProvider.listConversationsToolName,
                        arguments: .object([:]),
                        id: "call_ws_timeout_tool_1"
                    ),
                ]
            )
        }
        throw LLMError.timeout
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.send([], config: LLMRequestConfig())
                    continuation.yield(.complete(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor WebSocketStreamingChunksLLM: LLMProtocol {
    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "ws-streaming-chunks-llm" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        return LLMResponse(content: "stream-final", toolCalls: [])
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in ["alpha", "beta", "gamma", "delta", "epsilon"] {
                    continuation.yield(.stream(LLMResponse(content: chunk, toolCalls: [])))
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                continuation.yield(.complete(LLMResponse(content: "stream-final", toolCalls: [])))
                continuation.finish()
            }
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private struct WebSocketScriptedLLMFactory: ModelLLMFactoring {
    let llm: any LLMProtocol

    func makeBaseLLM(
        model: Model,
        providerBindings: [ProviderBinding]?,
        conversationID: UUID?,
        ownerAccountID: UUID?,
        systemPrompt: SystemPrompt,
        logger: Logger?,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?
    ) -> any LLMProtocol {
        let _ = (model, providerBindings, conversationID, ownerAccountID, systemPrompt, logger, attemptObserver)
        return llm
    }
}

fileprivate enum APILayerWebSocketTestSupport {
    private static let suiteContainer: ModelContainer = {
        try! HarnessTestModelContainer.makeInMemory()
    }()

    static func makeContainer() throws -> ModelContainer {
        suiteContainer
    }

    static let webSocketSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Keep hangs bounded when awaiting socket frames in tests.
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    static func makeTestModel(id: UUID = UUID()) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "ws-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

}

@Suite("APILayer WebSocket routes", .serialized, .timeLimit(.minutes(2)))
struct APILayerWebSocketCoverageTests {
    private func splitGatewayServices(runtimeSession: HarnessRuntimeSession) async -> APILayerChatGatewayServices {
        await makeSplitGatewayServices(runtimeSession: runtimeSession)
    }

    private func stopWebSocketTestServer(api: APILayer, runtimeSession: HarnessRuntimeSession) async {
        await runtimeSession.shutdownOrchestratorAndToolRuntimes()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            final class StopGate: @unchecked Sendable {
                private var resumed = false
                private let lock = NSLock()

                func resumeOnce(_ action: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard resumed == false else { return }
                    resumed = true
                    action()
                }
            }

            let gate = StopGate()
            Task {
                await api.stop()
                gate.resumeOnce { continuation.resume() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(5)) {
                gate.resumeOnce { continuation.resume() }
            }
        }
    }

    private func createConversationID(
        conversationAPI: any APILayerConversationManaging,
        model: Model,
        prompt: String
    ) async throws -> UUID {
        try await conversationAPI.apiCreateConversation(
            with: model,
            userSystemPrompt: prompt,
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            modeProfileID: nil,
            cwd: nil
        )
    }

    @Test("WS connect stays idle until client subscribes")
    func websocketHandshake() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServer(models: [model]) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            let frame = try await receiveJSONIfAvailable(task, timeoutNanos: 250_000_000)
            #expect(frame == nil)
        }
    }

    @Test("Separate WebSocket connections can subscribe independently")
    func websocketDistinctConnectionsMintDistinctClientSessions() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServer(models: [model]) { port, _ in
            let task1 = try makeWebSocketTask(port: port)
            defer { task1.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task1)

            let task2 = try makeWebSocketTask(port: port)
            defer { task2.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task2)
        }
    }

    @Test("WS subscribe models/registry returns harness snapshot")
    func websocketSubscribeModelsRegistrySnapshot() async throws {
        let fixture = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerAndModelState(models: [fixture]) { port, _, hub in
            // Seed the registry so subscribers receive the fixture in the initial snapshot.
            await hub.cacheRegistrySnapshot(ModelsRegistryPayload(models: [fixture]))

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["kind": "subscribe", "topic": ResourceTopicName.modelsRegistry])
            let payload = try await receiveJSON(kind: "snapshot", from: task, maxMessages: 4)
            #expect(payload["topic"] as? String == ResourceTopicName.modelsRegistry)
            let value = payload["value"] as? [String: Any]
            let modelsArr = value?["models"] as? [[String: Any]]
            #expect(modelsArr?.count == 1)
            #expect(modelsArr?.first?["id"] as? String == fixture.id.uuidString)
        }
    }

    @Test("WS send_trigger_message returns removal error")
    func websocketTriggerRemoved() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "send_trigger_message", "id": UUID().uuidString])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS invalid JSON returns error response")
    func websocketInvalidJSON() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await task.send(.string("{invalid-json"))
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Invalid JSON")
        }
    }

    @Test("WS unknown request type returns error")
    func websocketUnknownType() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "unknown_type"])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS send_message returns removal error")
    func websocketSendMessageRemoved() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "send_message", "message": "hello"])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS conversation events subscribe returns messagesRefresh snapshot aligned with persisted messages")
    func websocketConversationEventsSubscribeHydratesTranscriptWire() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerConversationEvents(models: [model]) { port, runtimeSession, _ in
            let conversationAPI = runtimeSession
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-events-hydrate"
            )
            let topic = ConversationTopicFormat.topic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == topic)
            let value = try #require(snap["value"] as? [String: Any])
            #expect(value["semanticKind"] as? String == "messagesRefresh")
            let jsonUTF8 = try #require(value["jsonUTF8"] as? String)
            let data = try #require(jsonUTF8.data(using: .utf8))
            let decoded = try JSONSerialization.jsonObject(with: data)
            let conversation = await conversationAPI.apiGetConversation(id: cid)
            let expectedCount = conversation?.messages.count ?? 0
            // Server encodes either a bare array of message rows (when no transcript sequence
            // is known) or `{"messages": [...], "latestTranscriptSequence": N}`. Each row is
            // a JSON object (`[String: Any]`), not a sub-array, so cast accordingly.
            if let rows = decoded as? [[String: Any]] {
                #expect(rows.count == expectedCount)
            } else if let obj = decoded as? [String: Any], let rows = obj["messages"] as? [[String: Any]] {
                #expect(rows.count == expectedCount)
            } else {
                Issue.record("Expected transcript jsonUTF8 to decode as rows array or {\"messages\":[...]}; got \(type(of: decoded))")
            }
        }
    }

    @Test("WS list_conversations is rejected after migration")
    func websocketListConversations() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "list_conversations"])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS send_trigger_message always returns removal error")
    func websocketTriggerRemovedUnknownConversation() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "send_trigger_message",
                "message": "trigger test",
                "id": UUID().uuidString
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("REST conversations list item contains expected keys")
    func websocketListConversationsItemShape() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServer(models: [model]) { port, runtimeSession in
            _ = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "shape-test"
            )
            let response = try await receiveRESTJSON(path: "/api/conversations", port: port)
            let items = response["items"] as? [[String: Any]]
            #expect((items?.isEmpty == false))
            let keys = items?.first.map { Set($0.keys) } ?? Set<String>()
            let required: Set<String> = ["id", "modelName", "updatedAt", "messageCount", "lifecycle", "controlPlaneRevision"]
            #expect(required.isSubset(of: keys))
        }
    }

    @Test("WS select_conversation returns removal error")
    func websocketSelectConversationRemoved() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "select_conversation", "id": "not-a-uuid"])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS create_conversation returns removal error")
    func websocketCreateConversationRemoved() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "create_conversation", "id": UUID().uuidString, "message": "prompt"])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS copy_conversation returns removal error")
    func websocketCopyConversationRemoved() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "copy_conversation", "sourceID": "missing-model"])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS revert_to_message returns removal error")
    func websocketRevertToMessageRemoved() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "revert_to_message", "id": "not-a-uuid"])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS split_conversation returns removal error")
    func websocketSplitConversationRemoved() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "split_conversation", "id": "not-a-uuid"])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS stop_agent_build returns removal error")
    func websocketStopAgentBuildRemoved() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "stop_agent_build",
                "conversationID": UUID().uuidString,
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS delete_conversation returns removal error")
    func websocketDeleteConversationRemoved() async throws {
        try await withRunningWebSocketServer(models: []) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, ["type": "delete_conversation", "id": "not-a-uuid"])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS patch_conversation returns removal error")
    func websocketPatchConversationRemoved() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServer(models: [model]) { port, runtimeSession in
            let conversationAPI = runtimeSession
            let conversationID = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws patch removed"
            )

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "patch_conversation",
                "id": conversationID.uuidString,
                "patch": [
                    "topic": "WS Updated Topic",
                    "expectedRevision": 0,
                ],
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
            let updated = await conversationAPI.apiGetConversation(id: conversationID)
            #expect(updated?.topic != "WS Updated Topic")
        }
    }

    @Test("WS spawn_sub_agent is removed and returns migration guidance")
    func websocketSpawnSubAgentRemoved() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServer(models: [model]) { port, runtimeSession in
            let parentID = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "parent"
            ).uuidString
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "spawn_sub_agent",
                "id": parentID,
                "context": "isolated",
                "taskDescription": "ws task",
                "prompt": "ws normalized prompt",
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS resolve_tool_approval is removed and returns migration guidance")
    func websocketResolveToolApprovalRemoved() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServer(models: [model]) { port, runtimeSession in
            let conversationID = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "parent"
            ).uuidString
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "resolve_tool_approval",
                "id": conversationID,
                "message": "delegate_remote_research",
                "approvalStatus": "approved",
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    @Test("WS push_completion_announce is removed and returns migration guidance")
    func websocketPushCompletionAnnounceRemoved() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServer(models: [model]) { port, runtimeSession in
            let conversationID = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws completion"
            ).uuidString
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "push_completion_announce",
                "id": conversationID,
                "delegateHandleID": "handle-ws",
                "toolCallID": "tool-call-ws",
                "lifecycleID": "handle-ws",
                "completionStatus": "done",
                "toolMessageContent": "ws completion done"
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(response, contains: "Harness control message requires kind")
        }
    }

    private func startWebSocketTestServer(_ api: APILayer) async throws {
        let startTimeoutError = NSError(
            domain: "APILayerWebSocketCoverageTests",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for WebSocket test server to start"]
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class StartGate: @unchecked Sendable {
                private var resumed = false
                private let lock = NSLock()

                func resumeOnce(_ action: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard resumed == false else { return }
                    resumed = true
                    action()
                }
            }

            let gate = StartGate()
            Task {
                do {
                    try await api.start()
                    gate.resumeOnce { continuation.resume() }
                } catch {
                    gate.resumeOnce { continuation.resume(throwing: error) }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(15)) {
                gate.resumeOnce { continuation.resume(throwing: startTimeoutError) }
            }
        }
    }

    private func withRunningWebSocketServer(
        models: [Model],
        _ body: (Int, any APILayerConversationManaging) async throws -> Void
    ) async throws {
        let api = APILayer(port: 0)
        let container = try APILayerWebSocketTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: WebSocketCoverageHarnessSupport.sharedHarness(for: container))
        let modelProvider = WebSocketStubModelProvider(models: models)
        let gateway = await splitGatewayServices(runtimeSession: runtimeSession)
        await api.setChatGatewayServices(gateway)
        await api.setModelProvider(modelProvider)
        try await startWebSocketTestServer(api)
        let port = await api.listeningPort
        do {
            try await body(port, gateway.conversation)
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
        } catch {
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
            throw error
        }
    }

    /// Starts `/ws` with ``APILayer/setConversationEventsWireResources`` for `conversation/{id}/events` tests.
    private func withRunningWebSocketServerConversationEvents(
        models: [Model],
        replayRetention: TranscriptTailRetentionPolicy? = nil,
        _ body: (Int, any APILayerConversationManaging, ConversationEventsTopicHub) async throws -> Void
    ) async throws {
        let api = APILayer(port: 0)
        let container = try APILayerWebSocketTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: WebSocketCoverageHarnessSupport.sharedHarness(for: container))
        let modelProvider = WebSocketStubModelProvider(models: models)
        let conversationHub = ConversationEventsTopicHub()
        await runtimeSession.setConversationTopicPublisher(ConversationEventsHubOnlyPublisher(hub: conversationHub))
        let gateway = await splitGatewayServices(runtimeSession: runtimeSession)
        await api.setChatGatewayServices(gateway)
        await api.setModelProvider(modelProvider)
        await api.setConversationEventsWireResources(hub: conversationHub, replayRetention: replayRetention)
        try await startWebSocketTestServer(api)
        let port = await api.listeningPort
        do {
            try await body(port, gateway.conversation, conversationHub)
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
        } catch {
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
            throw error
        }
    }

    private func withRunningWebSocketServerConversationEvents(
        models: [Model],
        runtimeSession: HarnessRuntimeSession,
        _ body: (Int, any APILayerConversationManaging, ConversationEventsTopicHub) async throws -> Void
    ) async throws {
        let api = APILayer(port: 0)
        let modelProvider = WebSocketStubModelProvider(models: models)
        let conversationHub = ConversationEventsTopicHub()
        await runtimeSession.setConversationTopicPublisher(ConversationEventsHubOnlyPublisher(hub: conversationHub))
        let gateway = await splitGatewayServices(runtimeSession: runtimeSession)
        await api.setChatGatewayServices(gateway)
        await api.setModelProvider(modelProvider)
        await api.setConversationEventsWireResources(hub: conversationHub)
        try await startWebSocketTestServer(api)
        let port = await api.listeningPort
        do {
            try await body(port, gateway.conversation, conversationHub)
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
        } catch {
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
            throw error
        }
    }

    /// Starts `/ws` with both model pool wire and conversation events (multiplexed subscribe coverage).
    private func withRunningWebSocketServerModelStateAndConversationEvents(
        models: [Model],
        _ body: (Int, any APILayerConversationManaging, ModelInvocationCoordinator, ConversationEventsTopicHub, ConversationStateTopicHub, CapabilityRegistryTopicHub) async throws -> Void
    ) async throws {
        let api = APILayer(port: 0)
        let container = try APILayerWebSocketTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: WebSocketCoverageHarnessSupport.sharedHarness(for: container))
        let modelProvider = WebSocketStubModelProvider(models: models)
        let hub = ModelStateTopicHub()
        let conversationHub = ConversationEventsTopicHub()
        let conversationStateHub = ConversationStateTopicHub()
        let traceTopicHub = TraceTopicHub()
        let subAgentLifecycleHub = SubAgentLifecycleTopicHub()
        let capabilityRegistryHub = CapabilityRegistryTopicHub()
        let conversationsRegistryHub = ConversationsRegistryTopicHub()
        let communicationLayer = CommunicationLayer(
            modelPoolTopics: hub,
            conversationEvents: conversationHub,
            conversationState: conversationStateHub,
            traceTopics: traceTopicHub,
            subAgentLifecycle: subAgentLifecycleHub,
            capabilityRegistries: capabilityRegistryHub,
            conversationsRegistry: conversationsRegistryHub
        )
        let resourceTopics: any ModelPoolResourceTopicPublishing = communicationLayer
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await resourceTopics.broadcast(modelID: modelID, payload: payload)
        }
        let gateway = await splitGatewayServices(runtimeSession: runtimeSession)
        await api.setChatGatewayServices(gateway)
        await api.setModelProvider(modelProvider)
        await api.setCommunicationWireResources(layer: communicationLayer, coordinator: coordinator)
        try await startWebSocketTestServer(api)
        let port = await api.listeningPort
        do {
            try await body(port, gateway.conversation, coordinator, conversationHub, conversationStateHub, capabilityRegistryHub)
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
        } catch {
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
            throw error
        }
    }

    private func withRunningWebSocketServerModelStateAndConversationEvents(
        models: [Model],
        runtimeSession: HarnessRuntimeSession,
        _ body: (Int, any APILayerConversationManaging, ModelInvocationCoordinator, ConversationEventsTopicHub, ConversationStateTopicHub, CapabilityRegistryTopicHub) async throws -> Void
    ) async throws {
        let api = APILayer(port: 0)
        let modelProvider = WebSocketStubModelProvider(models: models)
        let hub = ModelStateTopicHub()
        let conversationHub = ConversationEventsTopicHub()
        let conversationStateHub = ConversationStateTopicHub()
        let traceTopicHub = TraceTopicHub()
        let subAgentLifecycleHub = SubAgentLifecycleTopicHub()
        let capabilityRegistryHub = CapabilityRegistryTopicHub()
        let conversationsRegistryHub = ConversationsRegistryTopicHub()
        let communicationLayer = CommunicationLayer(
            modelPoolTopics: hub,
            conversationEvents: conversationHub,
            conversationState: conversationStateHub,
            traceTopics: traceTopicHub,
            subAgentLifecycle: subAgentLifecycleHub,
            capabilityRegistries: capabilityRegistryHub,
            conversationsRegistry: conversationsRegistryHub
        )
        let resourceTopics: any ModelPoolResourceTopicPublishing = communicationLayer
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await resourceTopics.broadcast(modelID: modelID, payload: payload)
        }
        let gateway = await splitGatewayServices(runtimeSession: runtimeSession)
        await api.setChatGatewayServices(gateway)
        await api.setModelProvider(modelProvider)
        await api.setCommunicationWireResources(layer: communicationLayer, coordinator: coordinator)
        try await startWebSocketTestServer(api)
        let port = await api.listeningPort
        do {
            try await body(port, gateway.conversation, coordinator, conversationHub, conversationStateHub, capabilityRegistryHub)
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
        } catch {
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
            throw error
        }
    }

    /// Starts `/ws` with ``APILayer/setModelStateWireResources`` wired for `model/{id}/state` tests.
    private func withRunningWebSocketServerAndModelState(
        models: [Model],
        _ body: (Int, ModelInvocationCoordinator) async throws -> Void
    ) async throws {
        try await withRunningWebSocketServerAndModelState(models: models) { port, coordinator, _ in
            try await body(port, coordinator)
        }
    }

    /// Variant that also exposes the ``ModelStateTopicHub`` for tests that need to seed the registry snapshot.
    private func withRunningWebSocketServerAndModelState(
        models: [Model],
        _ body: (Int, ModelInvocationCoordinator, ModelStateTopicHub) async throws -> Void
    ) async throws {
        let api = APILayer(port: 0)
        let container = try APILayerWebSocketTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: WebSocketCoverageHarnessSupport.sharedHarness(for: container))
        let modelProvider = WebSocketStubModelProvider(models: models)
        let hub = ModelStateTopicHub()
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await hub.broadcast(modelID: modelID, payload: payload)
        }
        await api.setChatGatewayServices(await splitGatewayServices(runtimeSession: runtimeSession))
        await api.setModelProvider(modelProvider)
        await api.setModelStateWireResources(hub: hub, coordinator: coordinator)
        try await startWebSocketTestServer(api)
        let port = await api.listeningPort
        do {
            try await body(port, coordinator, hub)
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
        } catch {
            await stopWebSocketTestServer(api: api, runtimeSession: runtimeSession)
            throw error
        }
    }

    @Test("WS pool health subscribe sends snapshot")
    func websocketPoolHealthSubscribeSnapshot() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerAndModelState(models: [model]) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": ResourceTopicName.poolHealth])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == ResourceTopicName.poolHealth)
            #expect(snap["seq"] as? Int == 1)
            let value = snap["value"] as? [String: Any]
            #expect(value?["queueDepth"] as? Int == 0)
            #expect(value?["inFlight"] as? Int == 0)
            #expect(value?["maxConcurrent"] as? Int == 8)
        }
    }

    @Test("WS models registry subscribe sends snapshot")
    func websocketModelsRegistrySubscribeSnapshot() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerAndModelState(models: [model]) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": ResourceTopicName.modelsRegistry])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == ResourceTopicName.modelsRegistry)
            let value = snap["value"] as? [String: Any]
            let models = value?["models"] as? [Any]
            #expect(models?.isEmpty == true)
        }
    }

    @Test("WS harness control frame rejects unknown keys")
    func websocketHarnessControlRejectsUnknownKeys() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerAndModelState(models: [model]) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": ResourceTopicName.poolHealth, "extra": 1])
            let err = try await receiveJSON(ofType: "error", from: task)
            #expect((err["message"] as? String)?.contains("unexpected") == true)
        }
    }

    @Test("WS conversation events subscribe sends snapshot envelope")
    func websocketConversationEventsSubscribeSnapshot() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerConversationEvents(models: [model]) { port, runtimeSession, _ in
            let conversationAPI = runtimeSession
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-conv-events"
            )
            let topic = ConversationTopicFormat.topic(conversationID: cid)
            let transcriptHead = await conversationAPI.apiLatestTranscriptSequence(conversationID: cid) ?? 0

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == topic)
            #expect((snap["seq"] as? Int) == transcriptHead)
            #expect(snap["kind"] as? String == "snapshot")
            let value = snap["value"] as? [String: Any]
            #expect(value?["semanticKind"] as? String == "messagesRefresh")
        }
    }

    @Test("WS conversation events receives hub broadcast after subscribe")
    func websocketConversationEventsSubscribeThenExternalBroadcast() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerConversationEvents(models: [model]) { port, runtimeSession, conversationHub in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-broadcast"
            )
            let topic = ConversationTopicFormat.topic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            let snapSeq = snap["seq"] as? Int

            await conversationHub.broadcast(
                conversationID: cid,
                payload: ConversationTopicWireEncoding.contentDeltaTextFragmentPayload(text: "hello-topic")
            )
            let evt = try await receiveJSON(kind: "event", from: task)
            // Transient `contentDelta` now carries envelope-level seq plus run correlation metadata.
            #expect((evt["seq"] as? Int) == ((snapSeq ?? 0) + 1))
            #expect(evt["turnOrdinal"] as? Int == 1)
            #expect(evt["runId"] != nil)
            #expect(evt["topic"] as? String == topic)
            let value = evt["value"] as? [String: Any]
            #expect(value?["semanticKind"] as? String == "contentDelta")
            let jsonUTF8 = try #require(value?["jsonUTF8"] as? String)
            let deltaData = try #require(jsonUTF8.data(using: .utf8))
            let delta = try JSONDecoder().decode(ModelContentDeltaWire.self, from: deltaData)
            #expect(delta.kind == .text)
            #expect(delta.text == "hello-topic")
        }
    }

    @Test("WS conversation events publish tool call id after REST send")
    func websocketConversationEventsToolRoundTripRows() async throws {
        let model = Model(
            protocol: .openAIAPI,
            modelName: "ws-tool-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
        let llm = WebSocketScriptedToolThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_ws_tool_roundtrip_1",
            finalAssistantText: "WS tool complete."
        )
        let runtimeSession = HarnessRuntimeSession(
            container: try APILayerWebSocketTestSupport.makeContainer(),
            llmFactory: WebSocketScriptedLLMFactory(llm: llm)
        )
        try await withRunningWebSocketServerConversationEvents(models: [model], runtimeSession: runtimeSession) { port, conversationAPI, _ in
            let cid = try await createConversationID(
                conversationAPI: conversationAPI,
                model: model,
                prompt: "ws-tool-roundtrip"
            )
            let topic = ConversationTopicFormat.topic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            _ = try await receiveJSON(kind: "snapshot", from: task)

            let sendURL = URL(string: "http://127.0.0.1:\(port)/api/conversations/\(cid.uuidString)/messages")!
            func sendMessage(ifMatch: String) async throws -> (Data, HTTPURLResponse) {
                var request = URLRequest(url: sendURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
                request.httpBody = Data(#"{"message":"run tool over ws","imageNames":[]}"#.utf8)
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = try #require(response as? HTTPURLResponse)
                return (data, http)
            }

            let (firstData, firstHTTP) = try await sendMessage(ifMatch: "\"msg-none\"")
            if firstHTTP.statusCode == 412 {
                let firstJSON = try JSONSerialization.jsonObject(with: firstData) as? [String: Any]
                let currentVersion = try #require(firstJSON?["currentVersion"] as? String)
                let (_, retryHTTP) = try await sendMessage(ifMatch: "\"\(currentVersion)\"")
                #expect(retryHTTP.statusCode == 201)
            } else {
                #expect(firstHTTP.statusCode == 201)
            }

            var sawToolAndAssistant = false
            var sawToolCallID = false
            for _ in 0..<40 where !(sawToolAndAssistant && sawToolCallID) {
                let payload = try await receiveJSON(task)
                guard payload["kind"] as? String == "event" else { continue }
                guard payload["topic"] as? String == topic else { continue }
                guard let value = payload["value"] as? [String: Any] else { continue }
                guard value["semanticKind"] as? String == "messagesRefresh" else { continue }
                guard let jsonUTF8 = value["jsonUTF8"] as? String,
                      let data = jsonUTF8.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data)
                else {
                    continue
                }
                let rows: [[String: Any]]
                if let direct = root as? [[String: Any]] {
                    rows = direct
                } else if let wrapped = root as? [String: Any],
                          let messages = wrapped["messages"] as? [[String: Any]] {
                    rows = messages
                } else {
                    continue
                }
                let roles = rows.compactMap { $0["role"] as? String }
                let toolCallIDs = rows.compactMap { row -> String? in
                    if let id = row["toolCallId"] as? String { return id }
                    if let id = row["toolCallID"] as? String { return id }
                    return nil
                }
                sawToolAndAssistant = roles.contains("tool") && roles.contains("assistant")
                sawToolCallID = toolCallIDs.contains("call_ws_tool_roundtrip_1")
            }
            #expect(sawToolAndAssistant)
            #expect(sawToolCallID)
        }
    }

    @Test("WS conversation events include tool error row after REST send")
    func websocketConversationEventsToolErrorRows() async throws {
        let model = Model(
            protocol: .openAIAPI,
            modelName: "ws-tool-error-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
        let llm = WebSocketScriptedToolErrorThenAnswerLLM()
        let runtimeSession = HarnessRuntimeSession(
            container: try APILayerWebSocketTestSupport.makeContainer(),
            llmFactory: WebSocketScriptedLLMFactory(llm: llm)
        )
        try await withRunningWebSocketServerConversationEvents(models: [model], runtimeSession: runtimeSession) { port, conversationAPI, _ in
            let cid = try await createConversationID(
                conversationAPI: conversationAPI,
                model: model,
                prompt: "ws-tool-error"
            )
            let topic = ConversationTopicFormat.topic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            _ = try await receiveJSON(kind: "snapshot", from: task)

            let sendURL = URL(string: "http://127.0.0.1:\(port)/api/conversations/\(cid.uuidString)/messages")!
            func sendMessage(ifMatch: String) async throws -> (Data, HTTPURLResponse) {
                var request = URLRequest(url: sendURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
                request.httpBody = Data(#"{"message":"trigger tool error","imageNames":[]}"#.utf8)
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = try #require(response as? HTTPURLResponse)
                return (data, http)
            }

            let (firstData, firstHTTP) = try await sendMessage(ifMatch: "\"msg-none\"")
            if firstHTTP.statusCode == 412 {
                let firstJSON = try JSONSerialization.jsonObject(with: firstData) as? [String: Any]
                let currentVersion = try #require(firstJSON?["currentVersion"] as? String)
                let (_, retryHTTP) = try await sendMessage(ifMatch: "\"\(currentVersion)\"")
                #expect(retryHTTP.statusCode == 201)
            } else {
                #expect(firstHTTP.statusCode == 201)
            }

            var sawToolRole = false
            var sawAssistantRole = false
            var sawToolCallID = false
            var sawTerminalLifecycle = false
            for _ in 0..<140 where !(sawToolRole && sawAssistantRole && sawToolCallID && sawTerminalLifecycle) {
                guard let payload = try await receiveJSONIfAvailable(task, timeoutNanos: 150_000_000) else { continue }
                guard payload["kind"] as? String == "event" else { continue }
                guard payload["topic"] as? String == topic else { continue }
                guard let value = payload["value"] as? [String: Any] else { continue }
                let semanticKind = value["semanticKind"] as? String
                if semanticKind == "runtimeLifecycle" {
                    guard let jsonUTF8 = value["jsonUTF8"] as? String,
                          let data = jsonUTF8.data(using: .utf8),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    let name = root["name"] as? String
                    if name == RuntimeLifecycleEventName.turnCompleted.rawValue
                        || name == RuntimeLifecycleEventName.turnCancelled.rawValue
                        || name == RuntimeLifecycleEventName.turnBounded.rawValue {
                        sawTerminalLifecycle = true
                    }
                }
                guard semanticKind == "messagesRefresh" else { continue }
                guard let jsonUTF8 = value["jsonUTF8"] as? String,
                      let data = jsonUTF8.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                let rows: [[String: Any]] = {
                    if let direct = root as? [[String: Any]] { return direct }
                    if let wrapped = root as? [String: Any], let messages = wrapped["messages"] as? [[String: Any]] {
                        return messages
                    }
                    return []
                }()
                guard !rows.isEmpty else { continue }
                let roles = rows.compactMap { $0["role"] as? String }
                let toolCallIDs = rows.compactMap { row -> String? in
                    (row["toolCallId"] as? String) ?? (row["toolCallID"] as? String)
                }
                sawToolRole = roles.contains("tool")
                sawAssistantRole = roles.contains("assistant")
                sawToolCallID = toolCallIDs.contains("call_ws_tool_error_1")
            }
            #expect(sawToolRole)
            #expect(sawAssistantRole)
            #expect(sawToolCallID)
            #expect(sawTerminalLifecycle)
        }
    }

    @Test("WS run cancellation suppresses slow final assistant on conversation events")
    func websocketConversationEventsRunCancellationLifecycle() async throws {
        let model = Model(
            protocol: .openAIAPI,
            modelName: "ws-tool-cancel-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
        let llm = WebSocketSlowToolThenAnswerLLM()
        let runtimeSession = HarnessRuntimeSession(
            container: try APILayerWebSocketTestSupport.makeContainer(),
            llmFactory: WebSocketScriptedLLMFactory(llm: llm)
        )
        try await withRunningWebSocketServerConversationEvents(models: [model], runtimeSession: runtimeSession) { port, conversationAPI, _ in
            let cid = try await createConversationID(
                conversationAPI: conversationAPI,
                model: model,
                prompt: "ws-tool-cancel"
            )
            let topic = ConversationTopicFormat.topic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            _ = try await receiveJSON(kind: "snapshot", from: task)

            let sendURL = URL(string: "http://127.0.0.1:\(port)/api/conversations/\(cid.uuidString)/messages")!
            func sendMessage(ifMatch: String) async throws -> (Data, HTTPURLResponse) {
                var request = URLRequest(url: sendURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
                request.httpBody = Data(#"{"message":"start cancel flow","imageNames":[]}"#.utf8)
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = try #require(response as? HTTPURLResponse)
                return (data, http)
            }

            let (firstData, firstHTTP) = try await sendMessage(ifMatch: "\"msg-none\"")
            let acceptedData: Data
            if firstHTTP.statusCode == 412 {
                let firstJSON = try JSONSerialization.jsonObject(with: firstData) as? [String: Any]
                let currentVersion = try #require(firstJSON?["currentVersion"] as? String)
                let (retryData, retryHTTP) = try await sendMessage(ifMatch: "\"\(currentVersion)\"")
                #expect(retryHTTP.statusCode == 201)
                acceptedData = retryData
            } else {
                #expect(firstHTTP.statusCode == 201)
                acceptedData = firstData
            }
            let acceptedJSON = try JSONSerialization.jsonObject(with: acceptedData) as? [String: Any]
            let runIDRaw = try #require(acceptedJSON?["runId"] as? String)
            let runID = try #require(UUID(uuidString: runIDRaw))

            let cancelURL = URL(
                string: "http://127.0.0.1:\(port)/api/conversations/\(cid.uuidString)/runs/\(runID.uuidString)/cancel"
            )!
            var cancelRequest = URLRequest(url: cancelURL)
            cancelRequest.httpMethod = "POST"
            cancelRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            cancelRequest.httpBody = Data("{}".utf8)
            let (_, cancelResponse) = try await URLSession.shared.data(for: cancelRequest)
            let cancelHTTP = try #require(cancelResponse as? HTTPURLResponse)
            #expect(cancelHTTP.statusCode == 200 || cancelHTTP.statusCode == 409)

            let verifyTask = try makeWebSocketTask(port: port)
            defer { verifyTask.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(verifyTask)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(verifyTask, ["kind": "subscribe", "topic": topic])

            var sawMessagesRefresh = false
            var sawFinalAssistantText = false
            for _ in 0..<120 where !sawFinalAssistantText {
                guard let payload = try await receiveJSONIfAvailable(verifyTask, timeoutNanos: 150_000_000) else { continue }
                let kind = payload["kind"] as? String
                guard kind == "event" || kind == "snapshot" else { continue }
                guard let value = payload["value"] as? [String: Any] else { continue }
                guard value["semanticKind"] as? String == "messagesRefresh" else { continue }
                guard let jsonUTF8 = value["jsonUTF8"] as? String,
                      let data = jsonUTF8.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data)
                else {
                    continue
                }
                let rows: [[String: Any]] = {
                    if let direct = root as? [[String: Any]] { return direct }
                    if let wrapped = root as? [String: Any], let messages = wrapped["messages"] as? [[String: Any]] {
                        return messages
                    }
                    return []
                }()
                guard !rows.isEmpty else { continue }
                sawMessagesRefresh = true
                let assistantContents = rows.compactMap { row -> String? in
                    guard (row["role"] as? String) == "assistant" else { return nil }
                    return row["content"] as? String
                }
                sawFinalAssistantText = assistantContents.contains("This should be cancelled.")
            }
            #expect(sawMessagesRefresh || cancelHTTP.statusCode == 409)
            if cancelHTTP.statusCode == 200 {
                #expect(sawFinalAssistantText == false)
            }
        }
    }

    @Test("WS tool timeout still publishes tool row and terminal lifecycle")
    func websocketConversationEventsToolTimeoutPublishesTerminalLifecycle() async throws {
        let model = Model(
            protocol: .openAIAPI,
            modelName: "ws-tool-timeout-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
        let llm = WebSocketToolThenTimeoutLLM()
        let runtimeSession = HarnessRuntimeSession(
            container: try APILayerWebSocketTestSupport.makeContainer(),
            llmFactory: WebSocketScriptedLLMFactory(llm: llm)
        )
        try await withRunningWebSocketServerConversationEvents(models: [model], runtimeSession: runtimeSession) { port, conversationAPI, _ in
            let cid = try await createConversationID(
                conversationAPI: conversationAPI,
                model: model,
                prompt: "ws-tool-timeout"
            )
            let topic = ConversationTopicFormat.topic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            _ = try await receiveJSON(kind: "snapshot", from: task)

            let sendURL = URL(string: "http://127.0.0.1:\(port)/api/conversations/\(cid.uuidString)/messages")!
            func sendMessage(ifMatch: String) async throws -> (Data, HTTPURLResponse) {
                var request = URLRequest(url: sendURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
                request.httpBody = Data(#"{"message":"trigger timeout path","imageNames":[]}"#.utf8)
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = try #require(response as? HTTPURLResponse)
                return (data, http)
            }

            let (firstData, firstHTTP) = try await sendMessage(ifMatch: "\"msg-none\"")
            if firstHTTP.statusCode == 412 {
                let firstJSON = try JSONSerialization.jsonObject(with: firstData) as? [String: Any]
                let currentVersion = try #require(firstJSON?["currentVersion"] as? String)
                let (_, retryHTTP) = try await sendMessage(ifMatch: "\"\(currentVersion)\"")
                #expect(retryHTTP.statusCode == 201)
            } else {
                #expect(firstHTTP.statusCode == 201)
            }

            var sawToolRole = false
            var sawToolCallID = false
            var sawTerminalLifecycle = false
            for _ in 0..<160 where !(sawToolRole && sawToolCallID && sawTerminalLifecycle) {
                guard let payload = try await receiveJSONIfAvailable(task, timeoutNanos: 150_000_000) else { continue }
                guard payload["kind"] as? String == "event" else { continue }
                guard payload["topic"] as? String == topic else { continue }
                guard let value = payload["value"] as? [String: Any] else { continue }
                let semanticKind = value["semanticKind"] as? String
                if semanticKind == "runtimeLifecycle" {
                    guard let jsonUTF8 = value["jsonUTF8"] as? String,
                          let data = jsonUTF8.data(using: .utf8),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    let name = root["name"] as? String
                    if name == RuntimeLifecycleEventName.turnCompleted.rawValue
                        || name == RuntimeLifecycleEventName.turnCancelled.rawValue
                        || name == RuntimeLifecycleEventName.turnBounded.rawValue {
                        sawTerminalLifecycle = true
                    }
                    continue
                }
                guard semanticKind == "messagesRefresh" else { continue }
                guard let jsonUTF8 = value["jsonUTF8"] as? String,
                      let data = jsonUTF8.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                let rows: [[String: Any]] = {
                    if let direct = root as? [[String: Any]] { return direct }
                    if let wrapped = root as? [String: Any], let messages = wrapped["messages"] as? [[String: Any]] {
                        return messages
                    }
                    return []
                }()
                guard !rows.isEmpty else { continue }
                let roles = rows.compactMap { $0["role"] as? String }
                let toolCallIDs = rows.compactMap { row -> String? in
                    (row["toolCallId"] as? String) ?? (row["toolCallID"] as? String)
                }
                sawToolRole = roles.contains("tool")
                sawToolCallID = toolCallIDs.contains("call_ws_timeout_tool_1")
            }
            #expect(sawToolRole)
            #expect(sawToolCallID)
            #expect(sawTerminalLifecycle)
        }
    }

    @Test("WS conversation events subscribe enforces replay retention window")
    func websocketConversationEventsSubscribeRejectsTooOldCursorByRetention() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerConversationEvents(
            models: [model],
            replayRetention: TranscriptTailRetentionPolicy(maxSequenceLag: 0)
        ) { port, runtimeSession, _ in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-retention"
            )
            let topic = ConversationTopicFormat.topic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic, "since": -1])
            let error = try await receiveJSON(ofType: "error", from: task)
            try assertErrorEnvelope(error, contains: "Subscribe failed")
        }
    }

    @Test("WS can subscribe to pool health and conversation events on one connection")
    func websocketMultiplexedPoolHealthAndConversationEvents() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, conversationHub, _, _ in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "mux"
            )
            let convTopic = ConversationTopicFormat.topic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)

            try await sendJSON(task, ["kind": "subscribe", "topic": ResourceTopicName.poolHealth])
            let poolSnap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(poolSnap["topic"] as? String == ResourceTopicName.poolHealth)

            try await sendJSON(task, ["kind": "subscribe", "topic": convTopic])
            let convSnap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(convSnap["topic"] as? String == convTopic)

            await conversationHub.broadcast(
                conversationID: cid,
                payload: ConversationTopicEventPayload.streamDone
            )
            let evt = try await receiveJSON(kind: "event", from: task)
            #expect(evt["topic"] as? String == convTopic)
            let value = evt["value"] as? [String: Any]
            #expect(value?["semanticKind"] as? String == "streamDone")
        }
    }

    @Test("WS conversation state subscribe sends snapshot envelope")
    func websocketConversationStateSubscribeSnapshot() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, _, _, _ in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-conv-state"
            )
            let topic = ConversationTopicFormat.stateTopic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == topic)
            #expect(snap["seq"] as? Int == 1)
            #expect(snap["kind"] as? String == "snapshot")
            let value = snap["value"] as? [String: Any]
            #expect(value?["exists"] as? Bool == true)
            #expect(value?["sessionSelected"] as? Bool == false)
            #expect(value?["schemaVersion"] as? Int == ConversationStatePayload.schemaVersionV2)
        }
    }

    @Test("WS tools registry subscribe sends snapshot")
    func websocketToolsRegistrySubscribeSnapshot() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, _, _, _ in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-tools-reg"
            )
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, [
                "kind": "subscribe",
                "topic": ResourceTopicName.toolsRegistry,
                "conversationId": cid.uuidString,
            ])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == ResourceTopicName.toolsRegistry)
            #expect(snap["seq"] as? Int == 1)
            let value = snap["value"] as? [String: Any]
            #expect(value?["schemaVersion"] as? Int == ToolsRegistryPayload.schemaVersionV1)
            #expect(value?["tools"] is [Any])
        }
    }

    @Test("WS tools registry receives broadcast after subscribe")
    func websocketToolsRegistrySubscribeThenBroadcast() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, _, _, capHub in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-tools-broadcast"
            )
            let conv = ConversationSessionService(backend: runtimeSession)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, [
                "kind": "subscribe",
                "topic": ResourceTopicName.toolsRegistry,
                "conversationId": cid.uuidString,
            ])
            _ = try await receiveJSON(kind: "snapshot", from: task)

            let payload = await CapabilityRegistrySnapshotBuilder.buildTools(conversation: conv, conversationID: cid)
            await capHub.broadcastToolsRegistry(payload)

            let evt = try await receiveJSON(kind: "event", from: task)
            #expect(evt["seq"] as? Int == 2)
            #expect(evt["topic"] as? String == ResourceTopicName.toolsRegistry)
            let value = evt["value"] as? [String: Any]
            #expect(value?["schemaVersion"] as? Int == ToolsRegistryPayload.schemaVersionV1)
        }
    }

    @Test("WS skills registry subscribe sends snapshot")
    func websocketSkillsRegistrySubscribeSnapshot() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, _, _, _ in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-skills-reg"
            )
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, [
                "kind": "subscribe",
                "topic": ResourceTopicName.skillsRegistry,
                "conversationId": cid.uuidString,
            ])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == ResourceTopicName.skillsRegistry)
            #expect(snap["seq"] as? Int == 1)
            let value = snap["value"] as? [String: Any]
            #expect(value?["schemaVersion"] as? Int == SkillsRegistryPayload.schemaVersionV1)
            #expect(value?["skills"] is [Any])
        }
    }

    @Test("WS sub-agents registry subscribe sends schema v2 snapshot")
    func websocketSubAgentsRegistrySubscribeSnapshot() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, _, _, _ in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-subagents-reg"
            )
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, [
                "kind": "subscribe",
                "topic": ResourceTopicName.subAgentsRegistry,
                "conversationId": cid.uuidString,
            ])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == ResourceTopicName.subAgentsRegistry)
            #expect(snap["seq"] as? Int == 1)
            let value = snap["value"] as? [String: Any]
            #expect(value?["schemaVersion"] as? Int == SubAgentsRegistryPayload.schemaVersionV2)
            #expect(value?["agents"] is [Any])
            #expect(value?["entries"] is [Any])
        }
    }

    @Test("WS orchestration out-of-band updates do not fan out skills registry events")
    func websocketOrchestrationOutOfBandDoesNotRefreshSkillsRegistry() async throws {
        let model = Model(
            protocol: .openAIAPI,
            modelName: "ws-oob-registry-loop-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let llm = WebSocketStreamingChunksLLM()
        let runtimeSession = HarnessRuntimeSession(
            container: try APILayerWebSocketTestSupport.makeContainer(),
            llmFactory: WebSocketScriptedLLMFactory(llm: llm)
        )
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model], runtimeSession: runtimeSession) { port, conversationAPI, _, _, _, _ in
            let cid = try await createConversationID(
                conversationAPI: conversationAPI,
                model: model,
                prompt: "ws-oob-skills-reg"
            )
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, [
                "kind": "subscribe",
                "topic": ResourceTopicName.skillsRegistry,
                "conversationId": cid.uuidString,
            ])
            _ = try await receiveJSON(kind: "snapshot", from: task)

            let sendURL = URL(string: "http://127.0.0.1:\(port)/api/conversations/\(cid.uuidString)/messages")!
            func sendMessage(ifMatch: String) async throws -> (Data, HTTPURLResponse) {
                var request = URLRequest(url: sendURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
                request.httpBody = Data(#"{"message":"drive streamed oob orchestration","imageNames":[]}"#.utf8)
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = try #require(response as? HTTPURLResponse)
                return (data, http)
            }

            let (firstData, firstHTTP) = try await sendMessage(ifMatch: "\"msg-none\"")
            if firstHTTP.statusCode == 412 {
                let firstJSON = try JSONSerialization.jsonObject(with: firstData) as? [String: Any]
                let currentVersion = try #require(firstJSON?["currentVersion"] as? String)
                let (_, retryHTTP) = try await sendMessage(ifMatch: "\"\(currentVersion)\"")
                #expect(retryHTTP.statusCode == 201)
            } else {
                #expect(firstHTTP.statusCode == 201)
            }

            var sawSkillsRegistryEvent = false
            for _ in 0..<60 {
                guard let payload = try await receiveJSONIfAvailable(task, timeoutNanos: 100_000_000) else { continue }
                guard payload["kind"] as? String == "event" else { continue }
                if payload["topic"] as? String == ResourceTopicName.skillsRegistry {
                    sawSkillsRegistryEvent = true
                    break
                }
            }

            #expect(sawSkillsRegistryEvent == false)
        }
    }

    @Test("WS sub-agent lifecycle topic subscribe sends snapshot")
    func websocketSubAgentLifecycleSubscribeSnapshot() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, _, _, _ in
            let parentConversationID = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-subagent-lifecycle"
            )
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            let topic = SubAgentTopicFormat.eventsTopic(
                conversationID: parentConversationID,
                pathSegments: ["agent-0"]
            )
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == topic)
            #expect(snap["seq"] as? Int == 1)
            let value = snap["value"] as? [String: Any]
            #expect(value?["schemaVersion"] as? Int == SubAgentLifecycleTopicPayload.schemaVersionV1)
            #expect((value?["parentConversationID"] as? String)?.lowercased() == parentConversationID.uuidString.lowercased())
            #expect(value?["entries"] is [Any])
        }
    }

    @Test("WS trace/server topic subscribe sends snapshot")
    func websocketTraceServerSubscribeSnapshot() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, _, _, _, _, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": TraceTopicFormat.serverTopic])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == TraceTopicFormat.serverTopic)
            #expect(snap["seq"] as? Int == 1)
            let value = snap["value"] as? [String: Any]
            #expect(value?["schemaVersion"] as? Int == TraceTopicPayload.schemaVersionV1)
            #expect(value?["spans"] is [Any])
        }
    }

    @Test("WS conversations registry subscribe receives snapshot and create event")
    func websocketConversationsRegistrySubscribeAndCreateEvent() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, _, _, _, _, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)

            try await sendJSON(task, ["kind": "subscribe", "topic": ResourceTopicName.conversationsRegistry])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == ResourceTopicName.conversationsRegistry)
            let snapValue = snap["value"] as? [String: Any]
            #expect(snapValue?["schemaVersion"] as? Int == ConversationsRegistryPayload.schemaVersionV1)

            _ = try await postRESTJSON(
                path: "/api/conversations",
                port: port,
                payload: [
                    "modelRef": model.id.uuidString,
                    "userSystemPrompt": "prompt",
                ]
            )
            let evt = try await receiveJSON(kind: "event", from: task)
            #expect(evt["topic"] as? String == ResourceTopicName.conversationsRegistry)
            let value = evt["value"] as? [String: Any]
            let changes = value?["changes"] as? [[String: Any]]
            #expect(changes?.first?["kind"] as? String == "added")
        }
    }

    @Test("WS conversations registry patch interactionMode-only carries catalog metadata")
    func websocketConversationsRegistryPatchIncludesInteractionModeMetadata() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, _, _, _ in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "registry-mode-meta"
            )

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)

            try await sendJSON(task, ["kind": "subscribe", "topic": ResourceTopicName.conversationsRegistry])
            _ = try await receiveJSON(kind: "snapshot", from: task)
            _ = try await patchRESTJSON(
                path: "/api/conversations/\(cid.uuidString)",
                port: port,
                payload: [
                    "interactionMode": InteractionMode.agent.rawValue,
                    "expectedRevision": 1,
                ]
            )
            try await Task.sleep(nanoseconds: 150_000_000)

            let evt = try await receiveJSON(kind: "event", from: task)
            #expect(evt["topic"] as? String == ResourceTopicName.conversationsRegistry)
            let value = evt["value"] as? [String: Any]
            let changes = value?["changes"] as? [[String: Any]]
            let meta = changes?.first?["metadata"] as? [String: Any]
            #expect(meta?["interactionMode"] as? String == InteractionMode.agent.rawValue)
            let metaID = meta?["id"] as? String
            #expect(metaID?.lowercased() == cid.uuidString.lowercased())
        }
    }

    @Test("REST modeProfileID-only patch fans out on state and registry topics")
    func websocketModeProfilePatchPublishesStateAndRegistryMetadata() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, _, _, _ in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "registry-profile-pointer"
            )
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)

            let registryTopic = ResourceTopicName.conversationsRegistry
            let stateTopic = ConversationTopicFormat.stateTopic(conversationID: cid)
            try await sendJSON(task, ["kind": "subscribe", "topic": registryTopic])
            _ = try await receiveJSON(kind: "snapshot", from: task)
            try await sendJSON(task, ["kind": "subscribe", "topic": stateTopic])
            _ = try await receiveJSON(kind: "snapshot", from: task)

            let revision = try #require(
                await runtimeSession.apiGetConversation(id: cid)?.controlPlaneRevision
            )
            _ = try await patchRESTJSON(
                path: "/api/conversations/\(cid.uuidString)",
                port: port,
                payload: [
                    "modeProfileID": "custom.profile.delta",
                    "expectedRevision": revision,
                ]
            )

            var registrySeen = false
            var stateSeen = false
            for _ in 0..<16 where !(registrySeen && stateSeen) {
                let evt = try await receiveJSON(kind: "event", from: task)
                guard let topic = evt["topic"] as? String else { continue }
                if topic == registryTopic {
                    let value = evt["value"] as? [String: Any]
                    let changes = value?["changes"] as? [[String: Any]]
                    let meta = changes?.first?["metadata"] as? [String: Any]
                    #expect(meta?["modeProfileID"] as? String == "custom.profile.delta")
                    registrySeen = true
                }
                if topic == stateTopic {
                    let value = evt["value"] as? [String: Any]
                    #expect(value?["modeProfileID"] as? String == "custom.profile.delta")
                    stateSeen = true
                }
            }
            #expect(registrySeen)
            #expect(stateSeen)
        }
    }

    @Test("WS conversation state receives broadcast after subscribe")
    func websocketConversationStateSubscribeThenBroadcast() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, runtimeSession, _, _, stateHub, _ in
            let cid = try await createConversationID(
                conversationAPI: runtimeSession,
                model: model,
                prompt: "ws-state-broadcast"
            )
            let topic = ConversationTopicFormat.stateTopic(conversationID: cid)

            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            _ = try await receiveJSON(kind: "snapshot", from: task)

            let orch = try #require(await runtimeSession.apiSnapshotOrchestrationState(conversationID: cid))
            await stateHub.broadcast(conversationID: cid, payload: ConversationStatePayload(
                conversationID: cid,
                exists: true,
                sessionSelected: false,
                orchestration: orch,
                replayActive: false
            ))
            let evt = try await receiveJSON(kind: "event", from: task)
            #expect(evt["seq"] as? Int == 2)
            #expect(evt["topic"] as? String == topic)
            let value = evt["value"] as? [String: Any]
            #expect(value?["exists"] as? Bool == true)
        }
    }

    @Test("WS model state subscribe sends snapshot then events")
    func websocketModelStateTopicSnapshotAndEvent() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerAndModelState(models: [model]) { port, coordinator in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            let topic = ModelStateTopicFormat.topic(modelID: model.id)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["seq"] as? Int == 1)

            let callID = await coordinator.beginCall(modelID: model.id)
            await coordinator.recordTransition(modelID: model.id, phase: .streaming, callID: callID)

            let evt = try await receiveJSON(kind: "event", from: task)
            #expect(evt["seq"] as? Int == 2)
            #expect(evt["topic"] as? String == topic)
        }
    }

    @Test("WS model state event path works through communication-layer facade wiring")
    func websocketModelStateTopicSnapshotAndEventWithCommunicationLayerWiring() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerModelStateAndConversationEvents(models: [model]) { port, _, coordinator, _, _, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            let topic = ModelStateTopicFormat.topic(modelID: model.id)
            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["seq"] as? Int == 1)

            let callID = await coordinator.beginCall(modelID: model.id)
            await coordinator.recordTransition(modelID: model.id, phase: .streaming, callID: callID)

            let evt = try await receiveJSON(kind: "event", from: task)
            #expect(evt["seq"] as? Int == 2)
            #expect(evt["topic"] as? String == topic)
        }
    }

    // Full end-to-end integration test: real URLSessionWebSocketTask, Vapor APILayer,
    // HarnessRuntimeSession, and splitGatewayServices. Can flake under parallel full-suite
    // runs (hang during server/session setup from shared ModelContainer / runtime contention).
    // Prefer ModelStateTopicHubTests and WebSocketTopicSubscriptionRouterTests for
    // deterministic replay semantics.
    // TODO: Move WebSocket integration tests into a dedicated test target
    // (e.g. SwiftAgentHarnessIntegrationTests) so CI can run unit vs integration separately.
    @Test("WS model state subscribe replays in-window since range", .timeLimit(.minutes(1)))
    func websocketModelStateReplayFromSinceRange() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerAndModelState(models: [model]) { port, coordinator in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            let topic = ModelStateTopicFormat.topic(modelID: model.id)

            try await sendJSON(task, ["kind": "subscribe", "topic": topic])
            _ = try await receiveJSON(kind: "snapshot", from: task)

            let callID = await coordinator.beginCall(modelID: model.id)
            await coordinator.recordTransition(modelID: model.id, phase: .streaming, callID: callID)
            let firstEvent = try await receiveJSON(kind: "event", from: task, maxMessages: 4)
            #expect(firstEvent["seq"] as? Int == 2)

            try await sendJSON(task, ["kind": "subscribe", "topic": topic, "since": 1])
            let replay = try await receiveNextMatching(
                from: task,
                where: { payload in
                    payload["kind"] as? String == "event" && payload["topic"] as? String == topic
                },
                maxMessages: 4
            )
            #expect(replay["seq"] as? Int == 2)

            let snap = try await receiveJSON(kind: "snapshot", from: task, maxMessages: 4)
            #expect(snap["topic"] as? String == topic)
            #expect(snap["seq"] as? Int == 3)
        }
    }

    private func receiveNextMatching(
        from task: URLSessionWebSocketTask,
        where predicate: ([String: Any]) -> Bool,
        maxMessages: Int = 8
    ) async throws -> [String: Any] {
        for _ in 0..<maxMessages {
            let payload = try await receiveJSON(task)
            if predicate(payload) {
                return payload
            }
            if payload["type"] as? String == "error" || payload["kind"] as? String == "error" {
                let message = (payload["message"] as? String) ?? "(no message)"
                throw NSError(
                    domain: "APILayerWebSocketCoverageTests",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected error envelope: \(message)"]
                )
            }
        }
        throw NSError(
            domain: "APILayerWebSocketCoverageTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Did not receive expected WebSocket payload"]
        )
    }

    // Shares the same heavy WebSocket server fixture as websocketModelStateReplayFromSinceRange;
    // see flake note there. Lagging fallback is covered by unit tests on ModelStateTopicHub
    // and WebSocketTopicSubscriptionRouter.
    @Test("WS model state subscribe falls back to lagging when since is invalid")
    func websocketModelStateSinceLagFallback() async throws {
        let model = APILayerWebSocketTestSupport.makeTestModel()
        try await withRunningWebSocketServerAndModelState(models: [model]) { port, _ in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await Task.sleep(nanoseconds: 150_000_000)
            let topic = ModelStateTopicFormat.topic(modelID: model.id)

            try await sendJSON(task, ["kind": "subscribe", "topic": topic, "since": 999])
            let lag = try await receiveJSON(kind: "lagging", from: task)
            #expect(lag["topic"] as? String == topic)
            #expect(lag["seq"] as? Int == 0)
            #expect(lag["hint"] as? String == "resync")

            let snap = try await receiveJSON(kind: "snapshot", from: task)
            #expect(snap["topic"] as? String == topic)
            #expect(snap["seq"] as? Int == 1)
        }
    }

    private func receiveJSON(kind: String, from task: URLSessionWebSocketTask, maxMessages: Int = 8) async throws -> [String: Any] {
        for _ in 0..<maxMessages {
            let payload = try await receiveJSON(task)
            if payload["kind"] as? String == kind {
                return payload
            }
            // Fail fast on server-side error envelopes — otherwise the loop just keeps
            // waiting for a snapshot/event frame that will never arrive (and the only
            // signal to the harness is the per-receive timeout in `receiveWebSocketMessage`).
            if payload["type"] as? String == "error" || payload["kind"] as? String == "error" {
                let message = (payload["message"] as? String) ?? "(no message)"
                throw NSError(
                    domain: "APILayerWebSocketCoverageTests",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Expected kind \(kind) but received error envelope: \(message)"]
                )
            }
        }
        throw NSError(
            domain: "APILayerWebSocketCoverageTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Did not receive kind \(kind)"]
        )
    }

    private func makeWebSocketTask(port: Int) throws -> URLSessionWebSocketTask {
        let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let task = APILayerWebSocketTestSupport.webSocketSession.webSocketTask(with: url)
        task.resume()
        return task
    }

    private func sendJSON(_ task: URLSessionWebSocketTask, _ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
    }

    private func receiveJSON(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await receiveWebSocketMessage(task, timeoutNanos: 1_000_000_000)
        switch message {
        case .string(let text):
            let data = Data(text.utf8)
            let object = try JSONSerialization.jsonObject(with: data)
            return (object as? [String: Any]) ?? [:]
        case .data(let data):
            let object = try JSONSerialization.jsonObject(with: data)
            return (object as? [String: Any]) ?? [:]
        @unknown default:
            return [:]
        }
    }

    private func receiveWebSocketMessage(
        _ task: URLSessionWebSocketTask,
        timeoutNanos: UInt64
    ) async throws -> URLSessionWebSocketTask.Message {
        let timeoutError = NSError(
            domain: "APILayerWebSocketCoverageTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for WebSocket frame"]
        )
        return try await withCheckedThrowingContinuation { continuation in
            final class ReceiveGate: @unchecked Sendable {
                private var resumed = false
                private let lock = NSLock()

                func resumeOnce(_ action: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard resumed == false else { return }
                    resumed = true
                    action()
                }
            }

            let gate = ReceiveGate()
            task.receive { result in
                gate.resumeOnce {
                    continuation.resume(with: result)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNanos))) {
                gate.resumeOnce {
                    continuation.resume(throwing: timeoutError)
                }
            }
        }
    }

    private func receiveJSONIfAvailable(_ task: URLSessionWebSocketTask, timeoutNanos: UInt64) async throws -> [String: Any]? {
        do {
            let message = try await receiveWebSocketMessage(task, timeoutNanos: timeoutNanos)
            switch message {
            case .string(let text):
                let data = Data(text.utf8)
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            case .data(let data):
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            @unknown default:
                return nil
            }
        } catch {
            let ns = error as NSError
            if ns.domain == "APILayerWebSocketCoverageTests", ns.code == 3 {
                return nil
            }
            throw error
        }
    }

    private func awaitWebSocketReady(_ task: URLSessionWebSocketTask) async throws {
        _ = task
        // URLSession WebSocket send can race server-side setup immediately after resume.
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    private func receiveJSON(ofType expectedType: String, from task: URLSessionWebSocketTask, maxMessages: Int = 8) async throws -> [String: Any] {
        for _ in 0..<maxMessages {
            let payload = try await receiveJSON(task)
            if payload["type"] as? String == expectedType {
                return payload
            }
            if expectedType == "error", payload["kind"] as? String == "error" {
                return payload
            }
        }
        throw NSError(domain: "APILayerWebSocketCoverageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Did not receive expected type \(expectedType)"])
    }

    private func assertErrorEnvelope(_ payload: [String: Any], contains messageSubstring: String) throws {
        #expect((payload["type"] as? String == "error") || (payload["kind"] as? String == "error"))
        #expect((payload["message"] as? String)?.contains(messageSubstring) == true)
        if payload["type"] as? String == "error" {
            #expect(Set(payload.keys) == ["type", "message"])
        } else {
            #expect(Set(payload.keys).isSuperset(of: ["kind", "message"]))
        }
    }

    private func receiveRESTJSON(path: String, port: Int) async throws -> [String: Any] {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postRESTJSON(path: String, port: Int, payload: [String: Any]) async throws -> [String: Any] {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func patchRESTJSON(path: String, port: Int, payload: [String: Any]) async throws -> [String: Any] {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-Match")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
