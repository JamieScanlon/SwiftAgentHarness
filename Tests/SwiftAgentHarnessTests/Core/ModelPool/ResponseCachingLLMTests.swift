import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor CacheScriptedLLM: LLMProtocol {
    private var sendQueue: [LLMResponse]
    private(set) var sendCalls: Int = 0

    init(sendQueue: [LLMResponse]) {
        self.sendQueue = sendQueue
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "cache-stub" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }
    nonisolated func getRequestFeatures() -> ModelRequestFeatures {
        ModelRequestFeatures(
            streaming: true,
            responseFormats: [.text],
            parallelToolCalls: .unsupported,
            reasoningEfforts: []
        )
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        sendCalls += 1
        guard !sendQueue.isEmpty else {
            return LLMResponse(content: "default", toolCalls: [])
        }
        return sendQueue.removeFirst()
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        return ImageGenerationResponse(images: [])
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func observedSendCalls() -> Int { sendCalls }
}

private final class CacheTestClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

@Suite("ResponseCachingLLM")
struct ResponseCachingLLMTests {
    private static func message(_ text: String) -> Message {
        Message(id: UUID(), role: .user, content: text, timestamp: Date(), toolCalls: [])
    }

    @Test("cache hit returns first response without second base call")
    func cacheHitOnSecondSend() async throws {
        let base = CacheScriptedLLM(sendQueue: [
            LLMResponse(content: "first", toolCalls: []),
            LLMResponse(content: "second", toolCalls: []),
        ])
        let llm = ResponseCachingLLM(
            base: base,
            store: ResponseCacheStore(),
            modelID: UUID(),
            providerScopeKey: "provider#a",
            policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil)
        )
        let messages = [Self.message("hello")]
        let r1 = try await llm.send(messages, config: LLMRequestConfig())
        let r2 = try await llm.send(messages, config: LLMRequestConfig())
        #expect(r1.content == "first")
        #expect(r2.content == "first")
        #expect(await base.observedSendCalls() == 1)
    }

    @Test("ttl expiry triggers base call again")
    func ttlExpiryMisses() async throws {
        let base = CacheScriptedLLM(sendQueue: [
            LLMResponse(content: "first", toolCalls: []),
            LLMResponse(content: "second", toolCalls: []),
        ])
        let clock = CacheTestClock(now: Date(timeIntervalSince1970: 0))
        let store = ResponseCacheStore(now: { clock.now })
        let llm = ResponseCachingLLM(
            base: base,
            store: store,
            modelID: UUID(),
            providerScopeKey: "provider#a",
            policy: .enabled(maxEntries: 8, ttlSeconds: 1.0, stablePrefixMessageCount: nil)
        )
        let messages = [Self.message("hello")]
        let r1 = try await llm.send(messages, config: LLMRequestConfig())
        clock.now = Date(timeIntervalSince1970: 3)
        let r2 = try await llm.send(messages, config: LLMRequestConfig())
        #expect(r1.content == "first")
        #expect(r2.content == "second")
        #expect(await base.observedSendCalls() == 2)
    }

    @Test("provider scope key isolates cache entries")
    func providerScopeIsolation() async throws {
        let sharedStore = ResponseCacheStore()
        let modelID = UUID()
        let a = CacheScriptedLLM(sendQueue: [LLMResponse(content: "provider-a", toolCalls: [])])
        let b = CacheScriptedLLM(sendQueue: [LLMResponse(content: "provider-b", toolCalls: [])])
        let llmA = ResponseCachingLLM(
            base: a,
            store: sharedStore,
            modelID: modelID,
            providerScopeKey: "provider#a",
            policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil)
        )
        let llmB = ResponseCachingLLM(
            base: b,
            store: sharedStore,
            modelID: modelID,
            providerScopeKey: "provider#b",
            policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil)
        )
        let messages = [Self.message("hello")]
        let ra = try await llmA.send(messages, config: LLMRequestConfig())
        let rb = try await llmB.send(messages, config: LLMRequestConfig())
        #expect(ra.content == "provider-a")
        #expect(rb.content == "provider-b")
        #expect(await a.observedSendCalls() == 1)
        #expect(await b.observedSendCalls() == 1)
    }

    @Test("wrapper forwards request features")
    func forwardsRequestFeatures() {
        let base = CacheScriptedLLM(sendQueue: [])
        let llm = ResponseCachingLLM(
            base: base,
            store: ResponseCacheStore(),
            modelID: UUID(),
            providerScopeKey: "provider#a",
            policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil)
        )
        #expect(llm.getRequestFeatures().responseFormats == [.text])
    }

    @Test("owner scope key isolates cache entries under strict tenancy")
    func ownerScopeIsolation() async throws {
        let sharedStore = ResponseCacheStore()
        let modelID = UUID()
        let ownerA = UUID()
        let ownerB = UUID()
        let scopeA = ResponseCacheOwnerScope.resolve(
            ownerAccountID: ownerA,
            tenancyPolicy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
        )!
        let scopeB = ResponseCacheOwnerScope.resolve(
            ownerAccountID: ownerB,
            tenancyPolicy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
        )!
        let baseA = CacheScriptedLLM(sendQueue: [LLMResponse(content: "owner-a", toolCalls: [])])
        let baseB = CacheScriptedLLM(sendQueue: [LLMResponse(content: "owner-b", toolCalls: [])])
        let llmA = ResponseCachingLLM(
            base: baseA,
            store: sharedStore,
            modelID: modelID,
            providerScopeKey: "provider#a",
            policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil),
            cacheOwnerScopeKey: scopeA
        )
        let llmB = ResponseCachingLLM(
            base: baseB,
            store: sharedStore,
            modelID: modelID,
            providerScopeKey: "provider#a",
            policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil),
            cacheOwnerScopeKey: scopeB
        )
        let messages = [Self.message("hello")]
        let ra = try await llmA.send(messages, config: LLMRequestConfig())
        let rb = try await llmB.send(messages, config: LLMRequestConfig())
        #expect(ra.content == "owner-a")
        #expect(rb.content == "owner-b")
        #expect(await baseA.observedSendCalls() == 1)
        #expect(await baseB.observedSendCalls() == 1)
    }

    @Test("empty owner scope shares cache entries in non-strict deployments")
    func sharedNonStrictOwnerScope() async throws {
        let sharedStore = ResponseCacheStore()
        let modelID = UUID()
        let baseA = CacheScriptedLLM(sendQueue: [LLMResponse(content: "shared", toolCalls: [])])
        let baseB = CacheScriptedLLM(sendQueue: [LLMResponse(content: "other", toolCalls: [])])
        let llmA = ResponseCachingLLM(
            base: baseA,
            store: sharedStore,
            modelID: modelID,
            providerScopeKey: "provider#a",
            policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil),
            cacheOwnerScopeKey: ""
        )
        let llmB = ResponseCachingLLM(
            base: baseB,
            store: sharedStore,
            modelID: modelID,
            providerScopeKey: "provider#a",
            policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil),
            cacheOwnerScopeKey: ""
        )
        let messages = [Self.message("hello")]
        _ = try await llmA.send(messages, config: LLMRequestConfig())
        let r2 = try await llmB.send(messages, config: LLMRequestConfig())
        #expect(r2.content == "shared")
        #expect(await baseA.observedSendCalls() == 1)
        #expect(await baseB.observedSendCalls() == 0)
    }

    @Test("strict tenancy without owner bypasses cache")
    func strictNilOwnerBypassesCache() async throws {
        let base = CacheScriptedLLM(sendQueue: [
            LLMResponse(content: "first", toolCalls: []),
            LLMResponse(content: "second", toolCalls: []),
        ])
        let llm = ResponseCachingLLM(
            base: base,
            store: ResponseCacheStore(),
            modelID: UUID(),
            providerScopeKey: "provider#a",
            policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil),
            cacheOwnerScopeKey: nil
        )
        let messages = [Self.message("hello")]
        let r1 = try await llm.send(messages, config: LLMRequestConfig())
        let r2 = try await llm.send(messages, config: LLMRequestConfig())
        #expect(r1.content == "first")
        #expect(r2.content == "second")
        #expect(await base.observedSendCalls() == 2)
    }

    @Test("ResponseCacheOwnerScope produces distinct keys for different owners")
    func ownerScopeResolverDistinctOwners() {
        let strict = TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
        let ownerA = UUID()
        let ownerB = UUID()
        let scopeA = ResponseCacheOwnerScope.resolve(ownerAccountID: ownerA, tenancyPolicy: strict)
        let scopeB = ResponseCacheOwnerScope.resolve(ownerAccountID: ownerB, tenancyPolicy: strict)
        #expect(scopeA != scopeB)
        #expect(scopeA == AgentMemoryPathResolver.ownerSegment(ownerA))
        #expect(ResponseCacheOwnerScope.resolve(ownerAccountID: nil, tenancyPolicy: strict) == nil)
        #expect(ResponseCacheOwnerScope.resolve(ownerAccountID: ownerA, tenancyPolicy: .disabled) == "")
    }
}

