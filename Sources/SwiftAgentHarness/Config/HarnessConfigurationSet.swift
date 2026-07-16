import Foundation
import Logging

/// Immutable snapshot of every PromptConfig-derived section used to build a harness session.
public struct HarnessConfigurationSet: Sendable {
    public var promptAssembly: PromptAssemblyConfiguration
    public var agentHarness: AgentHarnessConfiguration
    public var toolPolicy: ToolPolicyConfiguration
    public var subAgentHostingPolicy: SubAgentHostingPolicyConfiguration
    public var trustPolicy: TrustPolicyConfiguration
    public var thinkingPolicy: ThinkingPolicyConfiguration
    public var conversationTransforms: ConversationTransformConfiguration
    public var modeProfiles: ModeProfileConfiguration
    public var memory: MemoryConfiguration
    public var skillWorkshop: SkillWorkshopConfiguration
    public var publishingGovernance: PublishingGovernanceConfiguration
    public var modelPoolBudget: ModelPoolBudgetConfiguration
    public var modelPoolFailover: ModelPoolFailoverConfiguration
    public var modelPoolProviderPreference: ModelPoolProviderPreferenceConfiguration
    public var subAgentCustomEndpoint: SubAgentCustomEndpointConfiguration

    /// Compiled-in locked-down baseline when no host document is supplied.
    public static let lockedDownBaseline = HarnessConfigurationSet(
        promptAssembly: .default,
        agentHarness: .default,
        toolPolicy: .unrestricted,
        subAgentHostingPolicy: .empty,
        trustPolicy: .disabled,
        thinkingPolicy: .default,
        conversationTransforms: .default,
        modeProfiles: .empty,
        memory: .default,
        skillWorkshop: .default,
        publishingGovernance: .defaultStrict,
        modelPoolBudget: .safeDefaults,
        modelPoolFailover: .specDefaults,
        modelPoolProviderPreference: .specDefaults,
        subAgentCustomEndpoint: .empty
    )

    public init(
        promptAssembly: PromptAssemblyConfiguration,
        agentHarness: AgentHarnessConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        subAgentHostingPolicy: SubAgentHostingPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        thinkingPolicy: ThinkingPolicyConfiguration,
        conversationTransforms: ConversationTransformConfiguration,
        modeProfiles: ModeProfileConfiguration,
        memory: MemoryConfiguration,
        skillWorkshop: SkillWorkshopConfiguration,
        publishingGovernance: PublishingGovernanceConfiguration,
        modelPoolBudget: ModelPoolBudgetConfiguration,
        modelPoolFailover: ModelPoolFailoverConfiguration,
        modelPoolProviderPreference: ModelPoolProviderPreferenceConfiguration,
        subAgentCustomEndpoint: SubAgentCustomEndpointConfiguration
    ) {
        self.promptAssembly = promptAssembly
        self.agentHarness = agentHarness
        self.toolPolicy = toolPolicy
        self.subAgentHostingPolicy = subAgentHostingPolicy
        self.trustPolicy = trustPolicy
        self.thinkingPolicy = thinkingPolicy
        self.conversationTransforms = conversationTransforms
        self.modeProfiles = modeProfiles
        self.memory = memory
        self.skillWorkshop = skillWorkshop
        self.publishingGovernance = publishingGovernance
        self.modelPoolBudget = modelPoolBudget
        self.modelPoolFailover = modelPoolFailover
        self.modelPoolProviderPreference = modelPoolProviderPreference
        self.subAgentCustomEndpoint = subAgentCustomEndpoint
    }

