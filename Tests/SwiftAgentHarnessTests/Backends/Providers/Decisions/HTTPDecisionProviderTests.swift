import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

private func provider(
    _ transport: MockDecisionTransport,
    profile: ContractProfile = DecisionProfiles.systemOne(),
    serverURL: URL = DecisionFixtures.baseURL,
    credential: String? = "sk-test"
) -> (HTTPDecisionProvider, DecisionDispatchTarget) {
    let entry = DecisionFixtures.decider("decider-2026-09", profile: profile, serverURL: serverURL)
    let provider = HTTPDecisionProvider(
        manifest: DecisionFixtures.manifest("decider"),
        entries: [entry],
        transport: transport,
        retryExecutor: instantRetryExecutor(),
        credential: { _ in credential }
    )
    return (provider, DecisionDispatchTarget(entry: entry, binding: entry.providers[0], profile: profile))
}

private func systemOneAnswers(_ answers: [String: Double], model: String = "decider-2026-09", inputTokens: Int = 100) -> String {
    let body = answers.keys.sorted().map { "\"\($0)\": {\"type\": \"noul\", \"noul\": \(answers[$0]!)}" }.joined(separator: ",")
    return "{\"model\": \"\(model)\", \"answers\": {\(body)}, \"usage\": {\"input_tokens\": \(inputTokens), \"output_tokens\": 0}}"
}

@Suite("HTTP decision provider")
struct HTTPDecisionProviderTests {
    @Test("Posts to {base}/v1/systemone with bearer auth and returns a calibrated, versioned result")
    func endToEnd() async throws {
        let transport = MockDecisionTransport([
            .ok(systemOneAnswers(["safe": 0.97], model: "decider-2026-09-15"), headers: ["request-id": "req_123"]),
        ])
        let (provider, target) = provider(transport)
        let result = try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        #expect(result.modelVersion == "decider-2026-09-15")
        #expect(result.calibrated)
        #expect(result.guarantee == .calibratedDistribution)
        #expect(result.answers["safe"] == .yesNo(pYes: 0.97))
        #expect(result.usage.inputTokens == 100)
        #expect(result.requestIDs == ["req_123"])

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://decider.example/v1/systemone")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.jsonBody?[test: "model"]?.testString == "decider-2026-09")
    }

