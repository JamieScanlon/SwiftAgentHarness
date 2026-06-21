import Foundation
import OllamaKit
import Testing
@testable import SwiftAgentHarness

@Suite("OllamaLLM request encoding")
struct OllamaLLMRequestEncodingTests {
    @Test("encoded chat request body includes think when provided")
    func encodedBodyIncludesThink() throws {
        let requestData = OKChatRequestData(
            model: "test",
            messages: [.init(role: .user, content: "hello")],
            think: false
        )

        let body = try OllamaLLM.testEncodedChatRequestBody(requestData)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["think"] as? Bool == false)
    }

    @Test("make chat request carries think in HTTP body")
    func makeChatRequestCarriesThink() throws {
        let requestData = OKChatRequestData(
            model: "test",
            messages: [.init(role: .user, content: "hello")],
            think: true
        )
        let request = try OllamaLLM.testMakeChatRequest(
            baseURL: URL(string: "http://localhost:11434")!,
            requestData: requestData,
            timeout: nil
        )
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["think"] as? Bool == true)
    }
}
