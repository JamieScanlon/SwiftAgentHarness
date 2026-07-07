import Foundation
import SwiftAgentKit

public enum ProviderThinkingReplayAction: String, Sendable, Equatable, Codable {
    case preserveSignedThinking
    case convertToReasoningText
    case drop
}

public struct ProviderReplayPolicy: Sendable, Equatable {
    public var foreignThinkingBlock: ProviderThinkingReplayAction
    public var foreignThinkingWithoutSignature: ProviderThinkingReplayAction
    public var inlineThinkingTags: ProviderThinkingReplayAction

    public init(
        foreignThinkingBlock: ProviderThinkingReplayAction = .drop,
        foreignThinkingWithoutSignature: ProviderThinkingReplayAction = .drop,
        inlineThinkingTags: ProviderThinkingReplayAction = .convertToReasoningText
    ) {
        self.foreignThinkingBlock = foreignThinkingBlock
        self.foreignThinkingWithoutSignature = foreignThinkingWithoutSignature
        self.inlineThinkingTags = inlineThinkingTags
    }

    public static let conservativeDropForeign = ProviderReplayPolicy()

    public static let anthropicTarget = ProviderReplayPolicy(
        foreignThinkingBlock: .preserveSignedThinking,
        foreignThinkingWithoutSignature: .drop,
        inlineThinkingTags: .drop
    )

    public static let openAICompatTarget = ProviderReplayPolicy(
        foreignThinkingBlock: .convertToReasoningText,
        foreignThinkingWithoutSignature: .drop,
        inlineThinkingTags: .convertToReasoningText
    )

    public static let ollamaTarget = ProviderReplayPolicy(
        foreignThinkingBlock: .drop,
        foreignThinkingWithoutSignature: .drop,
        inlineThinkingTags: .convertToReasoningText
    )
}

public struct ProviderReplayValidationIssue: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable, Codable {
        case warning
        case error
    }

    public var severity: Severity
    public var code: String
    public var message: String

    public init(severity: Severity, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }
}

public struct ProviderMessageTransformContext: Sendable {
    public var binding: ProviderBinding
    public var compat: ProviderModelCompat?
    public var targetCapabilities: Set<LLMCapability>

    public init(
        binding: ProviderBinding,
        compat: ProviderModelCompat? = nil,
        targetCapabilities: Set<LLMCapability> = []
    ) {
        self.binding = binding
        self.compat = compat
        self.targetCapabilities = targetCapabilities
    }
}

public struct ProviderDynamicPrepareContext: Sendable {
    public var binding: ProviderBinding
    public var catalogEntry: ProviderCatalogEntry

    public init(binding: ProviderBinding, catalogEntry: ProviderCatalogEntry) {
        self.binding = binding
        self.catalogEntry = catalogEntry
    }
}

public struct ProviderReplayTurnContext: Sendable {
    public var binding: ProviderBinding
    public var compat: ProviderModelCompat?
    public var targetCapabilities: Set<LLMCapability>

    public init(
        binding: ProviderBinding,
        compat: ProviderModelCompat? = nil,
        targetCapabilities: Set<LLMCapability> = []
    ) {
        self.binding = binding
        self.compat = compat
        self.targetCapabilities = targetCapabilities
    }
}

public struct ProviderDynamicModelPreferenceContext: Sendable {
    public var binding: ProviderBinding
    public var endpointModelId: String

    public init(binding: ProviderBinding, endpointModelId: String) {
        self.binding = binding
        self.endpointModelId = endpointModelId
    }
}

enum ProviderMessageReplayTransformer {
    static func defaultReplayPolicy(for context: ProviderMessageTransformContext) -> ProviderReplayPolicy {
        if context.compat?.thinkingFormat == "anthropic-extended-thinking"
            || context.binding.providerId == "anthropic" {
            return .anthropicTarget
        }
        switch context.binding.providerId {
        case "ollama":
            return .ollamaTarget
        default:
            return .openAICompatTarget
        }
    }

    static func transform(
        _ messages: [Message],
        envelopes: [UUID: HarnessMessageEnvelope],
        policy: ProviderReplayPolicy,
        context: ProviderMessageTransformContext
    ) -> [Message] {
        messages.map { message in
            guard message.role == .assistant else { return message }
            let envelope = envelopes[message.id] ?? HarnessMessageEnvelope(message: message)
            return flatten(envelope: envelope, policy: policy, context: context)
        }
    }

