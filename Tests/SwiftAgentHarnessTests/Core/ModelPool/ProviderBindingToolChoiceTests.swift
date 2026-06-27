import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("ProviderBinding toolChoice override")
struct ProviderBindingToolChoiceTests {
    @Test("effectiveToolChoiceModes is identity when override is nil")
    func nilOverrideIsIdentity() {
        let baseline: Set<ToolChoiceMode> = [.auto, .none, .required, .specific]
        #expect(ModelManager.effectiveToolChoiceModes(baseline: baseline, override: nil) == baseline)
    }

    @Test("effectiveToolChoiceModes intersects downward and retains auto")
    func downwardIntersectionRetainsAuto() {
        let baseline: Set<ToolChoiceMode> = [.auto, .none, .required, .specific]
        let effective = ModelManager.effectiveToolChoiceModes(
            baseline: baseline,
            override: [.required]
        )
        #expect(effective == [.auto, .required])
    }

    @Test("effectiveToolChoiceModes retains auto when override omits it")
    func autoRetainedWhenOverrideOmitsIt() {
        let baseline: Set<ToolChoiceMode> = [.auto, .required]
        let effective = ModelManager.effectiveToolChoiceModes(
            baseline: baseline,
            override: [.required]
        )
        #expect(effective.contains(.auto))
        #expect(effective == [.auto, .required])
    }

    @Test("ProviderBinding Codable round-trips toolChoiceModesOverride")
    func bindingCodableRoundTrip() throws {
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-test",
            serverURL: URL(string: "https://api.openai.com/v1")!,
            priority: 1,
            authProfile: "work",
            toolChoiceModesOverride: [.auto]
        )
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(ProviderBinding.self, from: data)
        #expect(decoded == binding)
    }

    @Test("ProviderBinding decodes absent toolChoiceModesOverride as nil")
    func bindingDecodesAbsentOverrideAsNil() throws {
        let json = """
        {
          "providerId": "openai",
          "modelProtocol": "openAIAPI",
          "endpointModelId": "gpt-test",
          "serverURL": "https://api.openai.com/v1/",
          "priority": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProviderBinding.self, from: json)
        #expect(decoded.toolChoiceModesOverride == nil)
    }

    @Test("makeBindingAdapter applies per-binding toolChoiceModes override")
    func factoryAppliesBindingOverride() async throws {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let model = Model(
            protocol: .openAIAPI,
            modelName: "gpt-test",
            serverURL: URL(string: "https://api.openai.com/v1")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI,
            requestFeatures: ModelManager.requestFeaturesBaseline(for: .openAIAPI)
        )
        let store = AuthProfileStore(environment: ["OPENAI_API_KEY": "test-key"])
        let restrictedBinding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-test",
            serverURL: URL(string: "https://api.openai.com/v1")!,
            toolChoiceModesOverride: [.auto]
        )
        let unrestrictedBinding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-test",
            serverURL: URL(string: "https://api.openai.com/v1")!
        )
        let restricted = StandardModelLLMFactory.makeBindingAdapter(
            binding: restrictedBinding,
            model: model,
            systemPrompt: prompt,
            logger: nil,
            authProfileStore: store
        )
        let unrestricted = StandardModelLLMFactory.makeBindingAdapter(
            binding: unrestrictedBinding,
            model: model,
            systemPrompt: prompt,
            logger: nil,
            authProfileStore: store
        )
        #expect(restricted.getRequestFeatures().toolChoiceModes == [.auto])
        #expect(unrestricted.getRequestFeatures().toolChoiceModes.contains(.required))

        let dummyTool = ToolDefinition(name: "finish", description: "", parameters: [], type: .function)
        let config = LLMRequestConfig(availableTools: [dummyTool], toolInvocationPolicy: .required)
        let restrictedEffective = ToolChoiceTranslation.effectivePolicy(
            config: config,
            features: restricted.getRequestFeatures(),
            hasTools: true,
            model: "gpt-test",
            logger: nil
        )
        let unrestrictedEffective = ToolChoiceTranslation.effectivePolicy(
            config: config,
            features: unrestricted.getRequestFeatures(),
            hasTools: true,
            model: "gpt-test",
            logger: nil
        )
        #expect(restrictedEffective == .automatic)
        #expect(unrestrictedEffective == .required)
        #expect(OpenAILLM.toolChoice(for: restrictedEffective) == nil)
        #expect(OpenAILLM.toolChoice(for: unrestrictedEffective) == .required)
    }
}
