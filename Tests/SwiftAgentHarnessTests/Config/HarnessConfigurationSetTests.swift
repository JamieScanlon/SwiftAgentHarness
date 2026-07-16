import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessConfigurationSet")
struct HarnessConfigurationSetTests {
    @Test("lockedDownBaseline uses compiled defaults")
    func lockedDownBaseline() {
        let baseline = HarnessConfigurationSet.lockedDownBaseline
        #expect(baseline.agentHarness.strictAgentHarnessPrompts == AgentHarnessConfiguration.default.strictAgentHarnessPrompts)
        #expect(baseline.promptAssembly.includeAgentSkills == true)
        #expect(baseline.memory.enabled == MemoryConfiguration.default.enabled)
        #expect(baseline.modeProfiles.profiles.isEmpty)
        #expect(baseline.trustPolicy.mode == .none)
    }

    @Test("load(from:) matches per-section document loaders for fixture")
    func loadMatchesSectionLoaders() throws {
        guard let url = Bundle.module.url(forResource: "PromptConfig", withExtension: "json") else {
            Issue.record("PromptConfig.json fixture not in test bundle")
            return
        }
        let data = try Data(contentsOf: url)
        let document = try PromptConfigDocument.parse(data: data)
        let set = HarnessConfigurationSet.load(from: document)

        #expect(set.agentHarness.strictAgentHarnessPrompts == AgentHarnessConfiguration.load(from: document).strictAgentHarnessPrompts)
        #expect(set.promptAssembly.includeAgentSkills == PromptAssemblyConfiguration.load(from: document).includeAgentSkills)
        #expect(set.promptAssembly.includeCurrentDateTime == false)
        #expect(set.promptAssembly.skillsFolderPath == "/skills")
        #expect(set.memory.activeMemoryEnabled == MemoryConfigurationLoader.load(from: document).activeMemoryEnabled)
        #expect(set.modeProfiles.profiles.count == ModeProfileConfiguration.load(from: document).profiles.count)
        #expect(set.modelPoolProviderPreference.order == ModelPoolProviderPreferenceConfiguration.load(from: document).order)
    }

    @Test("load(from:) applies host agentHarness and memory overrides")
    func loadAppliesHostOverrides() throws {
        let json = """
        {
          "options": { "includeAgentSkills": false, "includeCurrentDateTime": false },
          "agentHarness": { "strictAgentHarnessPrompts": false },
          "memory": { "activeMemoryEnabled": false }
        }
        """
        let document = try PromptConfigDocument.parse(data: Data(json.utf8))
        let set = HarnessConfigurationSet.load(from: document)
        #expect(set.agentHarness.strictAgentHarnessPrompts == false)
        #expect(set.promptAssembly.includeAgentSkills == false)
        #expect(set.memory.activeMemoryEnabled == false)
    }
}
