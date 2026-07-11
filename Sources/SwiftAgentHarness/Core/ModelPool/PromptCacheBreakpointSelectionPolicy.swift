import Foundation
import SwiftAgentKit

public enum PromptCacheBreakpointSelectionPolicy {
    static let stableSystemMinimumTokens = 1024
    static let toolSchemasCombinedMinimumTokens = 1024
    static let rollingConversationMinimumTokens = 2048
    static let persistentStableSystemMinimumTokens = 3000

    public static func anthropic(
        candidates: [PromptCacheBreakpointCandidate],
        context: ProviderPromptCacheBreakpointContext
    ) -> ProviderPromptCacheBreakpointPlan {
        selectExplicit(
            candidates: candidates,
            context: context,
            includeToolSchemas: true,
            includeRolling: true
        )
    }

    public static func lmStudio(
        candidates: [PromptCacheBreakpointCandidate],
        context: ProviderPromptCacheBreakpointContext
    ) -> ProviderPromptCacheBreakpointPlan {
        selectExplicit(
            candidates: candidates,
            context: context,
            stableSystemMinimumTokens: 4,
            toolSchemasCombinedMinimumTokens: 16,
            rollingConversationMinimumTokens: 32,
            persistentStableSystemMinimumTokens: 3000,
            includeToolSchemas: false,
            includeRolling: true
        )
    }

    public static func implicit(
        candidates: [PromptCacheBreakpointCandidate],
        context: ProviderPromptCacheBreakpointContext
    ) -> ProviderPromptCacheBreakpointPlan {
        let _ = (candidates, context)
        return .empty
    }

    private static func selectExplicit(
        candidates: [PromptCacheBreakpointCandidate],
        context: ProviderPromptCacheBreakpointContext,
        stableSystemMinimumTokens: Int = Self.stableSystemMinimumTokens,
        toolSchemasCombinedMinimumTokens: Int = Self.toolSchemasCombinedMinimumTokens,
        rollingConversationMinimumTokens: Int = Self.rollingConversationMinimumTokens,
        persistentStableSystemMinimumTokens: Int = Self.persistentStableSystemMinimumTokens,
        includeToolSchemas: Bool,
        includeRolling: Bool
    ) -> ProviderPromptCacheBreakpointPlan {
        let capabilities = Set(context.capabilities)
        let supportsPersistent = capabilities.contains(.promptCachePersistent)
        let supportsEphemeral = supportsPersistent || capabilities.contains(.promptCacheEphemeral)
        guard supportsEphemeral else { return .empty }

        var selected: [PromptCacheBreakpointCandidate] = []

        if let stable = candidates.first(where: { $0.kind == .stableSystemPrefixEnd }),
           stable.estimatedPrefixTokens >= stableSystemMinimumTokens {
            selected.append(stable)
        }

        if includeToolSchemas,
           !selected.isEmpty,
           let tools = candidates.first(where: { $0.kind == .toolSchemasEnd }),
           tools.estimatedPrefixTokens >= toolSchemasCombinedMinimumTokens {
            selected.append(tools)
        }

        if includeRolling,
           let rolling = candidates.first(where: { $0.kind == .rollingConversation }),
           rolling.estimatedPrefixTokens >= rollingConversationMinimumTokens {
            selected.append(rolling)
        }

        guard !selected.isEmpty else { return .empty }

        let stableTokens = selected.first(where: { $0.kind == .stableSystemPrefixEnd })?.estimatedPrefixTokens ?? 0
        let mode: PromptCacheMode = {
            switch context.strategy {
            case .automatic:
                if supportsPersistent && stableTokens >= persistentStableSystemMinimumTokens {
                    return .persistent
                }
                return .ephemeral
            case .conservative:
                return .ephemeral
            }
        }()

        var messageCount = PromptCacheBreakpointCandidates.derivedStablePrefixMessageCount(
            messages: context.messages,
            breakpoints: selected,
            strategy: context.strategy
        )
        if messageCount == nil, let maxIndex = selected.compactMap(\.inclusiveMessageIndex).max() {
            messageCount = PromptCacheBreakpointCandidates.derivedStablePrefixMessageCount(
                messages: context.messages,
                breakpoints: [
                    PromptCacheBreakpointCandidate(
                        kind: .rollingConversation,
                        estimatedPrefixTokens: 0,
                        inclusiveMessageIndex: maxIndex
                    )
                ],
                strategy: context.strategy
            )
        }

        return ProviderPromptCacheBreakpointPlan(
            breakpoints: selected,
            mode: mode,
            stablePrefixMessageCount: messageCount,
            stablePrefixTokenEstimate: PromptCacheBreakpointCandidates.stablePrefixTokenEstimate(from: selected)
        )
    }
}
