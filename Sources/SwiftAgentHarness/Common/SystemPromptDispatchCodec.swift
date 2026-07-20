import CryptoKit
import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKit

/// Resolves harness message arrays into provider-ready prompts with a single canonical system expansion.
enum SystemPromptDispatchCodec: Sendable {
    struct DispatchPlan: Sendable {
        let canonicalSystemText: String?
        let resolvedMessages: [Message]
        let assembledPromptDigest: String?
    }

    static func sha256Digest(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalSystemMessageIndex(in messages: [Message]) -> Int? {
        messages.firstIndex { message in
            message.role == .system && !HarnessInjectedMessageMetadata.isHarnessInjected(message)
        }
    }

    static func resolve(
        messages: [Message],
        systemPrompt: SystemPrompt?,
        promptMetadata: [String: String],
        providerStablePrefix: String?
    ) async throws -> DispatchPlan {
        var metadata = promptMetadata
        if let providerStablePrefix,
           !providerStablePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata[SystemPromptAssemblyMetadataKeys.providerStablePrefix] = providerStablePrefix
        }

        let canonicalIndex = canonicalSystemMessageIndex(in: messages)

        if let canonicalIndex,
           let expectedDigest = metadata[SystemPromptAssemblyMetadataKeys.assembledPromptDigest]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedDigest.isEmpty {
            let canonicalContent = messages[canonicalIndex].content
            if sha256Digest(of: canonicalContent) == expectedDigest {
                return DispatchPlan(
                    canonicalSystemText: canonicalContent,
                    resolvedMessages: messages,
                    assembledPromptDigest: expectedDigest
                )
            }
        }

        var canonicalText: String?
        if let systemPrompt {
            let userPrompt: String = {
                guard let canonicalIndex else { return "" }
                return messages[canonicalIndex].content
            }()
            canonicalText = try await systemPrompt.generateSystemPrompt(
                withUserSystemPrompt: userPrompt,
                additionalMetadata: metadata
            )
        }

        var resolved: [Message] = []
        resolved.reserveCapacity(messages.count)
        var expandedCanonical = false
        for (index, message) in messages.enumerated() {
            if message.role == .system,
               HarnessInjectedMessageMetadata.isHarnessInjected(message) {
                resolved.append(message)
                continue
            }
            if message.role == .system,
               let canonicalText,
               let canonicalIndex,
               index == canonicalIndex,
               !expandedCanonical {
                resolved.append(
                    Message(
                        id: message.id,
                        role: .system,
                        content: canonicalText,
                        timestamp: message.timestamp,
                        toolCalls: message.toolCalls,
                        inputTrustRaw: message.inputTrustRaw
                    )
                )
                expandedCanonical = true
                continue
            }
            resolved.append(message)
        }

        if let canonicalText, !expandedCanonical, !canonicalText.isEmpty {
            let injected = HarnessInjectedMessageMetadata.systemMessage(id: UUID(), content: canonicalText)
            resolved.insert(injected, at: 0)
        }

        let digest = canonicalText.map { sha256Digest(of: $0) }
        return DispatchPlan(
            canonicalSystemText: canonicalText,
            resolvedMessages: resolved,
            assembledPromptDigest: digest
        )
    }

    static func extractPromptMetadata(from additionalParameters: JSON?) -> [String: String] {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              let metadataJSON = root["contextEngineSystemPromptMetadata"] ?? root["systemPromptMetadata"],
              case .object(let metadataObject) = metadataJSON else {
            return [:]
        }
        var metadata: [String: String] = [:]
        for (key, value) in metadataObject {
            switch value {
            case .string(let stringValue):
                metadata[key] = stringValue
            case .integer(let integerValue):
                metadata[key] = String(integerValue)
            case .double(let doubleValue):
                metadata[key] = String(doubleValue)
            case .boolean(let booleanValue):
                metadata[key] = String(booleanValue)
            case .array, .object:
                continue
            }
        }
        return metadata
    }

    static func extractProviderStablePrefix(from additionalParameters: JSON?) -> String? {
        let metadata = extractPromptMetadata(from: additionalParameters)
        let raw = metadata[SystemPromptAssemblyMetadataKeys.providerStablePrefix]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}
