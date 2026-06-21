import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("AgentLoopLLMStreaming")
struct AgentLoopLLMStreamingTests {
    @Test("required tool choice maps to required invocation policy")
    func requiredToolChoicePolicy() {
        #expect(AgentLoopLLMStreaming.toolInvocationPolicy(for: .required) == .required)
        #expect(AgentLoopLLMStreaming.toolInvocationPolicy(for: RuntimeToolChoicePosture.auto) == .automatic)
    }
}
