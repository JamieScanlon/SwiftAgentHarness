import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Anthropic prompt cache breakpoints")
struct AnthropicPromptCacheBreakpointTests {
    @Test("system wire attaches cache_control on stable system block")
    func systemWireAttachesCacheControl() throws {
        let marker = ProviderPromptContribution.cacheBoundaryMarker
        let system = "stable block\n\n\(marker)\n\nToday is volatile."
        let additional: JSON = .object([
            PromptCacheKnobKey.mode: .string("ephemeral"),
            PromptCacheKnobKey.breakpoints: .array([
                .object([
                    "kind": .string(PromptCacheBreakpointKind.stableSystemPrefixEnd.rawValue),
                    "estimatedPrefixTokens": .integer(1200),
                ])
            ]),
        ])
        let payload = AnthropicPromptCacheWire.systemPayload(
            systemText: system,
            additionalParameters: additional
        )
        let blocks = try #require(payload as? [[String: Any]])
        let first = try #require(blocks.first)
        let cacheControl = try #require(first["cache_control"] as? [String: Any])
        #expect(cacheControl["type"] as? String == "ephemeral")
        #expect((first["text"] as? String)?.contains("stable block") == true)
        let second = try #require(blocks.dropFirst().first)
        #expect((second["text"] as? String)?.contains("Today is volatile") == true)
    }
}
