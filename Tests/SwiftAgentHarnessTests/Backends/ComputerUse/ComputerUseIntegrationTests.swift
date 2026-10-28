import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use integration", .serialized)
struct ComputerUseIntegrationTests {
    private func leasedProvider(approvals: (any ExecApprovalDelivering)? = nil) async throws -> (FakeDisplayTarget, ComputerUseSession, ComputerUseToolProvider) {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
        let registry = DisplayTargetRegistry(targets: [target])
        let grant = try await registry.lease(
            LeaseRequest(
                target: target.manifest.id,
                agentID: "agent",
                grants: [.app(bundleID: "com.apple.TextEdit", tier: .full), .app(bundleID: "com.1password.1password", tier: .full)],
                budgets: ComputerUseBudgets(maxSteps: 20, maxDuration: .seconds(600)),
                operatorInitiated: true,
                userPresent: true
            ),
            approve: { request in request.review.grantable.map(\.grant) }
        )
        #expect(grant.review.blocked.count == 1)
        let session = ComputerUseSession(
            target: grant.target,
            lease: grant.lease,
            configuration: ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["Bold the title and save."])),
            approvals: approvals,
            now: { ComputerUseFixtures.epoch }
        )
        return (target, session, ComputerUseToolProvider(session: session))
    }

    @Test("Host-injected computer-use tools appear in the built tool manager")
    func toolsInstalledThroughSeam() async throws {
        let (_, _, provider) = try await leasedProvider()
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "computer-use-seam")
        fixture.services.orchestratorRuntimeService.installAdditionalToolProviders { _ in [provider] }
        let conversation = ModelConversation(
            id: UUID(),
            model: HarnessConversationTestFixtures.makeTestModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let systemPrompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true,
            interactionMode: .agent
        )
        let toolNames = await fixture.services.orchestratorRuntimeService.testing_buildToolManagerToolNames(
            systemPrompt: systemPrompt,
            activeConversation: conversation
        )
        #expect(toolNames.contains(ComputerUseToolProvider.observeToolName))
        #expect(toolNames.contains(ComputerUseToolProvider.handoffToolName))
    }

    @Test("Lease, observe, confirm, and act end to end; screen text comes back wrapped as untrusted")
    func endToEnd() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session, provider) = try await leasedProvider(approvals: approvals)
        let manager = ToolManager(providers: [provider])

        let observeCall = ToolCall(name: ComputerUseToolProvider.observeToolName, id: "c1")
        let observed = try await manager.executeTool(observeCall)
        let wrapped = ToolResultExternalContentMiddleware.apply(toolCall: observeCall, result: observed, entry: nil)
        #expect(ExternalContentEnvelope.isAlreadyWrapped(wrapped.content))
        #expect(wrapped.content.contains("Screen content"))

        let click = try await manager.executeTool(ToolCall(
            name: ComputerUseToolProvider.clickToolName,
            arguments: .object(["observation": .string("o_1"), "ref": .string("e2")]),
            id: "c2"
        ))
        #expect(click.success)
        #expect(await approvals.requests.count == 1)
        #expect(await target.actCalls == [[.click(at: .ref("e2", observation: "o_1"))]])

        await session.end()
        #expect(await target.releases == [.completed])
        let after = try await manager.executeTool(observeCall)
        #expect(!after.success)
    }

    @Test("A screenshot reaches the Anthropic wire as an image block inside its tool_result, unresized")
    func screenshotReachesWire() async throws {
        let (_, _, provider) = try await leasedProvider()
        let call = ToolCall(name: ComputerUseToolProvider.observeToolName, id: "toolu_1")
        let raw = try await ToolManager(providers: [provider]).executeTool(call)
        let enveloped = ToolResultExternalContentMiddleware.apply(toolCall: call, result: raw, entry: nil)
        let spillContext = ToolResultFormattingSpillContext(
            conversationID: UUID(),
            toolName: call.name,
            entry: nil,
            spillWriter: HarnessSessionPersistenceSpillWriter(persistence: InMemoryHarnessSessionPersistence()),
            modelSupportsVision: true
        )
        // The fake's screenshots are 1280 px wide, above the default 1200 px cap.
        let overCap = ToolResultFormattingStack.apply(result: enveloped, stage: .runtime, configuration: .default, spillContext: spillContext)
        #expect(overCap.images.isEmpty)
        #expect(overCap.content.contains("observe again with a smaller image limit"))

        var withinCap = ToolResultFormattingConfiguration.default
        withinCap.maxInlineImagePixelDimension = 1_568
        let formatted = ToolResultFormattingStack.apply(result: enveloped, stage: .runtime, configuration: withinCap, spillContext: spillContext)
        let toolMessage = AgentLoopToolDispatch.toolResultMessage(for: formatted, fallbackToolCallID: call.id)
        #expect(toolMessage.images.first?.imageData == ToolImageFixtures.tinyPNG)

        let llm = AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "dummy",
            model: "claude-test",
            capabilities: [.completion, .vision, .tools],
            systemPrompt: try await ToolImageWireFixtures.prompt()
        )
        let messages = [
            Message(id: UUID(), role: .user, content: "Bold the title."),
            Message(id: UUID(), role: .assistant, content: "", toolCalls: [call]),
            toolMessage,
        ]
        let body = try await llm.testEncodedRequestBody(from: messages, config: LLMRequestConfig())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wire = try #require(json["messages"] as? [[String: Any]])
        let toolResult = try #require(
            wire.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.first { ($0["type"] as? String) == "tool_result" }
        )
        let blocks = try #require(toolResult["content"] as? [[String: Any]])
        let text = blocks.first { ($0["type"] as? String) == "text" }?["text"] as? String ?? ""
        #expect(ExternalContentEnvelope.isAlreadyWrapped(text))
        let source = try #require(blocks.first { ($0["type"] as? String) == "image" }?["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == ToolImageFixtures.tinyPNG.base64EncodedString())
    }
}
