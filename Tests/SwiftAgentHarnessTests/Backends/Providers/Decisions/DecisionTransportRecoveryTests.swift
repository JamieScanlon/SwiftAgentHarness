#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private func provider(_ transport: MockDecisionTransport, profile: ContractProfile = DecisionProfiles.systemOne(
    images: FeatureSupport(params: ["encoding": .string("assets")])
)) -> (HTTPDecisionProvider, DecisionDispatchTarget) {
    let entry = DecisionFixtures.decider("d-1", profile: profile)
    let provider = HTTPDecisionProvider(
        manifest: DecisionFixtures.manifest("decider"), entries: [entry], transport: transport,
        retryExecutor: instantRetryExecutor(), credential: { _ in nil }
    )
    return (provider, DecisionDispatchTarget(entry: entry, binding: entry.providers[0], profile: profile))
}

private let okBody = #"{"model": "d-1", "answers": {"safe": {"type": "noul", "noul": 0.9}}}"#

@Suite("Decision state trimming")
struct DecisionStateTrimmerTests {
    @Test("A long string state keeps head and tail around a visible marker")
    func stringState() throws {
        let text = String(repeating: "a", count: 600) + String(repeating: "z", count: 400)
        let trimmed = try #require(DecisionStateTrimmer.trimmed(.string(text)))
        guard case .string(let value) = trimmed else { Issue.record("expected string"); return }
        #expect(value.hasPrefix("aaa"))
        #expect(value.hasSuffix("zzz"))
        #expect(value.contains("characters trimmed]"))
        #expect(value.count < text.count)
    }

    @Test("Only the longest string in a structured state is trimmed")
    func structuredState() throws {
        let log = String(repeating: "line\n", count: 300)
        let state: JSON = .object(["command": .string("make test"), "log": .string(log), "tags": .array([.string("ci")])])
        let trimmed = try #require(DecisionStateTrimmer.trimmed(state))
        #expect(trimmed[test: "command"]?.testString == "make test")
        #expect(trimmed[test: "tags"]?[test: 0]?.testString == "ci")
        #expect((trimmed[test: "log"]?.testString?.count ?? .max) < log.count)
    }

    @Test("States without a long string are not trimmed")
    func nothingToTrim() {
        #expect(DecisionStateTrimmer.trimmed(.string("short")) == nil)
        #expect(DecisionStateTrimmer.trimmed(.object(["a": .integer(1)])) == nil)
    }
}

