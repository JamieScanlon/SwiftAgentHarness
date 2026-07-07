import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ModelRef parse")
struct ModelRefParserTests {
    @Test("Slash form splits at first slash")
    func slashForm() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let ref = try ModelRefParser.parse("openrouter/anthropic/claude-sonnet-4-6")
        #expect(ref.providerID == "openrouter")
        #expect(ref.modelID == "anthropic/claude-sonnet-4-6")
    }

    @Test("Provider aliases normalize")
    func providerAliases() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let ref = try ModelRefParser.parse("gpt/gpt-5.5")
        #expect(ref.providerID == "openai")
        #expect(ref.modelID == "gpt-5.5")
    }

    @Test("Bare model uses defaultProvider")
    func defaultProvider() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let ref = try ModelRefParser.parse("gemma3:27b", defaultProvider: "ollama")
        #expect(ref.providerID == "ollama")
        #expect(ref.modelID == "gemma3:27b")
    }

    @Test("Bare model infers provider from prefix")
    func prefixInference() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let ref = try ModelRefParser.parse("claude-sonnet-4-6")
        #expect(ref.providerID == "anthropic")
        #expect(ref.modelID == "claude-sonnet-4-6")
    }

    @Test("Plugin normalizeProviderModelId hook is applied")
    func modelNormalizationHook() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let ref = try ModelRefParser.parse(
            "anthropic/opus",
            normalizeModelID: { providerID, modelID in
                guard providerID == "anthropic", modelID == "opus" else { return modelID }
                return "claude-opus-4-6"
            }
        )
        #expect(ref.modelID == "claude-opus-4-6")
    }

    @Test("Empty input throws")
    func emptyInput() {
        #expect(throws: ModelRefParseError.self) {
            try ModelRefParser.parse("")
        }
    }
}
