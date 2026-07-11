import Foundation
import SwiftAgentKit

public enum PromptCacheBreakpointKind: String, Sendable, Equatable, Codable {
    case stableSystemPrefixEnd
    case toolSchemasEnd
    case rollingConversation
}

public struct PromptCacheBreakpointCandidate: Sendable, Equatable {
    public let kind: PromptCacheBreakpointKind
    public let estimatedPrefixTokens: Int
    public let inclusiveMessageIndex: Int?
    public let stableSystemPrefixCharacters: Int?

    public init(
        kind: PromptCacheBreakpointKind,
        estimatedPrefixTokens: Int,
        inclusiveMessageIndex: Int? = nil,
        stableSystemPrefixCharacters: Int? = nil
    ) {
        self.kind = kind
        self.estimatedPrefixTokens = estimatedPrefixTokens
        self.inclusiveMessageIndex = inclusiveMessageIndex
        self.stableSystemPrefixCharacters = stableSystemPrefixCharacters
    }
}

public struct ProviderPromptCacheBreakpointContext: Sendable {
    public let binding: ProviderBinding
    public let capabilities: [LLMCapability]
    public let cacheTtlEligibility: ProviderCacheTTLEligibility
    public let strategy: PromptCacheStrategy
    public let messages: [Message]

    public init(
        binding: ProviderBinding,
        capabilities: [LLMCapability],
        cacheTtlEligibility: ProviderCacheTTLEligibility,
        strategy: PromptCacheStrategy,
        messages: [Message]
    ) {
        self.binding = binding
        self.capabilities = capabilities
        self.cacheTtlEligibility = cacheTtlEligibility
        self.strategy = strategy
        self.messages = messages
    }
}

public struct ProviderPromptCacheBreakpointPlan: Sendable, Equatable {
    public let breakpoints: [PromptCacheBreakpointCandidate]
    public let mode: PromptCacheMode
    public let stablePrefixMessageCount: Int?
    public let stablePrefixTokenEstimate: Int?

    public init(
        breakpoints: [PromptCacheBreakpointCandidate],
        mode: PromptCacheMode,
        stablePrefixMessageCount: Int? = nil,
        stablePrefixTokenEstimate: Int? = nil
    ) {
        self.breakpoints = breakpoints
        self.mode = mode
        self.stablePrefixMessageCount = stablePrefixMessageCount
        self.stablePrefixTokenEstimate = stablePrefixTokenEstimate
    }

    public static let empty = ProviderPromptCacheBreakpointPlan(
        breakpoints: [],
        mode: .none,
        stablePrefixMessageCount: nil,
        stablePrefixTokenEstimate: nil
    )
}
