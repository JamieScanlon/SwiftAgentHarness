import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Screenshot retention in projection")
struct ContextScreenshotRetentionTests {
    /// A computer-use loop of `steps` observations inside one user turn.
    private func loop(steps: Int, tool: String = ComputerUseToolProvider.observeToolName) -> [Message] {
        var messages = [Message(id: UUID(), role: .user, content: "Fill in the form.")]
        for step in 1...steps {
            let id = "call-\(step)"
            messages.append(Message(id: UUID(), role: .assistant, content: "", toolCalls: [ToolCall(name: tool, id: id)]))
            messages.append(Message(
                id: UUID(),
                role: .tool,
                content: "observe: confirmed\n\nObservation o_\(step) — app com.apple.TextEdit, window w1\n[e2] button \"Bold\"",
                images: [Message.Image(name: "\(id)-image-1", imageData: ToolImageFixtures.tinyPNG, mediaType: "image/png")],
                toolCallId: id
            ))
        }
        return messages
    }

    private func screenshotCount(_ messages: [Message]) -> Int {
        messages.filter { $0.role == .tool }.reduce(0) { $0 + $1.images.count }
    }

    private func apply(_ messages: [Message], keep: Int = 3, batch: Int = 5) -> (messages: [Message], kind: CacheProjectionTransformationKind) {
        let result = ContextScreenshotRetention.apply(
            messages: messages,
            policy: ScreenshotRetentionPolicy(keepRecent: keep, pruneBatch: batch),
            toolCallResolutionContext: messages
        )
        return (result.messages, result.transformationKind)
    }

    @Test("Below keep + batch nothing is pruned and the projection is cache-neutral")
    func belowThreshold() {
        let messages = loop(steps: 7)
        let result = apply(messages)
        #expect(screenshotCount(result.messages) == 7)
        #expect(result.kind == .cacheNeutral)
    }

    @Test("Crossing a batch boundary prunes a whole batch of the oldest screenshots")
    func prunesInBatches() {
        for (steps, kept) in [(8, 3), (12, 7), (13, 3), (17, 7), (18, 3)] {
            let result = apply(loop(steps: steps))
            #expect(screenshotCount(result.messages) == kept, "steps=\(steps)")
        }
        #expect(apply(loop(steps: 8)).kind == .cacheEditing)
    }

    @Test("Between boundaries the pruned prefix is byte-identical from one step to the next")
    func prefixStableBetweenPrunes() {
        let atEight = apply(loop(steps: 8)).messages
        let atTwelve = apply(loop(steps: 12)).messages
        let prefix = 1 + 2 * 8
        for index in 0..<prefix {
            #expect(atEight[index].content == atTwelve[index].content)
            #expect(atEight[index].images == atTwelve[index].images)
        }
    }

    @Test("A pruned screenshot leaves a marker with its one-line summary; the tree text stays")
    func markerCarriesSummary() throws {
        let result = apply(loop(steps: 8))
        let firstTool = try #require(result.messages.first { $0.role == .tool })
        #expect(firstTool.images.isEmpty)
        #expect(firstTool.content.contains(ContextScreenshotRetention.markerPrefix))
        #expect(firstTool.content.contains("Observation o_1 — app com.apple.TextEdit, window w1"))
        #expect(firstTool.content.contains("[e2] button \"Bold\""))
        let lastTool = try #require(result.messages.last { $0.role == .tool })
        #expect(lastTool.images.count == 1)
        #expect(!lastTool.content.contains(ContextScreenshotRetention.markerPrefix))
    }

    @Test("Images from other tools and from the user are never counted or pruned")
    func onlyScreenTools() {
        var messages = loop(steps: 20, tool: "chart_tool")
        messages[0].images = [Message.Image(name: "photo.png", imageData: ToolImageFixtures.tinyPNG)]
        let result = apply(messages)
        #expect(screenshotCount(result.messages) == 20)
        #expect(result.messages[0].images.count == 1)
        #expect(result.kind == .cacheNeutral)
    }

    @Test("Applying twice changes nothing more")
    func idempotent() {
        let once = apply(loop(steps: 9)).messages
        let twice = apply(once).messages
        #expect(once.map(\.content) == twice.map(\.content))
        #expect(screenshotCount(twice) == screenshotCount(once))
    }

    @Test("Defaults keep every request under the ~20-image cap some vendors apply")
    func defaultsStayUnderTwenty() {
        for steps in stride(from: 1, through: 120, by: 7) {
            let result = ContextScreenshotRetention.apply(
                messages: loop(steps: steps),
                policy: .default,
                toolCallResolutionContext: []
            )
            #expect(screenshotCount(result.messages) < 20, "steps=\(steps)")
        }
    }

    @Test("Assembly prunes screenshots by default; a nil policy turns it off")
    func assembleIntegration() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        var conversation = ModelConversation(
            model: Model(
                protocol: .anthropic,
                modelName: "screenshot-retention",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion, .vision, .tools],
                modelProtocol: .anthropic
            ),
            messages: [],
            systemPrompt: "sys"
        )
        conversation.id = UUID()
        let messages = loop(steps: 20)
        func request(_ policy: ContextEngineProjectionPolicyInput) -> ContextEngineAssembleRequest {
            ContextEngineAssembleRequest(
                messages: messages,
                conversation: conversation,
                phase: .initial,
                gatingOverride: nil,
                compactionCustomInstructionsOverride: nil,
                enableContextTransform: false,
                compactionConfig: .default,
                transformMetadata: ConversationTransformMetadata(
                    conversationID: conversation.id,
                    modelID: conversation.model.id.uuidString,
                    modelName: conversation.model.modelName,
                    interactionMode: conversation.interactionMode,
                    routingPolicyTools: [],
                    routingPolicySkills: [],
                    thinkingEnabled: false,
                    reasoningEffort: nil,
                    metadata: nil
                ),
                lastContextLimitTokens: nil,
                lastPromptTokens: nil,
                events: [],
                eventLogFrontier: 0,
                lastModelRequestAtByConversationID: [:],
                lastCompactionLLMDateByConversationID: [:],
                persistCompactionCheckpoint: false,
                allowProactiveCompactionTriggers: false,
                compactionLockAlreadyHeldByCaller: false,
                derivedTailAtProjectionStart: 0,
                projectionPolicy: policy
            )
        }
        let pruned = await engine.assemble(request: request(ContextEngineProjectionPolicyInput())) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        #expect(screenshotCount(pruned.messages) == 5)
        let off = await engine.assemble(request: request(ContextEngineProjectionPolicyInput(screenshotRetentionPolicy: nil))) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        #expect(screenshotCount(off.messages) == 20)
    }

    @Test("A model's computer-use feature can override keep and batch")
    func modelOverrides() {
        let support = ComputerUseModelSupport(profile: ContractProfile(
            contract: .generate,
            surface: .anthropicMessages,
            interaction: [.unary],
            input: [.text, .image],
            output: [.text],
            guarantee: .freeText,
            features: [ComputerUseModelSupport.featureKey: FeatureSupport(params: [
                "keepRecentScreenshots": .integer(2),
                "pruneEvery": .integer(4),
            ])]
        ))
        let policy = ScreenshotRetentionPolicy.default.adjusted(for: support)
        #expect(policy.keepRecent == 2)
        #expect(policy.pruneBatch == 4)
        #expect(ScreenshotRetentionPolicy.default.adjusted(for: nil) == .default)
    }
}
