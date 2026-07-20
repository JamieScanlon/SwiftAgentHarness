import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessWorkspaceResolver (LS2)")
struct HarnessWorkspaceResolverTests {
    private func makeConversation(cwd: String?) -> ModelConversation {
        var conversation = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "test",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "sys"
        )
        conversation.harnessPersistenceCwd = cwd
        return conversation
    }

    @Test("recorded cwd wins for side-effecting resolve")
    func recordedCwdWins() throws {
        let conversation = makeConversation(cwd: "/trusted/workspace")
        let resolved = try HarnessWorkspaceResolver.resolveForSideEffects(
            conversation: conversation,
            policy: .default
        )
        #expect(resolved == "/trusted/workspace")
    }

    @Test("nil cwd fails closed when ambient fallback is disabled")
    func nilCwdFailsClosed() {
        let conversation = makeConversation(cwd: nil)
        #expect(throws: ConversationServiceError.harnessWorkspaceNotRecorded(conversationID: conversation.id)) {
            _ = try HarnessWorkspaceResolver.resolveForSideEffects(
                conversation: conversation,
                policy: .default
            )
        }
    }

    @Test("prompt context resolve never uses ambient fallback")
    func promptContextRecordedOnly() {
        let conversation = makeConversation(cwd: nil)
        #expect(HarnessWorkspaceResolver.resolveForPromptContext(conversation: conversation) == nil)
    }

    @Test("normalized cwd trims whitespace and rejects empty")
    func normalizedCwdTrims() {
        #expect(HarnessWorkspaceResolver.normalizedCwd("  /a/b  ") == "/a/b")
        #expect(HarnessWorkspaceResolver.normalizedCwd("   ") == nil)
        #expect(HarnessWorkspaceResolver.normalizedCwd(nil) == nil)
    }

    @Test("sanctioned ambient resolves when policy allows fallback")
    func ambientFallbackWhenPolicyAllows() throws {
        let conversation = makeConversation(cwd: nil)
        let policy = HarnessWorkspacePolicy(allowAmbientWorkspaceFallback: true)
        guard HarnessWorkspaceResolver.ambientIfKnown() != nil else {
            return
        }
        let resolved = try HarnessWorkspaceResolver.resolveForSideEffects(
            conversation: conversation,
            policy: policy
        )
        #expect(!resolved.isEmpty)
        #expect(resolved != "/")
    }
}
