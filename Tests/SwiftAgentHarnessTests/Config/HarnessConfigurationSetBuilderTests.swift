import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessConfigurationSet.Builder")
struct HarnessConfigurationSetBuilderTests {
    @Test("default Builder builds locked-down baseline public sections")
    func defaultMatchesBaseline() {
        let built = HarnessConfigurationSet.Builder().build()
        let baseline = HarnessConfigurationSet.lockedDownBaseline
        #expect(built.promptAssembly == baseline.promptAssembly)
        #expect(built.agentHarness == baseline.agentHarness)
        #expect(built.thinkingPolicy == baseline.thinkingPolicy)
        #expect(built.conversationTransforms == baseline.conversationTransforms)
        #expect(built.modeProfiles.profiles.isEmpty)
        #expect(built.modelPoolBudget == baseline.modelPoolBudget)
        #expect(built.modelPoolFailover == baseline.modelPoolFailover)
        #expect(built.modelPoolProviderPreference == baseline.modelPoolProviderPreference)
        #expect(built.trustPolicy.mode == baseline.trustPolicy.mode)
        #expect(built.toolPolicy.parallelDispatchEnabled == baseline.toolPolicy.parallelDispatchEnabled)
    }

    @Test("withToolPolicy and withModeProfiles override stick; other sections remain baseline")
    func overridesStick() async throws {
        let modeProfiles = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "builder-mode",
                    extends: "chat",
                    tools: .object([
                        "allow+": .array([.string("extra_tool")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let built = HarnessConfigurationSet.Builder()
            .withToolPolicy(.unrestricted)
            .withModeProfiles(modeProfiles)
            .withTrustPolicy(.disabled)
            .build()

        #expect(built.modeProfiles.profiles.map(\.id) == ["builder-mode"])
        #expect(built.toolPolicy.parallelDispatchEnabled == ToolPolicyConfiguration.unrestricted.parallelDispatchEnabled)
        #expect(built.trustPolicy.mode == TrustPolicyConfiguration.disabled.mode)
        #expect(built.agentHarness == HarnessConfigurationSet.lockedDownBaseline.agentHarness)

        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: built.modeProfiles
        )
        let profile = try await registry.resolve(modeId: "builder-mode")
        #expect(profile.tools.allow == ["*"])
    }

    @Test("withDocument loads public sections from a PromptConfigDocument")
    func withDocumentLoads() throws {
        let json = """
        {
          "toolPolicy": {},
          "modeProfiles": [
            {
              "id": "doc-mode",
              "extends": "agent",
              "tools": { "allow": ["bash"], "allow+": ["read_file"] }
            }
          ]
        }
        """
        let document = try PromptConfigDocument.parse(data: Data(json.utf8))
        let built = HarnessConfigurationSet.Builder()
            .withDocument(document)
            .build()
        #expect(built.modeProfiles.profiles.contains(where: { $0.id == "doc-mode" }))
    }
}
