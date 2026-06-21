//
//  Tool listing, baseline providers, and orchestrator-visible tool resolution.
//

import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator

enum OrchestrationToolCatalog {
    static func registryEntries(
        from descriptors: [RegisteredToolDescriptor],
        executionEnvironmentAdapter: any ToolExecutionEnvironmentAdapting = DefaultToolExecutionEnvironmentAdapter()
    ) -> [ToolRegistryEntry] {
        descriptors
            .map(ToolRegistryEntry.init(descriptor:))
            .map { entry in
                let resolved = executionEnvironmentAdapter.descriptor(for: entry)
                guard resolved != entry.executionEnvironment else { return entry }
                return entry.withExecutionEnvironment(resolved)
            }
            .sorted { $0.name < $1.name }
    }

    static func availableToolInfos(from entries: [ToolRegistryEntry]) -> [AvailableToolInfo] {
        entries
            .map(\.availableToolInfo)
            .sorted(by: availableToolInfoSort)
    }

    private static func availableToolInfoSort(_ lhs: AvailableToolInfo, _ rhs: AvailableToolInfo) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.source.rawValue != rhs.source.rawValue { return lhs.source.rawValue < rhs.source.rawValue }
        if lhs.description != rhs.description { return lhs.description < rhs.description }
        if lhs.normalizedSchemaFingerprint != rhs.normalizedSchemaFingerprint {
            return (lhs.normalizedSchemaFingerprint ?? "") < (rhs.normalizedSchemaFingerprint ?? "")
        }
        if lhs.normalizedSchemaVersion != rhs.normalizedSchemaVersion {
            return (lhs.normalizedSchemaVersion ?? "") < (rhs.normalizedSchemaVersion ?? "")
        }
        if lhs.normalizedTopLevelType != rhs.normalizedTopLevelType {
            return (lhs.normalizedTopLevelType ?? "") < (rhs.normalizedTopLevelType ?? "")
        }
        if lhs.normalizedRequiredCount != rhs.normalizedRequiredCount {
            return (lhs.normalizedRequiredCount ?? Int.min) < (rhs.normalizedRequiredCount ?? Int.min)
        }
        return (lhs.normalizedPropertyCount ?? Int.min) < (rhs.normalizedPropertyCount ?? Int.min)
    }

    /// Harness-owned tool providers only (conversations, plan, termination). Used when SwiftAgentKit reports an empty tool list until MCP/A2A wiring completes.
    static func baselineRegisteredToolDescriptorsFromLocalProviders(
        dataProvider: ConversationsDataProviding,
        logger: Logger?
    ) async -> [RegisteredToolDescriptor] {
        let conversations = ConversationsToolProvider(dataProvider: dataProvider, logger: logger)
        let plans = AgentPlanToolProvider(dataProvider: dataProvider, logger: logger)
        let terminations = TerminationToolProvider(dataProvider: dataProvider, logger: logger)
        var providers: [any ToolProvider] = [conversations, plans, terminations]
        if let transitionProvider = dataProvider as? any ModeTransitionDataProviding {
            providers.append(ModeTransitionToolProvider(dataProvider: transitionProvider, logger: logger))
        }
        let manager = ToolManager(providers: providers)
        return await manager.allRegisteredToolsAsync()
    }

    /// Canonical registered tool descriptors for an orchestrator turn.
    static func allRegisteredToolDescriptorsForOrchestration(
        orchestrator: SwiftAgentKitOrchestrator,
        dataProvider: ConversationsDataProviding,
        logger: Logger?
    ) async -> [RegisteredToolDescriptor] {
        var all = await orchestrator.allRegisteredTools
        if all.isEmpty {
            logger?.warning("[HarnessRuntimeSession] Orchestrator reported zero registered descriptors; using local provider baseline")
            all = await baselineRegisteredToolDescriptorsFromLocalProviders(dataProvider: dataProvider, logger: logger)
        }
        return all.sorted { $0.definition.name < $1.definition.name }
    }

    static func registryEntriesForListing(
        orchestrator: SwiftAgentKitOrchestrator?,
        dataProvider: ConversationsDataProviding,
        logger: Logger?,
        executionEnvironmentAdapter: any ToolExecutionEnvironmentAdapting = DefaultToolExecutionEnvironmentAdapter()
    ) async -> [ToolRegistryEntry] {
        if let orchestrator {
            let descriptors = await allRegisteredToolDescriptorsForOrchestration(
                orchestrator: orchestrator,
                dataProvider: dataProvider,
                logger: logger
            )
            return registryEntries(
                from: descriptors,
                executionEnvironmentAdapter: executionEnvironmentAdapter
            )
        }
        logger?.warning("[HarnessRuntimeSession] No orchestrator bound; using local provider baseline descriptors for listing")
        let fallback = await baselineRegisteredToolDescriptorsFromLocalProviders(
            dataProvider: dataProvider,
            logger: logger
        )
        return registryEntries(
            from: fallback,
            executionEnvironmentAdapter: executionEnvironmentAdapter
        )
    }

}