    @Test("Local servers send no Authorization header")
    func noCredential() async throws {
        let transport = MockDecisionTransport([.ok(systemOneAnswers(["safe": 0.5]))])
        let (provider, target) = provider(transport, credential: nil)
        _ = try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Falls back to the binding id when the response omits model")
    func versionFallback() async throws {
        let transport = MockDecisionTransport([.ok("{\"answers\": {\"safe\": {\"type\": \"noul\", \"noul\": 0.4}}}")])
        let (provider, target) = provider(transport)
        let result = try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        #expect(result.modelVersion == "decider-2026-09")
    }

    @Test("Omitted ids become missing-in-response and broken distributions become invalid-distribution")
    func reconciliation() async throws {
        let transport = MockDecisionTransport([.ok(systemOneAnswers(["a": 1.3]))])
        let (provider, target) = provider(transport)
        let result = try await provider.decide(DecisionFixtures.yesNoRequest(["a", "b"]), target: target)
        #expect(result.answers["a"] == .unavailable(reason: .invalidDistribution))
        #expect(result.answers["b"] == .unavailable(reason: .missingInResponse))
    }

    @Test("Splits questions by maxItemsPerCall and merges answers and usage")
    func splitsByLimit() async throws {
        let transport = MockDecisionTransport(handler: { request in
            let ids = request.jsonBody?[test: "questions"]?.testObject?.keys.sorted() ?? []
            return .ok(systemOneAnswers(Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.6) }), inputTokens: 10))
        })
        let profile = DecisionProfiles.systemOne(limits: ContractLimits(contextTokens: 65_536, maxItemsPerCall: 64, maxOptions: 255))
        let (provider, target) = provider(transport, profile: profile)
        let ids = (0..<130).map { "q\($0)" }
        let result = try await provider.decide(DecisionFixtures.yesNoRequest(ids), target: target)
        #expect(await transport.requestCount == 3)
        #expect(result.answers.count == 130)
        #expect(result.answers.values.allSatisfy { $0 == .yesNo(pYes: 0.6) })
        #expect(result.usage.inputTokens == 30)
    }

    @Test("A token-limit 400 is retried once by splitting the questions")
    func contextOverflowSplit() async throws {
        let transport = MockDecisionTransport(handler: { request in
            let ids = request.jsonBody?[test: "questions"]?.testObject?.keys.sorted() ?? []
            if ids.count > 2 {
                return .status(400, "{\"error\": {\"type\": \"max_tokens_exceeded\"}}")
            }
            return .ok(systemOneAnswers(Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.2) })))
        })
        let (provider, target) = provider(transport)
        let result = try await provider.decide(DecisionFixtures.yesNoRequest(["a", "b", "c", "d"]), target: target)
        #expect(await transport.requestCount == 3)
        #expect(result.answers.count == 4)
    }

    @Test("A token-limit 400 on a single question surfaces as context-overflow")
    func contextOverflowSingle() async {
        let transport = MockDecisionTransport([.status(400, "{\"error\": \"max_tokens_exceeded\"}")])
        let (provider, target) = provider(transport)
        await #expect(throws: DecisionProviderError.self) {
            try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        }
        let error = DecisionProviderError.http(status: 400, body: "max_tokens_exceeded", requestID: nil)
        #expect(provider.failoverError(error) == .contextOverflow)
    }

    @Test("Split chunks answered by different versions are rejected")
    func inconsistentVersions() async {
        let transport = MockDecisionTransport(handler: { request in
            let ids = request.jsonBody?[test: "questions"]?.testObject?.keys.sorted() ?? []
            let model = ids.contains("q0") ? "v1" : "v2"
            return .ok(systemOneAnswers(Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.5) }), model: model))
        })
        let profile = DecisionProfiles.systemOne(limits: ContractLimits(maxItemsPerCall: 1))
        let (provider, target) = provider(transport, profile: profile)
        await #expect(throws: DecisionProviderError.inconsistentModelVersions(["v1", "v2"])) {
            try await provider.decide(DecisionFixtures.yesNoRequest(["q0", "q1"]), target: target)
        }
    }

    @Test("Bodies above 1 KiB are gzip-compressed when the binding opts in")
    func gzip() async throws {
        let transport = MockDecisionTransport([.ok(systemOneAnswers(["safe": 0.5]))])
        let profile = DecisionProfiles.systemOne(extraFeatures: [
            DecisionFeatureKey.compression: FeatureSupport(params: ["encoding": .string("gzip")]),
        ])
        let (provider, target) = provider(transport, profile: profile)
        let state = JSON.string(String(repeating: "log line\n", count: 400))
        _ = try await provider.decide(DecisionFixtures.yesNoRequest(state: state), target: target)
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(request.httpBody?.prefix(2) == Data([0x1f, 0x8b]))
    }

    @Test("Small bodies are never compressed")
    func smallBodyUncompressed() async throws {
        let transport = MockDecisionTransport([.ok(systemOneAnswers(["safe": 0.5]))])
        let profile = DecisionProfiles.systemOne(extraFeatures: [
            DecisionFeatureKey.compression: FeatureSupport(params: ["encoding": .string("gzip")]),
        ])
        let (provider, target) = provider(transport, profile: profile)
        _ = try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Content-Encoding") == nil)
    }

    @Test("Large states set the long-context opt-in header")
    func longContextHeader() async throws {
        let transport = MockDecisionTransport([.ok(systemOneAnswers(["safe": 0.5])), .ok(systemOneAnswers(["safe": 0.5]))])
        let profile = DecisionProfiles.systemOne(
            longContext: FeatureSupport(params: ["optInHeader": .string("X-Long-Context")]),
            limits: ContractLimits(contextTokens: 100)
        )
        let (provider, target) = provider(transport, profile: profile)
        _ = try await provider.decide(DecisionFixtures.yesNoRequest(state: .string(String(repeating: "x", count: 2_000))), target: target)
        _ = try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        let requests = await transport.requests
        #expect(requests[0].value(forHTTPHeaderField: "X-Long-Context") == "true")
        #expect(requests[1].value(forHTTPHeaderField: "X-Long-Context") == nil)
    }

    @Test("OpenAI Decisions binding posts to {base}/decisions without doubling v1")
    func openAIEndpoint() async throws {
        let body = """
        {"model": "gpt-decide-1", "answers": [{"type": "predicate", "name": "safe", "probability": 0.8}]}
        """
        let transport = MockDecisionTransport([.ok(body)])
        let (provider, target) = provider(
            transport,
            profile: DecisionProfiles.openAIDecisions(),
            serverURL: URL(string: "https://api.openai.com/v1")!
        )
        let result = try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        #expect(result.answers["safe"] == .yesNo(pYes: 0.8))
        #expect(await transport.requests.first?.url?.absoluteString == "https://api.openai.com/v1/decisions")
    }

    @Test("Question kinds and surfaces the binding cannot serve fail before any request")
    func unsupported() async {
        let transport = MockDecisionTransport([])
        let (provider, target) = provider(transport, profile: DecisionProfiles.systemOne(questionKinds: [.choice]))
        await #expect(throws: DecisionProviderError.unsupportedQuestionKind(.yesNo, surface: .systemOne)) {
            try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        }
        var emulated = target
        emulated.profile.surface = .llmEmulation
        await #expect(throws: DecisionProviderError.unsupportedSurface(.llmEmulation)) {
            try await provider.decide(DecisionFixtures.yesNoRequest(), target: emulated)
        }
        #expect(await transport.requestCount == 0)
    }

    @Test("Invalid requests are rejected before dispatch")
    func invalidRequest() async {
        let transport = MockDecisionTransport([])
        let (provider, target) = provider(transport)
        await #expect(throws: DecisionRequestValidationError.noQuestions) {
            try await provider.decide(DecisionRequest(state: .string("s"), questions: []), target: target)
        }
    }

    @Test("Warm-up issues a GET to /v1/models")
    func warm() async {
        let transport = MockDecisionTransport([.ok("{}")])
        let (provider, target) = provider(transport)
        await provider.warmConnections(target: target)
        let request = await transport.requests.first
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.absoluteString == "https://decider.example/v1/models")
    }

    @Test("Discovery returns the configured decide rows")
    func discovery() async {
        let (provider, _) = provider(MockDecisionTransport([]))
        let entries = await provider.discoverEntries(logger: nil)
        #expect(entries.count == 1)
        #expect(entries[0].supports(.decide))
    }
}

