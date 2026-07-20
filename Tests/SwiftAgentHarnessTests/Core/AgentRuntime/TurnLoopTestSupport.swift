import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

actor TurnLoopConversationState {
    private var conversation: ModelConversation

    init(conversation: ModelConversation) {
        self.conversation = conversation
    }

    func snapshot() -> ModelConversation {
        conversation
    }

    func append(_ message: Message) {
        conversation.messages.append(message)
    }

    func swapModel(_ model: Model) {
        conversation.model = model
    }

    func setMetadata(_ metadata: JSON?) {
        conversation.metadata = metadata
    }

    func anchorUserMessageID() -> UUID? {
        conversation.messages.first(where: { $0.role == .user })?.id
    }
}

actor TurnLoopTranscriptRecorder {
    private var toolMessages: [Message] = []

    func recordTool(_ message: Message) {
        toolMessages.append(message)
    }

    func appendedToolMessages() -> [Message] {
        toolMessages
    }
}

actor TurnLoopCompactionRecorder {
    private var hints: [CompactionHint] = []

    func record(_ hint: CompactionHint) {
        hints.append(hint)
    }

    func recordedHints() -> [CompactionHint] {
        hints
    }
}

actor TurnLoopLifecycleRecorder {
    private var events: [RuntimeLifecycleEventName] = []
    private var payloads: [RuntimeLifecycleEventPayload] = []

    func record(name: RuntimeLifecycleEventName) {
        events.append(name)
    }

    func record(payload: RuntimeLifecycleEventPayload) {
        payloads.append(payload)
        events.append(payload.name)
    }

    func completedToolCallCount() -> Int {
        events.filter { $0 == .toolCallCompleted }.count
    }

    func failedToolCallCount() -> Int {
        events.filter { $0 == .toolCallFailed }.count
    }

    func startedToolCallCount() -> Int {
        events.filter { $0 == .toolCallStarted }.count
    }

    func eventOrder() -> [RuntimeLifecycleEventName] {
        events
    }

    func recordedPayloads() -> [RuntimeLifecycleEventPayload] {
        payloads
    }

    func everyStartedHasTerminalPair() -> Bool {
        var openStarts = 0
        for name in events {
            switch name {
            case .toolCallStarted:
                openStarts += 1
            case .toolCallCompleted, .toolCallFailed:
                guard openStarts > 0 else { return false }
                openStarts -= 1
            default:
                break
            }
        }
        return openStarts == 0
    }

    func startedBeforeCompleted() -> Bool {
        guard let startedIndex = events.firstIndex(of: .toolCallStarted),
              let completedIndex = events.firstIndex(of: .toolCallCompleted)
        else { return true }
        return startedIndex < completedIndex
    }
}

struct StubTurnLoopLLM: LLMProtocol {
    func getModelName() -> String { "stub" }
    func getCapabilities() -> [LLMCapability] { [.completion] }
    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        LLMResponse.llmResponse(from: "", availableTools: [])
    }
    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateImage(config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        ImageGenerationResponse(images: [])
    }
}

final class DispatchOutcomeQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [ToolDispatchOutcome]
    private var index = 0

    init(outcomes: [ToolDispatchOutcome]) {
        self.outcomes = outcomes
    }

    func next() -> ToolDispatchOutcome {
        lock.lock()
        defer { lock.unlock() }
        let outcome = outcomes[min(index, outcomes.count - 1)]
        index += 1
        return outcome
    }
}

