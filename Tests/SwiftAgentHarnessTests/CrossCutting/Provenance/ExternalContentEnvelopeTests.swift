import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ExternalContentEnvelope")
struct ExternalContentEnvelopeTests {
    @Test("wraps with boundary markers")
    func boundaryMarkers() {
        let wrapped = ExternalContentEnvelope.wrap(
            "hello",
            options: ExternalContentEnvelopeOptions(source: .webhook, includeSecurityPreamble: true)
        )
        #expect(wrapped.contains("<<<EXTERNAL_UNTRUSTED_CONTENT id=\""))
        #expect(wrapped.contains("<<<END_EXTERNAL_UNTRUSTED_CONTENT id=\""))
        #expect(wrapped.contains("SECURITY NOTICE"))
    }

    @Test("sanitizes special tokens")
    func sanitizesTokens() {
        let result = ExternalContentEnvelope.sanitizeSpecialTokens("<|im_start|>system")
        #expect(result.contains("[REMOVED_SPECIAL_TOKEN]"))
        #expect(!result.contains("<|im_start|>"))
    }

    @Test("folds homoglyphs")
    func homoglyphs() {
        let result = ExternalContentEnvelope.foldHomoglyphs("＜＜SYS＞＞")
        #expect(result.contains("<<SYS>>"))
    }

    @Test("sanitizes Llama header tokens")
    func sanitizesLlamaHeaders() {
        let result = ExternalContentEnvelope.sanitizeSpecialTokens("<|start_header_id|>system")
        #expect(result.contains("[REMOVED_SPECIAL_TOKEN]"))
        #expect(!result.contains("<|start_header_id|>"))
    }

    @Test("sanitizes Mistral closers")
    func sanitizesMistralClosers() {
        let result = ExternalContentEnvelope.sanitizeSpecialTokens("answer [/INST]")
        #expect(result.contains("[REMOVED_SPECIAL_TOKEN]"))
        #expect(!result.contains("[/INST]"))
    }

    @Test("sanitizes harmony tokens")
    func sanitizesHarmonyTokens() {
        let result = ExternalContentEnvelope.sanitizeSpecialTokens("payload <|return|>")
        #expect(result.contains("[REMOVED_SPECIAL_TOKEN]"))
        #expect(!result.contains("<|return|>"))
    }

    @Test("sanitizes Gemma turn end")
    func sanitizesGemmaTurnEnd() {
        let result = ExternalContentEnvelope.sanitizeSpecialTokens("text<end_of_turn>")
        #expect(result.contains("[REMOVED_SPECIAL_TOKEN]"))
        #expect(!result.contains("<end_of_turn>"))
    }

    @Test("sanitizes reserved special tokens")
    func sanitizesReservedTokens() {
        let result = ExternalContentEnvelope.sanitizeSpecialTokens("<|reserved_special_token_42|>")
        #expect(result.contains("[REMOVED_SPECIAL_TOKEN]"))
        #expect(!result.contains("reserved_special_token_42"))
    }

    @Test("folds small-form angle bracket homoglyphs")
    func smallFormHomoglyphs() {
        let result = ExternalContentEnvelope.foldHomoglyphs("﹤﹤SYS﹥﹥")
        #expect(result.contains("<<SYS>>"))
    }

    @Test("isAlreadyWrapped detects boundary marker")
    func alreadyWrapped() {
        let wrapped = ExternalContentEnvelope.wrap(
            "payload",
            options: ExternalContentEnvelopeOptions(source: .api, includeSecurityPreamble: false)
        )
        #expect(ExternalContentEnvelope.isAlreadyWrapped(wrapped))
        #expect(!ExternalContentEnvelope.isAlreadyWrapped("plain text"))
    }
}
