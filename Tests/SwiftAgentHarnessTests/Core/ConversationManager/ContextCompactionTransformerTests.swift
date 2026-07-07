import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ContextCompactionTransformer")
struct ContextCompactionTransformerTests {
    // MARK: - Stubs

    private actor CapturingSummarizer: ContextCompactionSummarizing {
        private(set) var capturedMessages: [Message] = []
        private(set) var capturedPreviousSummaryText: String?
        private let output: [Message]

        init(output: [Message]) {
            self.output = output
        }

        func summarizeMiddle(messages: [Message], maxMessages: Int, debugOutputPath: String?) async throws -> [Message] {
            try await summarizeMiddle(
                messages: messages,
                maxMessages: maxMessages,
                debugOutputPath: debugOutputPath,
                customInstructionsOverride: nil,
                identifierPreservationPolicy: nil,
                previousSummaryText: nil,
                summaryBudgetTokens: 2000,
                maxOutputTokens: 20_000
            )
        }

        func summarizeMiddle(
            messages: [Message],
            maxMessages: Int,
            debugOutputPath: String?,
            customInstructionsOverride _: String?,
            identifierPreservationPolicy _: ContextCompactionIdentifierPreservationPolicy?,
            previousSummaryText: String?,
            summaryBudgetTokens _: Int,
            maxOutputTokens _: Int
        ) async throws -> [Message] {
            capturedMessages = messages
            capturedPreviousSummaryText = previousSummaryText
            return Array(output.prefix(maxMessages))
        }

        func snapshot() async -> (messages: [Message], previousSummaryText: String?) {
            (capturedMessages, capturedPreviousSummaryText)
        }
    }

    private struct ThrowingSummarizer: ContextCompactionSummarizing {
        func summarizeMiddle(messages _: [Message], maxMessages _: Int, debugOutputPath _: String?) async throws -> [Message] {
            throw TestError.summarizerFailed
        }
    }

    private struct StubTurnSummarizer: TurnSummarizing {
        let decision: TurnSummaryDecision
        let shouldThrow: Bool

        init(decision: TurnSummaryDecision, shouldThrow: Bool = false) {
            self.decision = decision
            self.shouldThrow = shouldThrow
        }

        func summarizeTurn(
            turnMessages _: [Message],
            conversation _: ConversationTransformMetadata
        ) async throws -> TurnSummaryDecision {
            if shouldThrow { throw TestError.turnSummarizerFailed }
            return decision
        }
    }

