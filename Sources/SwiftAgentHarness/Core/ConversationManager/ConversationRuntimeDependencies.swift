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
    let callScheduler: any ModelCallScheduling
    let invocationCoordinator: any ModelInvocationLifecycleTracking
    let runtimeLaneCoordinator: RuntimeLaneCoordinator
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
    let logger: Logger?

    init(
        persistenceDomain: ConversationPersistenceDomain,
        compactionCoordinator: CompactionConcurrencyCoordinator,
        contextEngine: any ContextEngine,
        contextAssemblyRuntime: ContextAssemblyRuntimeFacade,
        modeRegistry: any ModeRegistryAccessing,
        llmFactory: any ModelLLMFactoring,
        callScheduler: any ModelCallScheduling,
        invocationCoordinator: any ModelInvocationLifecycleTracking,
        runtimeLaneCoordinator: RuntimeLaneCoordinator,
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
        logger: Logger?
    ) {
        self.persistenceDomain = persistenceDomain
        self.compactionCoordinator = compactionCoordinator
        self.contextEngine = contextEngine
        self.contextAssemblyRuntime = contextAssemblyRuntime
        self.modeRegistry = modeRegistry
        self.llmFactory = llmFactory
        self.callScheduler = callScheduler
        self.invocationCoordinator = invocationCoordinator
        self.runtimeLaneCoordinator = runtimeLaneCoordinator
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
        self.logger = logger
    }
}
