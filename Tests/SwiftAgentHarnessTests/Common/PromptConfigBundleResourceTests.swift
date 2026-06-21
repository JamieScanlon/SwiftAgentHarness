import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PromptConfigBundleResource")
struct PromptConfigBundleResourceTests {
    @Test("test bundle exposes PromptConfig.json")
    func testBundleProvidesPromptConfig() {
        #expect(PromptConfigBundleResource.url() != nil)
    }

    @Test("test PromptConfig disables agent skills for orchestrator warm-up")
    func testPromptConfigDisablesAgentSkills() {
        #expect(SystemPrompt.loadIncludeAgentSkillsFromConfig() == false)
    }
}