    /// Runs each section loader against a single parsed document (no ambient re-reads).
    public static func load(from document: PromptConfigDocument, logger: Logger? = nil) -> HarnessConfigurationSet {
        let toolPolicy = ToolPolicyConfiguration.load(from: document, logger: logger)
        return HarnessConfigurationSet(
            promptAssembly: PromptAssemblyConfiguration.load(from: document),
            agentHarness: AgentHarnessConfiguration.load(from: document, logger: logger),
            toolPolicy: toolPolicy,
            subAgentHostingPolicy: SubAgentHostingPolicyConfiguration.load(from: document, logger: logger),
            trustPolicy: TrustPolicyConfiguration.load(from: document, logger: logger),
            thinkingPolicy: ThinkingPolicyConfiguration.load(from: document, logger: logger),
            conversationTransforms: ConversationTransformConfiguration.load(from: document, logger: logger),
            modeProfiles: ModeProfileConfiguration.load(from: document),
            memory: MemoryConfigurationLoader.load(from: document, logger: logger),
            skillWorkshop: SkillWorkshopConfigurationLoader.load(from: document, logger: logger),
            publishingGovernance: PublishingGovernanceConfiguration.load(from: document, logger: logger),
            modelPoolBudget: ModelPoolBudgetConfiguration.load(from: document, logger: logger),
            modelPoolFailover: ModelPoolFailoverConfiguration.load(from: document, logger: logger),
            modelPoolProviderPreference: ModelPoolProviderPreferenceConfiguration.load(from: document, logger: logger),
            subAgentCustomEndpoint: SubAgentCustomEndpointConfiguration.load(from: document, logger: logger)
        )
    }

    /// Resolves ambient PromptConfig bytes once, then materializes the full set.
    public static func resolveFromAmbient(logger: Logger? = nil) -> HarnessConfigurationSet {
        guard let data = PromptConfigBundleResource.data() else {
            logger?.warning("PromptConfig.json not found; using locked-down baseline")
            return .lockedDownBaseline
        }
        do {
            let document = try PromptConfigDocument.parse(data: data, logger: logger)
            return load(from: document, logger: logger)
        } catch {
            logger?.warning("PromptConfig.json failed to parse; using locked-down baseline (\(error))")
            return .lockedDownBaseline
        }
    }

    /// Compact snapshot for system-prompt assembly replay records.
    public var promptAssemblyConfigSnapshot: PromptAssemblyConfigSnapshot {
        PromptAssemblyConfigSnapshot(from: self)
    }

    /// Overlay of composition-root section values onto the locked-down baseline.
    public static func assembling(
        promptAssembly: PromptAssemblyConfiguration? = nil,
        agentHarness: AgentHarnessConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        subAgentHostingPolicy: SubAgentHostingPolicyConfiguration? = nil,
        trustPolicy: TrustPolicyConfiguration,
        thinkingPolicy: ThinkingPolicyConfiguration,
        conversationTransforms: ConversationTransformConfiguration,
        modeProfiles: ModeProfileConfiguration? = nil,
        memory: MemoryConfiguration? = nil,
        skillWorkshop: SkillWorkshopConfiguration? = nil,
        publishingGovernance: PublishingGovernanceConfiguration? = nil,
        modelPoolBudget: ModelPoolBudgetConfiguration? = nil,
        modelPoolFailover: ModelPoolFailoverConfiguration? = nil,
        modelPoolProviderPreference: ModelPoolProviderPreferenceConfiguration? = nil,
        subAgentCustomEndpoint: SubAgentCustomEndpointConfiguration? = nil
    ) -> HarnessConfigurationSet {
        var set = lockedDownBaseline
        if let promptAssembly { set.promptAssembly = promptAssembly }
        set.agentHarness = agentHarness
        set.toolPolicy = toolPolicy
        if let subAgentHostingPolicy { set.subAgentHostingPolicy = subAgentHostingPolicy }
        set.trustPolicy = trustPolicy
        set.thinkingPolicy = thinkingPolicy
        set.conversationTransforms = conversationTransforms
        if let modeProfiles { set.modeProfiles = modeProfiles }
        if let memory { set.memory = memory }
        if let skillWorkshop { set.skillWorkshop = skillWorkshop }
        if let publishingGovernance { set.publishingGovernance = publishingGovernance }
        if let modelPoolBudget { set.modelPoolBudget = modelPoolBudget }
        if let modelPoolFailover { set.modelPoolFailover = modelPoolFailover }
        if let modelPoolProviderPreference { set.modelPoolProviderPreference = modelPoolProviderPreference }
        if let subAgentCustomEndpoint { set.subAgentCustomEndpoint = subAgentCustomEndpoint }
        return set
    }
}

