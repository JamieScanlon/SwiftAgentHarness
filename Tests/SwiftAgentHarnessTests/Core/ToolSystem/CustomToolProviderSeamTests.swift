import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Custom tool provider seam", .serialized)
struct CustomToolProviderSeamTests {
    private struct StubHostToolProvider: ToolProvider {
        static let toolName = "host_injected_tool"
        var name: String { "stub-host-provider" }

        func availableTools() async -> [ToolDefinition] {
            [ToolDefinition(name: Self.toolName, description: "host supplied", parameters: [], type: .function)]
        }

        func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
            ToolResult(success: true, content: "ok", metadata: .object([:]), toolCallId: toolCall.id)
        }
    }

    @Test("host-injected providers appear in the built tool manager")
    func hostInjectedProviderAppearsInToolManager() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "custom-tool-seam")
        fixture.services.orchestratorRuntimeService.installAdditionalToolProviders { _ in
            [StubHostToolProvider()]
        }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
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
        #expect(toolNames.contains(StubHostToolProvider.toolName))
    }

    private final class StubConversationsDataProvider: ConversationsDataProviding, Sendable {
        func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
        func getConversation(id: UUID) async -> ModelConversation? { nil }
        func switchConversation(id: UUID, message: String?) async throws -> String? { nil }
    }
}
