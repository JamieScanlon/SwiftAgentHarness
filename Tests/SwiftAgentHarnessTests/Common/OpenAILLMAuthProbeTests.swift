import Foundation
import Testing
@testable import SwiftAgentHarness

private actor AuthProbeCallCounter {
    private(set) var count = 0
    func increment() {
        count += 1
    }
}

@Suite("OpenAILLM auth probe")
struct OpenAILLMAuthProbeTests {
    @Test("returns false on 401")
    func returnsFalseOnUnauthorized() async {
        let llm = OpenAILLM(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            model: "gpt-test",
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

    @Test("returns true on 2xx")
    func returnsTrueOnSuccess() async {
        let llm = OpenAILLM(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            model: "gpt-test",
            authProbeTransport: { request in
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
    }

    @Test("dummy key keeps probe permissive and skips request")
    func dummyKeySkipsRequest() async {
        let counter = AuthProbeCallCounter()
        let llm = OpenAILLM(
            baseURL: "https://api.openai.com/v1",
            apiKey: "dummy_key",
            model: "gpt-test",
            authProbeTransport: { request in
                let _ = request
                await counter.increment()
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
