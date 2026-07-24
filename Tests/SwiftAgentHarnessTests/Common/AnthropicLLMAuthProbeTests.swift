import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor AuthProbeCallCounter {
    private(set) var count = 0
    private(set) var lastURL: URL?
    func increment(url: URL?) {
        count += 1
        lastURL = url
    }
}

@Suite("AnthropicLLM auth probe")
struct AnthropicLLMAuthProbeTests {
    @Test("returns false on 401")
    func returnsFalseOnUnauthorized() async throws {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let llm = AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-test",
            model: "claude-test",
            systemPrompt: prompt,
            authProbeTransport: { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: [:]
                )!
                return (Data(), response)
            }
        )
        let result = await llm.validateAuth()
        #expect(result == false)
    }

    @Test("returns true on 2xx and probes /v1/models")
    func returnsTrueOnSuccess() async throws {
        let counter = AuthProbeCallCounter()
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let llm = AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-test",
            model: "claude-test",
            systemPrompt: prompt,
            authProbeTransport: { request in
                await counter.increment(url: request.url)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
                return (Data(), response)
            }
        )
        let result = await llm.validateAuth()
        #expect(result == true)
        #expect(await counter.count == 1)
        #expect(await counter.lastURL?.absoluteString.hasSuffix("/v1/models") == true)
    }

    @Test("dummy key keeps probe permissive and skips request")
    func dummyKeySkipsRequest() async throws {
        let counter = AuthProbeCallCounter()
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let llm = AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "dummy_key",
            model: "claude-test",
            systemPrompt: prompt,
            authProbePermissiveForEmptyToken: true,
            authProbeTransport: { request in
                await counter.increment(url: request.url)
                let response = HTTPURLResponse(
                    url: URL(string: "https://example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
                return (Data(), response)
            }
        )
        let result = await llm.validateAuth()
        #expect(result == true)
        #expect(await counter.count == 0)
    }
}
