import EasyJSON
import Foundation
import SwiftAgentKit

enum PromptCacheExpectsReadGate {
    static func evaluate(
        plan: PromptCachePlan,
        lastLLMDate: Date?,
        binding: ProviderBinding,
        referenceInstant: Date,
        messages: [Message]
    ) -> Bool {
        guard plan.mode != .none else { return false }
        guard let lastLLMDate else { return false }
        guard hasPriorConversationTurn(messages: messages) else { return false }

        let eligibility = ProviderRuntimeHooks.cacheTtlEligibility(binding: binding)
        guard let ttl = ttlSeconds(for: eligibility), ttl > 0 else { return false }
        return referenceInstant.timeIntervalSince(lastLLMDate) < ttl
    }

    private static func hasPriorConversationTurn(messages: [Message]) -> Bool {
        for message in messages {
            if HarnessInjectedMessageMetadata.isHarnessInjected(message) {
                continue
            }
            if message.role == .assistant || message.role == .tool {
                return true
            }
        }
        return false
    }

    private static func ttlSeconds(for eligibility: ProviderCacheTTLEligibility) -> Double? {
        switch eligibility {
        case .none:
            return nil
        case .short:
            return 300
        case .long:
            return 3600
        }
    }
}

enum PromptCacheDispatchMetadataKeys {
    static let lastLLMDateISO = "promptCacheLastLLMDateISO"
}

enum PromptCachePlanningMetadata {
    static func lastLLMDate(from additionalParameters: JSON?) -> Date? {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              case .string(let iso)? = root[PromptCacheDispatchMetadataKeys.lastLLMDateISO]
        else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }
}
