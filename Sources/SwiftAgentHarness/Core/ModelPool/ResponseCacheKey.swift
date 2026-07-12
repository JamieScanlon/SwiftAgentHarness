import CryptoKit
import Foundation
import SwiftAgentKit

enum ResponseCacheOwnerScope {
    /// Returns `nil` when strict tenancy requires an owner but none is present (cache bypass).
    /// Returns `""` when tenancy is off (legacy shared cache partition).
    static func resolve(
        ownerAccountID: UUID?,
        tenancyPolicy: TenancyPolicySettings
    ) -> String? {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else {
            return ""
        }
        guard let ownerAccountID else {
            return nil
        }
        return AgentMemoryPathResolver.ownerSegment(ownerAccountID)
    }
}

struct ResponseCacheKey: Hashable, Sendable {
    let ownerScopeKey: String
    let modelID: UUID
    let providerScopeKey: String
    let stablePrefixMessageCount: Int
    let messagesDigestHex: String
    let configDigestHex: String

    static func make(
        ownerScopeKey: String,
        modelID: UUID,
        providerScopeKey: String,
        messages: [Message],
        config: LLMRequestConfig,
        stablePrefixMessageCount: Int?
    ) -> ResponseCacheKey {
        let prefixMessages = boundaryStablePrefixMessages(
            messages: messages,
            stablePrefixMessageCount: stablePrefixMessageCount
        )
        let messageMaterial = prefixMessages.enumerated()
            .map { "\($0.offset):\(String(describing: $0.element))" }
            .joined(separator: "\n")
        let configMaterial = String(describing: config)
        return ResponseCacheKey(
            ownerScopeKey: ownerScopeKey,
            modelID: modelID,
            providerScopeKey: providerScopeKey,
            stablePrefixMessageCount: prefixMessages.count,
            messagesDigestHex: digestHex(messageMaterial),
            configDigestHex: digestHex(configMaterial)
        )
    }

    private static func boundaryStablePrefixMessages(
        messages: [Message],
        stablePrefixMessageCount: Int?
    ) -> [Message] {
        guard let stablePrefixMessageCount, stablePrefixMessageCount > 0 else {
            return messages.filter { !HarnessInjectedMessageMetadata.isHarnessInjected($0) }
        }
        var count = 0
        var selected: [Message] = []
        for message in messages {
            if HarnessInjectedMessageMetadata.isHarnessInjected(message) {
                continue
            }
            selected.append(message)
            count += 1
            if count >= stablePrefixMessageCount {
                break
            }
        }
        return selected
    }

    private static func digestHex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