@Suite("Decision retry and transport")
struct DecisionRetryTests {
    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://decider.example/v1/systemone")!)
    }

    @Test("Retries 503, 529, 408 and 429, then succeeds")
    func retriesRetryableStatuses() async throws {
        let transport = MockDecisionTransport([.status(503), .status(529), .status(408), .status(429), .ok("{}")])
        let executor = instantRetryExecutor(DecisionRetryPolicy(maxAttempts: 5, totalBudget: .seconds(60)))
        let (_, response) = try await executor.execute(request(), transport: transport)
        #expect(response.statusCode == 200)
        #expect(await transport.requestCount == 5)
    }

    @Test("Does not retry permanent client errors")
    func noRetryOn400() async {
        let transport = MockDecisionTransport([.status(422, "{\"field\": \"questions\"}"), .ok("{}")])
        await #expect(throws: DecisionProviderError.http(status: 422, body: "{\"field\": \"questions\"}", requestID: nil)) {
            try await instantRetryExecutor().execute(request(), transport: transport)
        }
        #expect(await transport.requestCount == 1)
    }

    @Test("Retries transport errors and gives up after maxAttempts")
    func transportErrors() async {
        let transport = MockDecisionTransport([.fail(.timedOut), .fail(.networkConnectionLost), .fail(.timedOut)])
        let executor = instantRetryExecutor(DecisionRetryPolicy(maxAttempts: 3, totalBudget: .seconds(60)))
        await #expect(throws: URLError.self) {
            try await executor.execute(request(), transport: transport)
        }
        #expect(await transport.requestCount == 3)
    }

    @Test("Honors retry-after-ms and retry-after")
    func honorsRetryAfter() async throws {
        let sleeps = SleepRecorder()
        let transport = MockDecisionTransport([
            .status(429, headers: ["retry-after-ms": "1500"]),
            .status(503, headers: ["retry-after": "2"]),
            .ok("{}"),
        ])
        let executor = DecisionRetryExecutor(
            policy: DecisionRetryPolicy(maxAttempts: 4, totalBudget: .seconds(60)),
            sleep: { await sleeps.record($0) },
            jitter: { 0 }
        )
        _ = try await executor.execute(request(), transport: transport)
        #expect(await sleeps.durations == [.milliseconds(1500), .milliseconds(2000)])
    }

    @Test("Stops retrying when the next delay would exceed the total time budget")
    func totalBudget() async {
        let transport = MockDecisionTransport([.status(503, headers: ["retry-after": "30"]), .ok("{}")])
        let executor = instantRetryExecutor(DecisionRetryPolicy(maxAttempts: 5, totalBudget: .seconds(5)))
        await #expect(throws: DecisionProviderError.self) {
            try await executor.execute(request(), transport: transport)
        }
        #expect(await transport.requestCount == 1)
        let tighter = instantRetryExecutor(DecisionRetryPolicy(maxAttempts: 5, totalBudget: .seconds(60)))
        let second = MockDecisionTransport([.status(503, headers: ["retry-after": "30"]), .ok("{}")])
        await #expect(throws: DecisionProviderError.self) {
            try await tighter.execute(self.request(), transport: second, budget: .seconds(1))
        }
    }

    @Test("Backoff is exponential, jittered, and capped")
    func backoff() {
        let policy = DecisionRetryPolicy(baseDelay: .milliseconds(250), maxDelay: .seconds(5))
        #expect(policy.backoff(afterAttempt: 0, jitter: 1) == .milliseconds(250))
        #expect(policy.backoff(afterAttempt: 2, jitter: 1) == .seconds(1))
        #expect(policy.backoff(afterAttempt: 10, jitter: 1) == .seconds(5))
        #expect(policy.backoff(afterAttempt: 10, jitter: 0) == .milliseconds(125))
    }

    @Test("Error classification follows the decision transport table")
    func classification() {
        #expect(DecisionErrorClassifier.classify(status: 401, body: "") == .authError)
        #expect(DecisionErrorClassifier.classify(status: 403, body: "") == .authError)
        #expect(DecisionErrorClassifier.classify(status: 400, body: "max_tokens_exceeded") == .contextOverflow)
        #expect(DecisionErrorClassifier.classify(status: 400, body: "bad field") == .permanent)
        #expect(DecisionErrorClassifier.classify(status: 413, body: "") == .permanent)
        #expect(DecisionErrorClassifier.classify(status: 415, body: "") == .permanent)
        #expect(DecisionErrorClassifier.classify(status: 422, body: "") == .permanent)
        #expect(DecisionErrorClassifier.classify(status: 429, body: "") == .rateLimited)
        #expect(DecisionErrorClassifier.classify(status: 408, body: "") == .transient)
        #expect(DecisionErrorClassifier.classify(status: 529, body: "") == .transient)
        #expect(DecisionErrorClassifier.classify(status: 502, body: "") == .transient)
        #expect(DecisionErrorClassifier.classify(status: 404, body: "") == .modelNotFound)
        #expect(DecisionErrorClassifier.classify(URLError(.timedOut)) == .transient)
        #expect(DecisionErrorClassifier.classify(URLError(.cancelled)) == .permanent)
        #expect(DecisionErrorClassifier.classify(DecisionProviderError.timeBudgetExhausted) == .transient)
        #expect(DecisionErrorClassifier.classify(DecisionProviderError.missingCredential("p")) == .authError)
        #expect(DecisionErrorClassifier.classify(AuthProfileStoreError.credentialNotFound("p", profileLabel: nil)) == .authError)
        #expect(DecisionErrorClassifier.classify(CancellationError()) == .permanent)
    }

    @Test("Request ids are read from the vendor header")
    func requestID() {
        let url = URL(string: "https://x")!
        let a = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["request-id": "r1"])!
        let b = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["x-request-id": "r2"])!
        #expect(DecisionRetryExecutor.requestID(from: a) == "r1")
        #expect(DecisionRetryExecutor.requestID(from: b) == "r2")
    }

    @Test("gzip output carries the header, CRC-32, and size trailer and inflates back")
    func gzipFraming() throws {
        let payload = Data(String(repeating: "decision state ", count: 200).utf8)
        let gz = try DecisionBodyCompression.gzip(payload)
        #expect(gz.prefix(3) == Data([0x1f, 0x8b, 0x08]))
        let trailer = gz.suffix(8)
        let crc = trailer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let size = trailer.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        #expect(crc == DecisionBodyCompression.crc32(payload))
        #expect(size == UInt32(payload.count))
        let deflated = gz.dropFirst(10).dropLast(8)
        let inflated = try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
        #expect(inflated == payload)
        #expect(gz.count < payload.count)
    }

    @Test("CRC-32 matches the standard check value")
    func crcCheckValue() {
        #expect(DecisionBodyCompression.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("Endpoint joining collapses a duplicated v1 segment")
    func endpointJoin() {
        #expect(DecisionEndpoint.url(base: URL(string: "https://a.example")!, path: "v1/systemone").absoluteString
            == "https://a.example/v1/systemone")
        #expect(DecisionEndpoint.url(base: URL(string: "https://api.openai.com/v1")!, path: "v1/decisions").absoluteString
            == "https://api.openai.com/v1/decisions")
        #expect(DecisionEndpoint.url(base: URL(string: "https://edge.example/client/v4")!, path: "/ai/run/decide").absoluteString
            == "https://edge.example/client/v4/ai/run/decide")
    }
}

actor SleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}
