import Foundation
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("SystemPromptLayerAssembly")
struct SystemPromptLayerAssemblyTests {

    private func neutralProfile() -> ResolvedModeProfile {
        ResolvedModeProfile(
            id: InteractionMode.chat.rawValue,
            interactionMode: .chat,
            assemblyKind: .chat,
            allowsProactiveCompactionTriggers: true,
            appliesAgentBuildOrchestratorHarness: false,
            builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
            semanticLayerTags: []
        )
    }

    private func neutralPolicy(provider: SystemPromptContribution? = nil) -> ContextEngineSystemPromptAssemblyPolicyInput {
        ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: neutralProfile(),
            strictAgentHarnessPrompts: false,
            includeAgentSkills: false,
            includeDateTime: false,
            toolPolicySignature: "sig",
            routingPolicyTools: [],
            routingPolicySkills: [],
            providerContribution: provider
        )
    }

    @Test("Anthropic claude-sonnet family catalog overlay resolves")
    func anthropicFamilyContribution() {
        ProviderTestManifestSupport.activateProviderResources()
        let binding = ProviderBinding(
            providerId: "anthropic",
            modelProtocol: .anthropic,
            endpointModelId: "claude-sonnet-4-6",
            serverURL: URL(string: "https://api.anthropic.com")!
        )
        let wire = ProviderRuntimeHooks.systemPromptContribution(binding: binding)
        let typed = ProviderPromptContribution.systemPromptContribution(from: wire)
        #expect(typed != nil)
        #expect(typed?.stablePrefix?.contains("Claude Sonnet") == true)
        #expect(typed?.sectionOverrides[SystemPromptSectionName.toolGuidance]?.contains("Batch independent reads") == true)
    }

    @Test("OpenAI gpt-4.1 family catalog overlay resolves")
    func openAIFamilyContribution() {
        ProviderTestManifestSupport.activateProviderResources()
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-4.1",
            serverURL: URL(string: "https://api.openai.com")!
        )
        let wire = ProviderRuntimeHooks.systemPromptContribution(binding: binding)
        let typed = ProviderPromptContribution.systemPromptContribution(from: wire)
        #expect(typed?.sectionOverrides[SystemPromptSectionName.toolGuidance]?.contains("strict JSON tool arguments") == true)
    }

    @Test("Workspace instructions land in personality, not memory tier-1")
    func workspacePersonalitySplit() {
        let blocks = MemorySystemPromptBlocks(
            projectInstructionsText: "Follow the project style guide.",
            memoryIndexText: "index: topics/foo.md",
            recalledTopicBodiesText: "",
            taxonomyPromptText: "",
            driftGuardText: "",
            sensitiveDataPromptText: "",
            memoryPathDisclosureText: "",
            snapshotGeneration: 3
        )
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: ""
        )
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: nil,
            memoryBlocks: blocks,
            memorySnapshotGeneration: 3,
            modeMemoryInjection: "on"
        )
        #expect(bundle.memorySlice.workspaceContent?.contains("style guide") == true)
        #expect(bundle.memorySlice.tier1Content?.contains("style guide") == false)
        #expect(bundle.memorySlice.tier1Content?.contains("index: topics/foo.md") == true)
        let workspace = bundle.contributions.first { $0.source == .workspace }
        #expect(workspace?.sectionOverrides[.personality]?.contains("style guide") == true)
        let memory = bundle.contributions.first { $0.source == .memory }
        #expect(memory?.sectionOverrides[.memory]?.contains("style guide") == false)
        #expect(memory?.sectionOverrides[.memory]?.contains("index: topics/foo.md") == true)
    }

    @Test("Conversation extraInstructions appear in Additional Requirements")
    func conversationExtraInstructions() async throws {
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "",
            extraInstructions: "Always cite sources."
        )
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "User override line",
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on"
        )
        let conversationLayer = bundle.contributions.first { $0.source == .conversation }
        let directive = try #require(conversationLayer?.sectionDirectives[.extraInstructions])
        #expect(directive.contains("Always cite sources."))
        #expect(directive.contains("User override line"))

        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let text = try await renderer.render(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "User override line",
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: Date(),
            fullOverrideText: bundle.fullOverrideText
        )
        #expect(text.contains("Always cite sources."))
        #expect(text.contains("User override line"))
        #expect(text.contains("# Additional Requirements"))
    }

    @Test("systemPromptFullOverride bypasses section assembly")
    func fullOverrideShortCircuit() async throws {
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "Canonical only",
            systemPromptFullOverride: true
        )
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Canonical only",
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on"
        )
        #expect(bundle.fullOverrideText == "Canonical only")
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let text = try await renderer.render(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Canonical only",
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: Date(),
            fullOverrideText: bundle.fullOverrideText
        )
        #expect(text == "Canonical only")
        #expect(text.contains("# Constraints") == false)
    }

    @Test("Workspace and memory layers resolve to distinct sections")
    func workspaceBeforeMemoryResolverOrder() throws {
        let workspace = SystemPromptContribution(
            source: .workspace,
            sectionOverrides: [.personality: "workspace personality"]
        )
        let memory = SystemPromptContribution(
            source: .memory,
            sectionOverrides: [.memory: "memory body"]
        )
        let resolution = try SystemPromptContributionResolver.resolve(contributions: [workspace, memory])
        #expect(resolution.resolved.sectionOverrides[.personality] == "workspace personality")
        #expect(resolution.resolved.sectionOverrides[.memory] == "memory body")
        #expect(resolution.resolved.provenance[.personality] == .workspace)
        #expect(resolution.resolved.provenance[.memory] == .memory)
    }

    @Test("Engine dynamic addition wires through collector")
    func engineDynamicAddition() {
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: ""
        )
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: nil,
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on",
            engineDynamicAddition: "Recall hint for this turn."
        )
        let engineLayer = bundle.contributions.first { $0.source == .engine }
        #expect(engineLayer?.sectionDirectives[.dynamicAdditions] == "Recall hint for this turn.")
    }

    @Test("omitWorkspaceConventions skips workspace contribution")
    func omitWorkspaceConventions() {
        var profile = neutralProfile()
        profile.context.omitWorkspaceConventions = true
        let policy = ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: profile,
            strictAgentHarnessPrompts: false,
            includeAgentSkills: false,
            includeDateTime: false,
            toolPolicySignature: "sig",
            routingPolicyTools: [],
            routingPolicySkills: []
        )
        let blocks = MemorySystemPromptBlocks(
            projectInstructionsText: "Hidden workspace text",
            memoryIndexText: "visible index",
            recalledTopicBodiesText: "",
            taxonomyPromptText: "",
            driftGuardText: "",
            sensitiveDataPromptText: "",
            memoryPathDisclosureText: "",
            snapshotGeneration: 1
        )
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: ""
        )
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: policy,
            userSystemPrompt: nil,
            memoryBlocks: blocks,
            memorySnapshotGeneration: 1,
            modeMemoryInjection: "on"
        )
        #expect(bundle.contributions.contains { $0.source == .workspace } == false)
        #expect(bundle.memorySlice.workspaceContent == nil)
    }
}