    static func validate(
        _ messages: [Message],
        envelopes: [UUID: HarnessMessageEnvelope],
        context: ProviderReplayTurnContext
    ) -> [ProviderReplayValidationIssue] {
        var issues: [ProviderReplayValidationIssue] = []
        let supportsAnthropicThinking = context.compat?.thinkingFormat == "anthropic-extended-thinking"
            || context.binding.providerId == "anthropic"
        guard supportsAnthropicThinking else { return issues }

        for message in messages where message.role == .assistant {
            let envelope = envelopes[message.id] ?? HarnessMessageEnvelope(message: message)
            for block in envelope.contentBlocks {
                guard case .thinking(let text, let signature) = block else { continue }
                if signature == nil || signature?.isEmpty == true {
                    issues.append(
                        ProviderReplayValidationIssue(
                            severity: .warning,
                            code: "unsigned_thinking_dropped",
                            message: "Assistant message \(message.id) has unsigned thinking block; may be dropped on replay to \(context.binding.providerId)"
                        )
                    )
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(
                        ProviderReplayValidationIssue(
                            severity: .warning,
                            code: "empty_thinking_block",
                            message: "Assistant message \(message.id) has empty thinking block"
                        )
                    )
                }
            }
        }
        return issues
    }

    private static func flatten(
        envelope: HarnessMessageEnvelope,
        policy: ProviderReplayPolicy,
        context: ProviderMessageTransformContext
    ) -> Message {
        var textParts: [String] = []
        var toolCalls = envelope.message.toolCalls

        if envelope.contentBlocks.isEmpty {
            return applyInlineTagPolicy(to: envelope.message, policy: policy)
        }

        let isAnthropicTarget = context.compat?.thinkingFormat == "anthropic-extended-thinking"
            || context.binding.providerId == "anthropic"

        for block in envelope.contentBlocks {
            switch block {
            case .text(let text):
                if !text.isEmpty { textParts.append(text) }
            case .thinking(let text, let signature):
                let action = thinkingAction(
                    signature: signature,
                    isAnthropicTarget: isAnthropicTarget,
                    policy: policy
                )
                switch action {
                case .preserveSignedThinking:
                    if !text.isEmpty { textParts.append(text) }
                case .convertToReasoningText:
                    if !text.isEmpty { textParts.append(text) }
                case .drop:
                    break
                }
            case .toolUse(let id, let name):
                let _ = (id, name)
            }
        }

        var content = textParts.joined()
        if content.isEmpty {
            content = envelope.message.content
        }
        content = stripInlineThinkingTags(from: content, policy: policy)

        return Message(
            id: envelope.message.id,
            role: envelope.message.role,
            content: content,
            timestamp: envelope.message.timestamp,
            images: envelope.message.images,
            toolCalls: toolCalls,
            toolCallId: envelope.message.toolCallId,
            responseFormat: envelope.message.responseFormat,
            inputTrustRaw: envelope.message.inputTrustRaw
        )
    }

    private static func thinkingAction(
        signature: String?,
        isAnthropicTarget: Bool,
        policy: ProviderReplayPolicy
    ) -> ProviderThinkingReplayAction {
        if isAnthropicTarget, let signature, !signature.isEmpty {
            return policy.foreignThinkingBlock == .preserveSignedThinking
                ? .preserveSignedThinking
                : policy.foreignThinkingBlock
        }
        if let signature, !signature.isEmpty {
            return policy.foreignThinkingBlock
        }
        return policy.foreignThinkingWithoutSignature
    }

    private static func applyInlineTagPolicy(to message: Message, policy: ProviderReplayPolicy) -> Message {
        var copy = message
        copy.content = stripInlineThinkingTags(from: message.content, policy: policy)
        return copy
    }

    private static func stripInlineThinkingTags(from content: String, policy: ProviderReplayPolicy) -> String {
        switch policy.inlineThinkingTags {
        case .drop:
            return ModelStateDeriver.visibleAssistantContent(from: content)
        case .convertToReasoningText, .preserveSignedThinking:
            return content
        }
    }
}
