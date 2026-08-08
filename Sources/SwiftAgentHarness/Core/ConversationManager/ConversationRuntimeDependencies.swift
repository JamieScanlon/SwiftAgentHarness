import Foundation
import Logging
import SwiftAgentKit

/// Shared infrastructure injected at the composition root and passed into runtime services during migration.
struct ConversationRuntimeDependencies {
    let persistenceDomain: ConversationPersistenceDomain
    let compactionCoordinator: CompactionConcurrencyCoordinator
    let contextEngine: any ContextEngine
    let contextAssemblyRuntime: ContextAssemblyRuntimeFacade
    let modeRegistry: any ModeRegistryAccessing
    let llmFactory: any ModelLLMFactoring
    /// Shared with `llmFactory`, so the turn loop can read the settled cost of a completion the
    /// budget gate priced. Defaulted in the initializer so the construction sites that do not care
    /// are untouched — but it has to be a *parameter*, not a property default: a property default
    /// would mint a fresh sink per dependency set, and the loop would read one the factory never
    /// writes to, silently falling back to catalog pricing forever.
    let modelCompletionSettlementSink: ModelCompletionSettlementSink
    let callScheduler: any ModelCallScheduling
    let invocationCoordinator: any ModelInvocationLifecycleTracking
    let runtimeLaneCoordinator: RuntimeLaneCoordinator
    /// Full PromptConfig snapshot for the session (parsed once at composition root).
    let configurationSet: HarnessConfigurationSet
    let toolPolicy: ToolPolicyConfiguration
    let trustPolicyConfiguration: TrustPolicyConfiguration
    let agentHarness: AgentHarnessConfiguration
    let thinkingPolicyConfiguration: ThinkingPolicyConfiguration
    let conversationTransformConfiguration: ConversationTransformConfiguration
    let conversationTransformer: any ConversationTransforming
    let registryEntryProvider: (@Sendable (UUID) async -> ModelRegistryEntry?)?
    let rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])?
    let delegateCostTracker: (any DelegateCostTracking)?
    let runtimeExecutorFactory: AgentRuntimeExecutorFactory
    let workspacePolicy: HarnessWorkspacePolicy
    /// Session-scoped host visibility grants (MCP / additional tool providers).
    let visibilityGrants: ToolVisibilityGrantStore
    let logger: Logger?

    init(
        persistenceDomain: ConversationPersistenceDomain,
        compactionCoordinator: CompactionConcurrencyCoordinator,
        contextEngine: any ContextEngine,
        contextAssemblyRuntime: ContextAssemblyRuntimeFacade,
        modeRegistry: any ModeRegistryAccessing,
        llmFactory: any ModelLLMFactoring,
        modelCompletionSettlementSink: ModelCompletionSettlementSink = ModelCompletionSettlementSink(),
        callScheduler: any ModelCallScheduling,
        invocationCoordinator: any ModelInvocationLifecycleTracking,
        runtimeLaneCoordinator: RuntimeLaneCoordinator,
        configurationSet: HarnessConfigurationSet = .lockedDownBaseline,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicyConfiguration: TrustPolicyConfiguration,
        agentHarness: AgentHarnessConfiguration,
        thinkingPolicyConfiguration: ThinkingPolicyConfiguration,
        conversationTransformConfiguration: ConversationTransformConfiguration,
        conversationTransformer: any ConversationTransforming,
        registryEntryProvider: (@Sendable (UUID) async -> ModelRegistryEntry?)?,
        rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])?,
        delegateCostTracker: (any DelegateCostTracking)?,
        runtimeExecutorFactory: @escaping AgentRuntimeExecutorFactory,
        workspacePolicy: HarnessWorkspacePolicy = .default,
        visibilityGrants: ToolVisibilityGrantStore = ToolVisibilityGrantStore(),
        logger: Logger?
    ) {
        self.persistenceDomain = persistenceDomain
        self.compactionCoordinator = compactionCoordinator
        self.contextEngine = contextEngine
        self.contextAssemblyRuntime = contextAssemblyRuntime
        self.modeRegistry = modeRegistry
        self.llmFactory = llmFactory
        self.modelCompletionSettlementSink = modelCompletionSettlementSink
        self.callScheduler = callScheduler
        self.invocationCoordinator = invocationCoordinator
        self.runtimeLaneCoordinator = runtimeLaneCoordinator
        self.configurationSet = configurationSet
        self.toolPolicy = toolPolicy
        self.trustPolicyConfiguration = trustPolicyConfiguration
        self.agentHarness = agentHarness
        self.thinkingPolicyConfiguration = thinkingPolicyConfiguration
        self.conversationTransformConfiguration = conversationTransformConfiguration
        self.conversationTransformer = conversationTransformer
        self.registryEntryProvider = registryEntryProvider
        self.rankedRegistryEntriesProvider = rankedRegistryEntriesProvider
        self.delegateCostTracker = delegateCostTracker
        self.runtimeExecutorFactory = runtimeExecutorFactory
        self.workspacePolicy = workspacePolicy
        self.visibilityGrants = visibilityGrants
        self.logger = logger
    }
}