@Suite("Decision transport recovery")
struct DecisionTransportRecoveryTests {
    @Test("A token-limit 400 on a single question retries once with a trimmed state")
    func trimRetry() async throws {
        let transport = MockDecisionTransport([.status(400, #"{"error": "max_tokens_exceeded"}"#), .ok(okBody)])
        let (provider, target) = provider(transport)
        let state = JSON.string(String(repeating: "evidence ", count: 200))
        let result = try await provider.decide(DecisionFixtures.yesNoRequest(state: state), target: target)
        #expect(result.answers["safe"] == .yesNo(pYes: 0.9))
        let bodies = await transport.requests.compactMap { $0.jsonBody?[test: "state"]?.testString }
        #expect(bodies.count == 2)
        #expect(bodies[1].count < bodies[0].count)
        #expect(bodies[1].contains("characters trimmed]"))
    }

    @Test("A token-limit 400 with nothing to trim fails after one request")
    func nothingToTrim() async {
        let transport = MockDecisionTransport([.status(400, #"{"error": "max_tokens_exceeded"}"#), .ok(okBody)])
        let (provider, target) = provider(transport)
        await #expect(throws: DecisionProviderError.self) {
            try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        }
        #expect(await transport.requestCount == 1)
    }

    @Test("Recovery happens once: a second token-limit error is final")
    func recoveryOnce() async {
        let transport = MockDecisionTransport([
            .status(400, #"{"error": "max_tokens_exceeded"}"#), .status(400, #"{"error": "max_tokens_exceeded"}"#), .ok(okBody),
        ])
        let (provider, target) = provider(transport)
        let state = JSON.string(String(repeating: "evidence ", count: 200))
        await #expect(throws: DecisionProviderError.self) {
            try await provider.decide(DecisionFixtures.yesNoRequest(state: state), target: target)
        }
        #expect(await transport.requestCount == 2)
    }

    #if canImport(ImageIO)
    @Test("A 413 with image assets retries once with smaller images")
    func shrinkRetry() async throws {
        let transport = MockDecisionTransport([.status(413, "payload too large"), .ok(okBody)])
        let (provider, target) = provider(transport)
        let png = try DecisionImageNormalizerTests.makePNG(width: 1200, height: 900)
        var request = DecisionFixtures.yesNoRequest()
        request.assets = ["shot": DecisionImageAsset(mediaType: .png, data: png)]
        _ = try await provider.decide(request, target: target)
        let sizes = await transport.requests.compactMap { $0.jsonBody?[test: "assets"]?[test: "shot"]?[test: "data_base64"]?.testString?.count }
        #expect(sizes.count == 2)
        #expect(sizes[1] < sizes[0])
    }

    @Test("Images already at the window minimum cannot shrink further")
    func shrinkFloor() throws {
        let window = DecisionImageNormalizer.Window(edgePx: 280...1568, totalPixels: 78_400...2_458_624)
        let png = try DecisionImageNormalizerTests.makePNG(width: 280, height: 280)
        #expect(try DecisionImageNormalizer.shrink(DecisionImageAsset(mediaType: .png, data: png), window: window) == nil)
    }
    #endif

    @Test("A 413 without assets is permanent")
    func noAssets413() async {
        let transport = MockDecisionTransport([.status(413, "too large"), .ok(okBody)])
        let (provider, target) = provider(transport)
        await #expect(throws: DecisionProviderError.self) {
            try await provider.decide(DecisionFixtures.yesNoRequest(), target: target)
        }
        #expect(await transport.requestCount == 1)
    }
}

@Suite("Decision keep-warm and emulation cost")
struct DecisionKeepWarmAndCostTests {
    @Test("keepWarm pings the top candidate on an interval and stops when cancelled")
    func keepWarm() async {
        let transport = MockDecisionTransport(handler: { _ in .ok("{}") })
        let entry = DecisionFixtures.decider("d-1")
        let provider = HTTPDecisionProvider(
            manifest: DecisionFixtures.manifest("decider"), entries: [entry], transport: transport,
            retryExecutor: instantRetryExecutor(), credential: { _ in nil }
        )
        let dispatcher = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource([entry]),
            providers: StaticDecisionProviderResolver(["decider": provider]),
            roles: RoleBindingResolver(settings: [.gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide)]),
            logger: DecisionLogCapture().logger
        )
        let task = Task { await dispatcher.keepWarm(role: .gatekeeper, interval: .milliseconds(5)) }
        #expect(await HarnessAsyncTestSupport.waitUntil { await transport.requestCount >= 2 })
        task.cancel()
        await task.value
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/v1/models" })
    }

    @Test("Emulated decide calls bill output tokens at the chat model's output price")
    func emulatedSettlement() {
        let prices: PriceVector = [
            PriceComponent(unit: .inputToken, usd: 1, per: 1_000),
            PriceComponent(unit: .outputToken, usd: 4, per: 1_000),
        ]
        let usage = DecisionUsage(inputTokens: 100, outputTokens: 10)
        #expect(abs(DecisionCostEstimator.settleEmulated(prices: prices, usage: usage)! - 0.14) < 1e-12)
        #expect(abs(DecisionCostEstimator.settleEmulated(prices: prices, usage: DecisionUsage(inputTokens: 100))! - 0.1) < 1e-12)
        #expect(DecisionCostEstimator.settleEmulated(prices: [prices[0]], usage: usage) == nil)
        #expect(DecisionCostEstimator.settleEmulated(prices: [], usage: usage) == nil)
    }

    @Test("The dispatcher settles an emulated call with output tokens")
    func dispatcherEmulatedCost() async {
        var chat = DecisionFixtures.chatModel("chat-1")
        chat.prices = [
            PriceComponent(unit: .inputToken, usd: 1, per: 1_000),
            PriceComponent(unit: .outputToken, usd: 4, per: 1_000),
        ]
        let llm = ScriptedDecisionLLM(responses: [
            LLMResponse(content: #"{"safe": "yes"}"#, metadata: LLMMetadata(promptTokens: 100, completionTokens: 10)),
        ])
        let dispatcher = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource([chat]),
            providers: StaticDecisionProviderResolver([:]),
            roles: RoleBindingResolver(settings: [.gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide, pin: "chat-1")]),
            emulator: FixedEmulationProvider(llm: llm),
            logger: DecisionLogCapture().logger
        )
        let outcome = await dispatcher.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(abs((outcome.receipt.costUSD ?? 0) - 0.14) < 1e-12)
    }
}