extension HarnessConfigurationSet {
    /// Fluent host-facing construction starting from ``lockedDownBaseline`` (or a caller-supplied base).
    ///
    /// Prefer typed section injection over ambient JSON.
    public struct Builder: Sendable {
        private var set: HarnessConfigurationSet

        public init(base: HarnessConfigurationSet = .lockedDownBaseline) {
            self.set = base
        }

        public func withPromptAssembly(_ value: PromptAssemblyConfiguration) -> Builder {
            var copy = self
            copy.set.promptAssembly = value
            return copy
        }

        public func withAgentHarness(_ value: AgentHarnessConfiguration) -> Builder {
            var copy = self
            copy.set.agentHarness = value
            return copy
        }

        public func withToolPolicy(_ value: ToolPolicyConfiguration) -> Builder {
            var copy = self
            copy.set.toolPolicy = value
            return copy
        }

        public func withSubAgentHostingPolicy(_ value: SubAgentHostingPolicyConfiguration) -> Builder {
            var copy = self
            copy.set.subAgentHostingPolicy = value
            return copy
        }

        public func withTrustPolicy(_ value: TrustPolicyConfiguration) -> Builder {
            var copy = self
            copy.set.trustPolicy = value
            return copy
        }

        public func withThinkingPolicy(_ value: ThinkingPolicyConfiguration) -> Builder {
            var copy = self
            copy.set.thinkingPolicy = value
            return copy
        }

        public func withConversationTransforms(_ value: ConversationTransformConfiguration) -> Builder {
            var copy = self
            copy.set.conversationTransforms = value
            return copy
        }

        public func withModeProfiles(_ value: ModeProfileConfiguration) -> Builder {
            var copy = self
            copy.set.modeProfiles = value
            return copy
        }

        public func withMemory(_ value: MemoryConfiguration) -> Builder {
            var copy = self
            copy.set.memory = value
            return copy
        }

        public func withSkillWorkshop(_ value: SkillWorkshopConfiguration) -> Builder {
            var copy = self
            copy.set.skillWorkshop = value
            return copy
        }

        public func withPublishingGovernance(_ value: PublishingGovernanceConfiguration) -> Builder {
            var copy = self
            copy.set.publishingGovernance = value
            return copy
        }

        public func withModelPoolBudget(_ value: ModelPoolBudgetConfiguration) -> Builder {
            var copy = self
            copy.set.modelPoolBudget = value
            return copy
        }

        public func withModelPoolFailover(_ value: ModelPoolFailoverConfiguration) -> Builder {
            var copy = self
            copy.set.modelPoolFailover = value
            return copy
        }

        public func withModelPoolProviderPreference(_ value: ModelPoolProviderPreferenceConfiguration) -> Builder {
            var copy = self
            copy.set.modelPoolProviderPreference = value
            return copy
        }

        public func withSubAgentCustomEndpoint(_ value: SubAgentCustomEndpointConfiguration) -> Builder {
            var copy = self
            copy.set.subAgentCustomEndpoint = value
            return copy
        }

        /// Replace public sections by loading a parsed PromptConfig document (internal sections included).
        public func withDocument(_ document: PromptConfigDocument, logger: Logger? = nil) -> Builder {
            Builder(base: HarnessConfigurationSet.load(from: document, logger: logger))
        }

        public func build() -> HarnessConfigurationSet {
            set
        }
    }
}