actor SlowDispatchGate {
    private var dispatchEntered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func markDispatchEntered() {
        dispatchEntered = true
    }

    func dispatchWasEntered() -> Bool {
        dispatchEntered
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

actor TurnLoopTemperatureRecorder {
    private var temperatures: [Double?] = []

    func record(_ temperature: Double?) {
        temperatures.append(temperature)
    }

    func recordedTemperatures() -> [Double?] {
        temperatures
    }
}

actor TurnLoopFinishReasonRecorder {
    private var stamps: [(messageID: UUID, conversationID: UUID, finishReason: String)] = []

    func record(messageID: UUID, conversationID: UUID, finishReason: String) {
        stamps.append((messageID, conversationID, finishReason))
    }

    func recordedStamps() -> [(messageID: UUID, conversationID: UUID, finishReason: String)] {
        stamps
    }
}

actor TurnLoopMarkerRecorder {
    private var markers: [(conversationID: UUID, runID: UUID?, iteration: Int)] = []

    func record(conversationID: UUID, runID: UUID?, iteration: Int) {
        markers.append((conversationID, runID, iteration))
    }

    func recordedMarkers() -> [(conversationID: UUID, runID: UUID?, iteration: Int)] {
        markers
    }
}

enum TurnLoopTestPorts {
    static func make(
        state: TurnLoopConversationState,
        recorder: TurnLoopTranscriptRecorder? = nil,
        assistantToolCalls: [ToolCall] = [],
        dispatchOutcomes: [ToolDispatchOutcome] = [],
        contextCompaction: ContextCompactionConfiguration = .default,
        streamFactory: @escaping @Sendable () async -> AsyncThrowingStream<ModelStreamEvent, Error> = { AsyncThrowingStream { $0.finish() } },
        ensureBoundFn: (@Sendable (ModelConversation, SwiftAgentKitOrchestrator) async -> UUID)? = nil,
        modeRegistry: (any ModeRegistryAccessing)? = nil,
        slowDispatchGate: SlowDispatchGate? = nil,
        compactionRecorder: TurnLoopCompactionRecorder? = nil,
        finishReasonRecorder: TurnLoopFinishReasonRecorder? = nil,
        markerRecorder: TurnLoopMarkerRecorder? = nil,
        effectiveToolEntries: [ToolRegistryEntry] = [],
        temperatureRecorder: TurnLoopTemperatureRecorder? = nil,
        agentHarness: AgentHarnessConfiguration = .default,
        stopRequestedFn: (@Sendable (UUID) async -> Bool)? = nil,
        dispatchContract: AgentRuntimeToolDispatchContract = .conservativeDefault,
        hangDispatchSeconds: TimeInterval? = nil,
        reconnectMCPClient: (@Sendable (_ serverName: String) async -> Bool)? = nil
    ) -> AgentLoopPorts {
        let emptySnapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: effectiveToolEntries.map {
                RuntimeToolAvailabilitySnapshot(
                    entry: $0,
                    decision: ToolAvailabilityDecision(
                        allowed: true,
                        blockReason: nil,
                        isSensitive: false,
                        requiresEscalation: false,
                        requiresApproval: false,
                        isElevated: false,
                        approvalGranted: false,
                        approvalRoute: nil,
                        delegationPermissionPolicy: nil,
                        delegationTrustLevel: nil
                    )
                )
            },
            effectiveEntries: effectiveToolEntries,
            dispatchContract: dispatchContract
        )
        let dispatchQueue = DispatchOutcomeQueue(outcomes: dispatchOutcomes)
        let toolCallStreamGate = OneShotGate(armed: !assistantToolCalls.isEmpty)
        let conversationPort = SessionRuntimeConversationPort(
            conversationFn: { _ in await state.snapshot() },
            appendFn: { message, _, _ in
                if message.role == .tool, let recorder {
                    await recorder.recordTool(message)
                }
                await state.append(message)
            },
            markerFn: { conversationID, runID, iteration in
                if let markerRecorder {
                    await markerRecorder.record(
                        conversationID: conversationID,
                        runID: runID,
                        iteration: iteration
                    )
                }
            },
            rollbackFn: { _, _ in },
            stampFinishReasonFn: { messageID, conversationID, finishReason in
                if let finishReasonRecorder {
                    await finishReasonRecorder.record(
                        messageID: messageID,
                        conversationID: conversationID,
                        finishReason: finishReason
                    )
                }
            },
            stopRequestedFn: { conversationID in
                if let stopRequestedFn {
                    return await stopRequestedFn(conversationID)
                }
                return false
            }
        )
        let resolvedStream: @Sendable () async -> AsyncThrowingStream<ModelStreamEvent, Error> = {
            if assistantToolCalls.isEmpty {
                return await streamFactory()
            }
            let emitTools = await toolCallStreamGate.consume()
            return AsyncThrowingStream { continuation in
                if emitTools {
                    let response = LLMResponse(content: "working", toolCalls: assistantToolCalls)
                    continuation.yield(.complete(response))
                } else {
                    continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [])))
                }
                continuation.finish()
            }
        }
        let modelPort = SessionRuntimeModelPort(
            ensureBoundFn: ensureBoundFn ?? { conv, _ in conv.model.id },
            streamLLM: { _, _, _, _, _, _, temperatureOverride in
                if let temperatureRecorder {
                    await temperatureRecorder.record(temperatureOverride)
                }
                return await resolvedStream()
            }
        )
        let toolPort = SessionRuntimeToolPort(
            consumeApprovalTimeoutsFn: { _, _, _, _, _ in },
            effectiveToolsFn: { _, _, _, _ in emptySnapshot },
            dispatchFn: { _, _, _, _, _, _, _, _, _, _ in
                if let hangDispatchSeconds {
                    // Sleep past the harness timeout; cancellation ends the wait cooperatively.
                    try? await Task.sleep(for: .seconds(hangDispatchSeconds))
                } else if let slowDispatchGate {
                    await slowDispatchGate.markDispatchEntered()
                    await slowDispatchGate.waitForRelease()
                }
                return dispatchQueue.next()
            },
            dispatchBatchFn: { calls, _, _, _, _, _, _, _, _, _ in
                if let hangDispatchSeconds, !calls.isEmpty {
                    try? await Task.sleep(for: .seconds(hangDispatchSeconds))
                } else if let slowDispatchGate, !calls.isEmpty {
                    await slowDispatchGate.markDispatchEntered()
                    await slowDispatchGate.waitForRelease()
                }
                var outcomes: [ToolDispatchOutcome] = []
                outcomes.reserveCapacity(calls.count)
                for _ in calls {
                    outcomes.append(dispatchQueue.next())
                }
                return outcomes
            },
            dispatchApprovalFn: { _, _, _, _, _, _, _ in },
            isHaltingFn: { _, _ in false }
        )
        let contextPort = SessionRuntimeContextPort(
            bootstrapFn: { _, _ in },
            assembleFn: { _, _, _, compaction, _ in
                if let compactionRecorder {
                    await compactionRecorder.record(compaction)
                }
                return await state.snapshot().messages
            },
            afterTurnFn: { _, _, _ in }
        )
        return AgentLoopPorts(
            model: modelPort,
            context: contextPort,
            tools: toolPort,
            conversation: conversationPort,
            memory: nil,
            agentHarness: agentHarness,
            contextCompaction: contextCompaction,
            modeRegistry: modeRegistry ?? ModeRegistryTestSupport.makePort(seedingBuiltIns: true),
            logger: nil,
            reconnectMCPClient: reconnectMCPClient
        )
    }
}

actor OneShotGate {
    private var armed: Bool

    init(armed: Bool) {
        self.armed = armed
    }

    func consume() -> Bool {
        guard armed else { return false }
        armed = false
        return true
    }
}
