import CryptoKit
import Foundation
import SwiftAgentKit

struct ResponseCacheKey: Hashable, Sendable {
    let modelID: UUID
    let providerScopeKey: String
    let stablePrefixMessageCount: Int
    let messagesDigestHex: String
    let configDigestHex: String

    static func make(
        modelID: UUID,
        providerScopeKey: String,
        messages: [Message],
        config: LLMRequestConfig,
        stablePrefixMessageCount: Int?
    ) -> ResponseCacheKey {
        let prefixCount = min(messages.count, max(0, stablePrefixMessageCount ?? messages.count))
        let prefix = messages.prefix(prefixCount)
        let messageMaterial = prefix.enumerated()
            .map { "\($0.offset):\(String(describing: $0.element))" }
            .joined(separator: "\n")
        let configMaterial = String(describing: config)
        return ResponseCacheKey(
            modelID: modelID,
            providerScopeKey: providerScopeKey,
            stablePrefixMessageCount: prefixCount,
            messagesDigestHex: digestHex(messageMaterial),
            configDigestHex: digestHex(configMaterial)
        )
    }

    private static func digestHex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