    private struct StubSuccessSummarizer: ContextCompactionSummarizing {
        func summarizeMiddle(messages _: [Message], maxMessages _: Int, debugOutputPath _: String?) async throws -> [Message] {
            [
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "<summary>fallback ok</summary>",
                    timestamp: Date(),
                    toolCalls: []
                ),
            ]
        }
    }

    private enum TestError: Error {
        case summarizerFailed
        case turnSummarizerFailed
    }

    private actor PriorityRecordingScheduler: ModelCallScheduling {
        private(set) var lastPriority: ModelRequestPriority?

        func acquire(for _: UUID, priority: ModelRequestPriority) async {
            lastPriority = priority
        }

        func release(for _: UUID) async {}

        func inFlightCount(for _: UUID) async -> Int { 0 }
    }

    private struct OneShotLLM: LLMProtocol {
        nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
        nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
        nonisolated func getModelName() -> String { "test" }
        nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

        func send(_: [Message], config _: LLMRequestConfig) async throws -> LLMResponse {
            LLMResponse(content: "ok", toolCalls: [])
        }

        nonisolated func stream(_: [Message], config _: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.complete(LLMResponse(content: "ok", toolCalls: [])))
                continuation.finish()
            }
        }

        nonisolated func generateImage(_: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
            throw LLMError.unsupportedCapability(.imageGeneration)
        }
    }

    // MARK: - Helpers

    private func summarizerPathConfig(
        pruneNames: [String] = [],
        reinjectionEnabled: Bool = false,
        tailMinMessageCount: Int = 1
    ) -> ContextCompactionConfiguration {
        ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "transformer-test",
            fallbackContextLimitTokens: 2_500,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15,
            middleMinCharactersForCompactionLLM: 0,
            compactionLLMCooldownSeconds: 0,
            compactionToolResultPruneNames: pruneNames,
            maxRecentToolResults: 5,
            maxRecentPerNameToolResults: 0,
            toolResultPruneReplacementMode: .blankMarker,
            compactionSummaryBudgetTokens: 2000,
            compactionCustomInstructionsBlock: "",
            compactionSummarizerContextLimitTokens: 2_500,
            proactiveSafetyBufferTokens: 500,
            proactiveOutputReserveTokens: 500,
            headMinMessageCount: 1,
            tailMinMessageCount: tailMinMessageCount,
            tailTokenBudgetFraction: 0.0001,
            sessionMemorySwapBeforeCompactionEnabled: false,
            compactionReinjectionEnabled: reinjectionEnabled,
            compactionMinPromptTokenSavingsFraction: 0
        )
    }

    private func disabledAttachmentHygiene() -> ContextCompactionAttachmentDocumentHygienePolicy {
        ContextCompactionAttachmentDocumentHygienePolicy(
            enabled: false,
            maxImagesPerMessage: 0,
            documentCharacterThreshold: 0,
            imagePlaceholder: "",
            documentPlaceholder: ""
        )
    }

    private func hygienePolicy(
        toolResultPruningEnabled: Bool
    ) -> ContextCompactionDeterministicHygienePolicy {
        ContextCompactionDeterministicHygienePolicy(
            toolResultPruningEnabled: toolResultPruningEnabled,
            attachmentDocumentHygiene: disabledAttachmentHygiene()
        )
    }
    private func metadata() -> ConversationTransformMetadata {
        ConversationTransformMetadata(
            conversationID: UUID(),
            modelID: "transformer-test",
            modelName: "transformer-test",
            interactionMode: .agent,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: false,
            reasoningEffort: nil,
            metadata: nil
        )
    }

    private func compressibleTranscript(toolCallID: String = "tc-1") -> [Message] {
        [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "call",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "web-fetch", arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: String(repeating: "X", count: 8_000),
                timestamp: Date(),
                toolCalls: [],
                toolCallId: toolCallID
            ),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: String(repeating: "m", count: 8_000),
                timestamp: Date(),
                toolCalls: []
            ),
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: []),
        ]
    }

    private func baseTransformInput(
        messages: [Message],
        compactionEffectiveMiddle: [Message]? = nil,
        compactionRawMiddleMessages: [Message]? = nil,
        compactionCheckpointKind: ContextCompactionCheckpointKind? = nil,
        compactionCheckpointPrefixCount: Int? = nil,
        compactionPreviousSummaryText: String? = nil,
        compactionStrategy: ContextCompactionStrategy = .default,
        compactionFocusQuery: String? = nil,
        compactionCachePolicy: ContextCompactionCachePolicy? = nil,
        compactionDeterministicHygienePolicy: ContextCompactionDeterministicHygienePolicy? = nil,
        branchParentConversationID: UUID? = nil
    ) -> ContextTransformInput {
        ContextTransformInput(
            messages: messages,
            conversation: metadata(),
            phase: .initial,
            compactionEffectiveMiddle: compactionEffectiveMiddle,
            compactionRawMiddleMessages: compactionRawMiddleMessages,
            effectiveContextLimitTokens: 2_500,
            compactionCheckpointKind: compactionCheckpointKind,
            compactionCheckpointPrefixCount: compactionCheckpointPrefixCount,
            compactionModelContextLimitTokens: 2_500,
            compactionStrategy: compactionStrategy,
            compactionFocusQuery: compactionFocusQuery,
            branchParentConversationID: branchParentConversationID,
            compactionCachePolicy: compactionCachePolicy,
            compactionDeterministicHygienePolicy: compactionDeterministicHygienePolicy,
            compactionPreviousSummaryText: compactionPreviousSummaryText,
            compactionSplitBaseMessages: messages
        )
    }

    // MARK: - Phase and failure behavior

    @Test("transformContext is a no-op on continuation phases")
    func noOpOnContinuationPhase() async throws {
        let cfg = summarizerPathConfig()
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: ThrowingSummarizer())
        let messages = compressibleTranscript()
        let output = try await transformer.transformContext(
            ContextTransformInput(
                messages: messages,
                conversation: metadata(),
                phase: .continuation(round: 2),
                effectiveContextLimitTokens: 2_500,
                compactionSplitBaseMessages: messages
            )
        )
        #expect(output.diagnostics == "context_compaction_noop_non_initial")
        #expect(output.messages.map(\.id) == messages.map(\.id))
    }

    @Test("Summarizer failure returns original messages with context_compaction_failed")
    func summarizerFailureFallback() async throws {
        let cfg = summarizerPathConfig()
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: ThrowingSummarizer())
        let messages = compressibleTranscript()
        let output = try await transformer.transformContext(baseTransformInput(messages: messages))
        #expect(output.diagnostics == "context_compaction_failed")
        #expect(output.messages.map(\.id) == messages.map(\.id))
    }

    // MARK: - Identifier preservation and handoff template

    @Test("identifierPreservationPromptBlock renders strict, custom, and off modes")
    func identifierPreservationPromptBlockModes() {
        let strict = OllamaContextCompactionSummarizer.identifierPreservationPromptBlock(
            policy: ContextCompactionIdentifierPreservationPolicy(mode: .strict, customInstructions: nil)
        )
        #expect(strict.contains("# Identifier preservation"))
        #expect(strict.contains("Preserve opaque identifiers"))

        let custom = OllamaContextCompactionSummarizer.identifierPreservationPromptBlock(
            policy: ContextCompactionIdentifierPreservationPolicy(mode: .custom, customInstructions: "Keep run IDs verbatim.")
        )
        #expect(custom.contains("Additional rules:"))
        #expect(custom.contains("Keep run IDs verbatim."))

        let off = OllamaContextCompactionSummarizer.identifierPreservationPromptBlock(
            policy: ContextCompactionIdentifierPreservationPolicy(mode: .off, customInstructions: nil)
        )
        #expect(off.isEmpty)
    }

    @Test("Handoff user prompt template renders identifier preservation block token")
    func handoffTemplateIncludesIdentifierBlock() {
        let block = OllamaContextCompactionSummarizer.identifierPreservationPromptBlock(
            policy: ContextCompactionIdentifierPreservationPolicy(mode: .strict, customInstructions: nil)
        )
        let rendered = DynamicPrompt(
            template: ContextCompactionHandoffUserPromptTemplate.value,
            defaultTokens: [
                "summary_budget": "2000",
                "identifier_preservation_block": block,
                "custom_instructions_block": "",
                "previous_summary_block": "",
            ]
        ).render()
        #expect(rendered.contains("# Identifier preservation"))
        #expect(rendered.contains("Preserve opaque identifiers"))
    }

    // MARK: - Scheduling

    @Test("ContextCompactionLLMScheduling.modelID is deterministic for same endpoint and model")
    func compactionSchedulingModelIDDeterministic() {
        let url = URL(string: "http://localhost:11434")!
        let a = ContextCompactionLLMScheduling.modelID(model: "gemma4:e4b", ollamaServerURL: url)
        let b = ContextCompactionLLMScheduling.modelID(model: "gemma4:e4b", ollamaServerURL: url)
        #expect(a == b)
    }

    @Test("ContextCompactionLLMScheduling.modelID normalizes case and whitespace")
    func compactionSchedulingModelIDNormalization() {
        let url = URL(string: "http://localhost:11434")!
        let canonical = ContextCompactionLLMScheduling.modelID(model: "gemma4:e4b", ollamaServerURL: url)
        let noisy = ContextCompactionLLMScheduling.modelID(model: "  GEMMA4:E4B  ", ollamaServerURL: url)
        #expect(canonical == noisy)
    }

    @Test("wrapCompactionLLMForScheduling forwards background priority to the scheduler")
    func compactionSchedulingWrapperUsesBackgroundPriority() async throws {
        let scheduler = PriorityRecordingScheduler()
        let modelID = UUID()
        let scheduling = ContextCompactionLLMScheduling(scheduler: scheduler, modelID: modelID)
        let wrapped = wrapCompactionLLMForScheduling(OneShotLLM(), scheduling: scheduling)
        _ = try await wrapped.send(
            [Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])],
            config: LLMRequestConfig()
        )
        #expect(await scheduler.lastPriority == .background)
    }

    @Test("wrapCompactionLLMForScheduling is a passthrough when scheduling is nil")
    func compactionSchedulingWrapperNoOpWhenNil() async throws {
        let base = OneShotLLM()
        let wrapped = wrapCompactionLLMForScheduling(base, scheduling: nil)
        let response = try await wrapped.send(
            [Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])],
            config: LLMRequestConfig()
        )
        #expect(response.content == "ok")
    }

    // MARK: - Turn summary

    @Test("transformTurnSummary preserves user prompt and summarizes outcome")
    func turnSummaryPreservesUserPromptAndSummarizesOutcome() async throws {
        let cfg = summarizerPathConfig()
        let transformer = ContextCompactionTransformer(
            config: cfg,
            turnSummarizer: StubTurnSummarizer(decision: TurnSummaryDecision(succeeded: true, summary: "Completed auth refactor."))
        )
        let user = Message(id: UUID(), role: .user, content: "Refactor auth to JWT", timestamp: Date(), toolCalls: [])
        let assistant = Message(id: UUID(), role: .assistant, content: "Working...", timestamp: Date(), toolCalls: [])
        let output = try await transformer.transformTurnSummary(
            TurnSummaryTransformInput(
                conversation: metadata(),
                turnMessageRangeStartIndex: 0,
                turnMessages: [user, assistant]
            )
        )
        #expect(output.diagnostics == "turn_summary_success_result")
        #expect(output.replacementTurnMessages.count == 2)
        #expect(output.replacementTurnMessages.first?.role == .user)
        #expect(output.replacementTurnMessages.first?.content == "Refactor auth to JWT")
        #expect(output.replacementTurnMessages.last?.content == "Completed auth refactor.")
    }

    @Test("transformTurnSummary failure keeps original turn with turn_summary_failed")
    func turnSummaryFailureFallsBackToOriginalTurn() async throws {
        let cfg = summarizerPathConfig()
        let transformer = ContextCompactionTransformer(
            config: cfg,
            turnSummarizer: StubTurnSummarizer(decision: TurnSummaryDecision(succeeded: false, summary: ""), shouldThrow: true)
        )
        let turn = [
            Message(id: UUID(), role: .user, content: "Do work", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "partial", timestamp: Date(), toolCalls: []),
        ]
        let output = try await transformer.transformTurnSummary(
            TurnSummaryTransformInput(conversation: metadata(), turnMessageRangeStartIndex: 0, turnMessages: turn)
        )
        #expect(output.diagnostics == "turn_summary_failed")
        #expect(output.replacementTurnMessages.map(\.id) == turn.map(\.id))
    }

    // MARK: - Checkpoint branches

    @Test("Summarized checkpoint with no new tail emits noop diagnostic")
    func branchSummarizedCheckpointNoNewTail() async throws {
        let cfg = summarizerPathConfig()
        let summarySynth = Message(id: UUID(), role: .assistant, content: "## Active Task\nexisting", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summarySynth])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let transcript = compressibleTranscript()
        let split = ContextCompactionCheckpointSupport.splitForCompaction(
            transcript,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        let output = try await transformer.transformContext(
            baseTransformInput(
                messages: transcript,
                compactionEffectiveMiddle: [summarySynth],
                compactionRawMiddleMessages: split.middle,
                compactionCheckpointKind: .summarized,
                compactionCheckpointPrefixCount: 1
            )
        )
        #expect(output.diagnostics == ContextCompactionTransformer.noopSummarizedNoNewTailDiagnostic)
        #expect(await summarizer.snapshot().messages.isEmpty)
    }

    @Test("Summarized checkpoint passes only new tail to summarizer without double-carrying prior synth")
    func summarizedCheckpointDoesNotDoubleCarryPriorSummary() async throws {
        let cfg = summarizerPathConfig()
        let prevSynth = Message(id: UUID(), role: .assistant, content: "## Active Task\nold", timestamp: Date(), toolCalls: [])
        let newTail = Message(id: UUID(), role: .assistant, content: String(repeating: "N", count: 8_000), timestamp: Date(), toolCalls: [])
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nupdated", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let transcript = compressibleTranscript() + [newTail]
        let split = ContextCompactionCheckpointSupport.splitForCompaction(
            transcript,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        let priorSummary = "prior summary body"
        let output = try await transformer.transformContext(
            baseTransformInput(
                messages: transcript,
                compactionEffectiveMiddle: [prevSynth, newTail],
                compactionRawMiddleMessages: split.middle + [newTail],
                compactionCheckpointKind: .summarized,
                compactionCheckpointPrefixCount: 1,
                compactionPreviousSummaryText: priorSummary
            )
        )
        #expect(output.diagnostics == ContextCompactionTransformer.summarizedDiagnostic)
        let captured = await summarizer.snapshot()
        #expect(captured.previousSummaryText == priorSummary)
        #expect(captured.messages.count == 1)
        #expect(captured.messages.first?.id == newTail.id)
        #expect(!captured.messages.contains(where: { $0.content.contains("## Active Task\nold") }))
    }

    @Test("Summarized checkpoint on branched conversation slices prefix before branch marker")
    func summarizedCheckpointBranchPrefixSlicesCorrectly() async throws {
        let cfg = summarizerPathConfig()
        let prevSynth = Message(id: UUID(), role: .assistant, content: "## Active Task\nold", timestamp: Date(), toolCalls: [])
        let newTail = Message(id: UUID(), role: .assistant, content: String(repeating: "N", count: 8_000), timestamp: Date(), toolCalls: [])
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nupdated", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let transcript = compressibleTranscript() + [newTail]
        let split = ContextCompactionCheckpointSupport.splitForCompaction(
            transcript,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        let priorSummary = "prior summary body"
        let output = try await transformer.transformContext(
            baseTransformInput(
                messages: transcript,
                compactionEffectiveMiddle: [prevSynth, newTail],
                compactionRawMiddleMessages: split.middle + [newTail],
                compactionCheckpointKind: .summarized,
                compactionCheckpointPrefixCount: 1,
                compactionPreviousSummaryText: priorSummary,
                branchParentConversationID: UUID()
            )
        )
        #expect(output.diagnostics == ContextCompactionTransformer.summarizedDiagnostic)
        let captured = await summarizer.snapshot()
        #expect(captured.previousSummaryText == priorSummary)
        #expect(captured.messages.count == 2)
        #expect(captured.messages.first?.content.contains("[BranchContext]") == true)
        #expect(captured.messages.last?.id == newTail.id)
        #expect(!captured.messages.contains(where: { $0.content.contains("## Active Task\nold") }))
    }

    @Test("Summarized checkpoint noop on branched conversation preserves prior synthetic summary")
    func summarizedCheckpointBranchNoNewTailPreservesPriorSynth() async throws {
        let cfg = summarizerPathConfig()
        let summarySynth = Message(id: UUID(), role: .assistant, content: "## Active Task\nexisting", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summarySynth])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let transcript = compressibleTranscript()
        let split = ContextCompactionCheckpointSupport.splitForCompaction(
            transcript,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        let output = try await transformer.transformContext(
            baseTransformInput(
                messages: transcript,
                compactionEffectiveMiddle: [summarySynth],
                compactionRawMiddleMessages: split.middle,
                compactionCheckpointKind: .summarized,
                compactionCheckpointPrefixCount: 1,
                branchParentConversationID: UUID()
            )
        )
        #expect(output.diagnostics == ContextCompactionTransformer.noopSummarizedNoNewTailDiagnostic)
        #expect(await summarizer.snapshot().messages.isEmpty)
        let before = ContextCompactionCheckpointSupport.splitForCompaction(
            transcript,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        let middle = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            output.messages,
            headCount: before.head.count,
            tailCount: before.tail.count
        )
        #expect(middle.count == 2)
        #expect(middle.first?.content.contains("[BranchContext]") == true)
        #expect(middle.last?.content.contains("## Active Task\nexisting") == true)
    }

    // MARK: - Summarizer input capture

    @Test("Summarizer receives pruned tool results for configured tool names")
    func summarizerReceivesPrunedToolResults() async throws {
        let cfg = summarizerPathConfig(pruneNames: ["web-fetch"])
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nok", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let messages = compressibleTranscript()
        _ = try await transformer.transformContext(baseTransformInput(messages: messages))
        let captured = await summarizer.snapshot().messages
        let cleared = captured.filter { $0.content == ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder }
        #expect(!cleared.isEmpty)
    }

    @Test("Summarizer receives effective middle when checkpoint hints are provided")
    func summarizerReceivesEffectiveMiddleWhenHintsProvided() async throws {
        let cfg = summarizerPathConfig()
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nok", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let messages = compressibleTranscript()
        let effective = [
            Message(
                id: UUID(),
                role: .assistant,
                content: String(repeating: "E", count: 8_000),
                timestamp: Date(),
                toolCalls: []
            ),
        ]
        _ = try await transformer.transformContext(
            baseTransformInput(
                messages: messages,
                compactionEffectiveMiddle: effective,
                compactionRawMiddleMessages: messages
            )
        )
        let captured = await summarizer.snapshot().messages
        #expect(captured.map(\.id) == effective.map(\.id))
    }

    @Test("Summarized output provenance covers every raw middle message id")
    func provenanceSourcesCoverFullRawMiddleWhenHintsProvided() async throws {
        let cfg = summarizerPathConfig(reinjectionEnabled: false)
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nok", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let messages = compressibleTranscript()
        let split = ContextCompactionCheckpointSupport.splitForCompaction(
            messages,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        let output = try await transformer.transformContext(
            baseTransformInput(
                messages: messages,
                compactionRawMiddleMessages: split.middle
            )
        )
        let synthesized = output.messageProvenance?.filter { $0.origin == .synthesized } ?? []
        #expect(!synthesized.isEmpty)
        let sourceIDs = Set(synthesized.flatMap(\.sourceMessageIDs))
        #expect(sourceIDs == Set(split.middle.map(\.id)))
    }

    @Test("Summarized output merges summary into first tail message when tail starts with assistant")
    func summarizedOutputMergesSummaryWhenTailStartsWithAssistant() async throws {
        let cfg = summarizerPathConfig(tailMinMessageCount: 2)
        let summaryOut = Message(
            id: UUID(),
            role: .assistant,
            content: "## Active Task\nfinish task",
            timestamp: Date(),
            toolCalls: []
        )
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let partialAssistantID = UUID()
        let transcript: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: String(repeating: "m", count: 8_000),
                timestamp: Date(),
                toolCalls: []
            ),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(
                id: partialAssistantID,
                role: .assistant,
                content: "partial reply",
                timestamp: Date(),
                toolCalls: []
            ),
            Message(id: UUID(), role: .user, content: "u3 latest", timestamp: Date(), toolCalls: []),
        ]
        let split = ContextCompactionCheckpointSupport.splitForCompaction(
            transcript,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        #expect(split.tail.first?.role == .assistant)
        let output = try await transformer.transformContext(baseTransformInput(messages: transcript))
        #expect(output.diagnostics == ContextCompactionTransformer.summarizedDiagnostic)
        let tailMessages = Array(output.messages.suffix(split.tail.count))
        #expect(tailMessages.first?.id == partialAssistantID)
        #expect(tailMessages.first?.content.contains("REFERENCE ONLY") == true)
        #expect(tailMessages.first?.content.contains("## Active Task\nfinish task") == true)
        #expect(tailMessages.first?.content.contains("partial reply") == true)
        let persisted = try #require(output.compactionPersistedMiddle)
        #expect(persisted.count == 1)
        #expect(persisted[0].role == .assistant)
        #expect(persisted[0].content.contains("REFERENCE ONLY"))
        #expect(persisted[0].content.contains("## Active Task\nfinish task"))
        #expect(persisted[0].content.contains("partial reply") == false)
    }

    // MARK: - Hygiene and cache policy

    @Test("Deterministic hygiene policy can disable tool-result pruning before summarizer")
    func deterministicHygieneToolPruningToggle() async throws {
        let cfg = summarizerPathConfig(pruneNames: ["web-fetch"])
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nok", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let messages = compressibleTranscript()
        let hygiene = hygienePolicy(toolResultPruningEnabled: false)
        _ = try await transformer.transformContext(
            baseTransformInput(
                messages: messages,
                compactionDeterministicHygienePolicy: hygiene
            )
        )
        let captured = await summarizer.snapshot().messages
        let toolMessages = captured.filter { $0.role == .tool }
        #expect(toolMessages.contains(where: { $0.content.count > 1000 }))
    }

    @Test("Deterministic hygiene trims document-like payloads and image attachments")
    func deterministicHygieneTrimsDocumentAndImages() async throws {
        let cfg = summarizerPathConfig()
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nok", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let doc = Message(
            id: UUID(),
            role: .assistant,
            content: String(repeating: "line\n", count: 50),
            timestamp: Date(),
            toolCalls: []
        )
        let images = (0..<4).map { i in
            Message.Image(name: "img\(i).png", path: "/tmp/img\(i).png")
        }
        let imageHeavy = Message(
            id: UUID(),
            role: .user,
            content: "see images",
            timestamp: Date(),
            images: images,
            toolCalls: []
        )
        var messages = compressibleTranscript()
        messages.removeLast()
        messages.append(doc)
        messages.append(imageHeavy)
        messages.append(
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: [])
        )
        let attachmentHygiene = ContextCompactionAttachmentDocumentHygienePolicy(
            enabled: true,
            maxImagesPerMessage: 1,
            documentCharacterThreshold: 100,
            imagePlaceholder: "[image trimmed]",
            documentPlaceholder: "[document trimmed]"
        )
        let hygiene = ContextCompactionDeterministicHygienePolicy(
            toolResultPruningEnabled: true,
            attachmentDocumentHygiene: attachmentHygiene
        )
        _ = try await transformer.transformContext(
            baseTransformInput(
                messages: messages,
                compactionDeterministicHygienePolicy: hygiene
            )
        )
        let captured = await summarizer.snapshot().messages
        #expect(captured.contains(where: { $0.content == "[document trimmed]" }))
        let trimmedImageMessage = captured.first(where: { $0.id == imageHeavy.id })
        #expect(trimmedImageMessage?.images.count == 1)
        #expect(trimmedImageMessage?.content.contains("[image trimmed]") == true)
    }

    @Test("Focused strategy passes full middle to summarizer (focus is prompt-only)")
    func focusedStrategyFiltersMiddle() async throws {
        let cfg = summarizerPathConfig()
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nok", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let messages = compressibleTranscript()
        let split = ContextCompactionCheckpointSupport.splitForCompaction(
            messages,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        _ = try await transformer.transformContext(
            baseTransformInput(
                messages: messages,
                compactionStrategy: .focused,
                compactionFocusQuery: "auth module"
            )
        )
        let captured = await summarizer.snapshot().messages
        #expect(captured.map(\.id) == split.middle.map(\.id))
    }

    @Test("Cache-aware pruning keeps stable prefix and drops expired suffix user messages")
    func cacheAwarePruningRespectsTTLAndStablePrefix() async throws {
        let cfg = summarizerPathConfig()
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nok", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let old = Date().addingTimeInterval(-3600)
        let recent = Date()
        let middle = [
            Message(id: UUID(), role: .user, content: "stable-1", timestamp: old, toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "stable-2", timestamp: old, toolCalls: []),
            Message(id: UUID(), role: .user, content: "expired-user", timestamp: old, toolCalls: []),
            Message(id: UUID(), role: .assistant, content: String(repeating: "z", count: 8_000), timestamp: recent, toolCalls: []),
            Message(id: UUID(), role: .user, content: "recent-user", timestamp: recent, toolCalls: []),
        ]
        let messages = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
        ] + middle
        let cachePolicy = ContextCompactionCachePolicy(
            enabled: true,
            stablePrefixMessageCount: 2,
            ttlSeconds: 60
        )
        _ = try await transformer.transformContext(
            baseTransformInput(
                messages: messages,
                compactionEffectiveMiddle: middle,
                compactionRawMiddleMessages: middle,
                compactionCachePolicy: cachePolicy,
                compactionDeterministicHygienePolicy: hygienePolicy(toolResultPruningEnabled: false)
            )
        )
        let captured = await summarizer.snapshot().messages
        #expect(captured.contains(where: { $0.content == "stable-1" }))
        #expect(captured.contains(where: { $0.content == "stable-2" }))
        #expect(!captured.contains(where: { $0.content == "expired-user" }))
        #expect(captured.contains(where: { $0.content == "recent-user" }))
    }

    @Test("Cache-aware pruning preserves assistant and tool rows for tool-pair safety")
    func cacheAwarePruningPreservesToolPairRows() async throws {
        let cfg = summarizerPathConfig()
        let summaryOut = Message(id: UUID(), role: .assistant, content: "## Active Task\nok", timestamp: Date(), toolCalls: [])
        let summarizer = CapturingSummarizer(output: [summaryOut])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let old = Date().addingTimeInterval(-3600)
        let toolCallID = "cache-tc-1"
        let messages = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: old, toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "tool call",
                timestamp: old,
                toolCalls: [ToolCall(name: "read_file", arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: String(repeating: "T", count: 8_000),
                timestamp: old,
                toolCalls: [],
                toolCallId: toolCallID
            ),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
        ]
        let cachePolicy = ContextCompactionCachePolicy(
            enabled: true,
            stablePrefixMessageCount: 0,
            ttlSeconds: 60
        )
        _ = try await transformer.transformContext(
            baseTransformInput(
                messages: messages,
                compactionCachePolicy: cachePolicy,
                compactionDeterministicHygienePolicy: hygienePolicy(toolResultPruningEnabled: false)
            )
        )
        let captured = await summarizer.snapshot().messages
        let assistantWithToolCall = captured.contains { message in
            message.role == .assistant && message.toolCalls.contains { $0.id == toolCallID }
        }
        let toolResult = captured.contains { message in
            message.role == .tool && message.toolCallId == toolCallID
        }
        #expect(assistantWithToolCall)
        #expect(toolResult)
    }

    // MARK: - Provider fallback

    @Test("Default provider factory builds fallback chain when slot is none with Ollama fallback")
    func providerFallbackChainForCompactionSummarizer() async throws {
        var config = ContextCompactionConfiguration.default
        config.optionalCompactionProviderSlot = "none"
        config.optionalCompactionProviderFallbackToOllama = true
        let factory = DefaultContextCompactionProviderFactory()
        let bundle = try #require(factory.makeProvider(config: config, logger: nil, scheduling: nil))
        #expect(bundle.summarizer is FallbackContextCompactionSummarizer)
        #expect(bundle.turnSummarizer is FallbackTurnSummarizer)

        let primary = ProviderUnavailableSummarizer(slot: "none")
        let chain = FallbackContextCompactionSummarizer(
            primary: primary,
            fallback: StubSuccessSummarizer(),
            logger: nil
        )
        let result = try await chain.summarizeMiddle(messages: [], maxMessages: 1, debugOutputPath: nil)
        #expect(result.first?.content.contains("fallback ok") == true)
    }
}
