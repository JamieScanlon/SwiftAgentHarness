import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

// MARK: - Recording stubs

/// Records every authorize / recordCompletion invocation in arrival order, with optional
/// throw-on-authorize support so we can drive the reject path.
private actor RecordingBudgetAccounting: BudgetAccounting {
    enum Event: Equatable, Sendable {
        case authorize(modelID: UUID, conversationID: UUID?, accountID: UUID?, projectedCostUSD: Double?)
        case recordCompletion(modelID: UUID, conversationID: UUID?, accountID: UUID?, actualCostUSD: Double?)
    }

    private(set) var events: [Event] = []
    private let throwOnAuthorize: Error?

    init(throwOnAuthorize: Error? = nil) {
        self.throwOnAuthorize = throwOnAuthorize
    }

    func authorize(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        projectedCostUSD: Double?
    ) async throws {
        events.append(.authorize(modelID: modelID, conversationID: conversationID, accountID: accountID, projectedCostUSD: projectedCostUSD))
        if let throwOnAuthorize {
            throw throwOnAuthorize
        }
    }

    func recordCompletion(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        actualCostUSD: Double?
    ) async {
        events.append(.recordCompletion(modelID: modelID, conversationID: conversationID, accountID: accountID, actualCostUSD: actualCostUSD))
    }

    func observed() -> [Event] { events }
    func authorizeCount() -> Int { events.filter { if case .authorize = $0 { return true } else { return false } }.count }
    func settleCount() -> Int { events.filter { if case .recordCompletion = $0 { return true } else { return false } }.count }
}

/// Recording inner LLM. `behavior` controls send / generateImage outcomes; stream is
/// scripted similarly to `RetryingLLMStreamTests`.
private actor RecordingInnerLLM: LLMProtocol {
    enum Behavior: Sendable {
        case succeed(LLMResponse)
        case fail(Error)
    }
    enum ImageBehavior: Sendable {
        case succeed(ImageGenerationResponse)
        case fail(Error)
    }
    enum StreamScript: Sendable {
        case yieldThenComplete(partials: [String], finalText: String)
        case throwBeforeFirstChunk(Error)
    }

    private let behavior: Behavior
    private let imageBehavior: ImageBehavior
    private var streamScripts: [StreamScript]
    private(set) var sendCalls: Int = 0
    private(set) var generateImageCalls: Int = 0
    private(set) var streamCalls: Int = 0

    init(
        behavior: Behavior = .succeed(LLMResponse(content: "ok", toolCalls: [])),
        imageBehavior: ImageBehavior = .succeed(ImageGenerationResponse(images: [])),
        streamScripts: [StreamScript] = []
    ) {
        self.behavior = behavior
        self.imageBehavior = imageBehavior
        self.streamScripts = streamScripts
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "inner" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        sendCalls += 1
        switch behavior {
        case .succeed(let response): return response
        case .fail(let error): throw error
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        generateImageCalls += 1
        switch imageBehavior {
        case .succeed(let response): return response
        case .fail(let error): throw error
        }
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let script = await self.popStreamScript()
                switch script {
                case .none:
                    continuation.finish()
                case .yieldThenComplete(let partials, let finalText):
                    for partial in partials {
                        continuation.yield(.stream(LLMResponse(content: partial, toolCalls: [])))
                    }
                    continuation.yield(.complete(LLMResponse(content: finalText, toolCalls: [])))
                    continuation.finish()
                case .throwBeforeFirstChunk(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func popStreamScript() -> StreamScript? {
        streamCalls += 1
        guard !streamScripts.isEmpty else { return nil }
        return streamScripts.removeFirst()
    }

    func observed() -> (send: Int, image: Int, stream: Int) {
        (sendCalls, generateImageCalls, streamCalls)
    }
}

// MARK: - Tests

@Suite("BudgetEnforcingLLM authorize/settle pairing")
struct BudgetEnforcingLLMTests {
    private static let modelID = UUID()
    private static let conversationID = UUID()
    private static let policy: BudgetPolicy = .enabled(maxUSDPerCall: 0.1, maxUSDPerConversation: 1.0)

    private static func makeWrapper(
        accounting: any BudgetAccounting,
        inner: any LLMProtocol,
        modelCost: ModelCostBudget? = nil
    ) -> BudgetEnforcingLLM {
        BudgetEnforcingLLM(
            base: inner,
            accounting: accounting,
            policy: policy,
            modelID: modelID,
            conversationID: conversationID,
            modelCost: modelCost
        )
    }

    // MARK: - send

    @Test("send allow path: authorize then settle, base.send invoked, response surfaces")
    func sendAllowPath() async throws {
        let accounting = RecordingBudgetAccounting()
        let inner = RecordingInnerLLM(behavior: .succeed(LLMResponse(content: "hi", toolCalls: [])))
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        let response = try await wrapper.send([], config: LLMRequestConfig())

        #expect(response.content == "hi")
        let inner_calls = await inner.observed()
        #expect(inner_calls.send == 1)
        let events = await accounting.observed()
        #expect(events.count == 2)
        if case .authorize(let mid, let cid, _, let projected) = events[0] {
            #expect(mid == Self.modelID)
            #expect(cid == Self.conversationID)
            #expect(projected == nil)
        } else {
            Issue.record("Expected first event to be authorize, got \(events[0])")
        }
        if case .recordCompletion(let mid, let cid, _, let actual) = events[1] {
            #expect(mid == Self.modelID)
            #expect(cid == Self.conversationID)
            #expect(actual == nil)
        } else {
            Issue.record("Expected second event to be recordCompletion, got \(events[1])")
        }
    }

    @Test("send reject path: authorize throws → base not invoked, no settle, error rethrown")
    func sendRejectPath() async throws {
        let accounting = RecordingBudgetAccounting(throwOnAuthorize: LLMError.quotaExceeded)
        let inner = RecordingInnerLLM()
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        await #expect(throws: LLMError.self) {
            _ = try await wrapper.send([], config: LLMRequestConfig())
        }
        let inner_calls = await inner.observed()
        #expect(inner_calls.send == 0)
        let authorizeCount = await accounting.authorizeCount()
        let settleCount = await accounting.settleCount()
        #expect(authorizeCount == 1)
        #expect(settleCount == 0)
    }

    @Test("send forwards ownerAccountID to authorize and settle")
    func sendForwardsOwnerAccountID() async throws {
        let accounting = RecordingBudgetAccounting()
        let inner = RecordingInnerLLM(behavior: .succeed(LLMResponse(content: "ok", toolCalls: [])))
        let accountID = UUID()
        let wrapper = BudgetEnforcingLLM(
            base: inner,
            accounting: accounting,
            policy: Self.policy,
            modelID: Self.modelID,
            conversationID: Self.conversationID,
            ownerAccountID: accountID,
            modelCost: nil
        )
        _ = try await wrapper.send([], config: LLMRequestConfig())
        let events = await accounting.observed()
        #expect(events.count == 2)
        if case .authorize(_, _, let forwarded, _) = events[0] {
            #expect(forwarded == accountID)
        } else {
            Issue.record("Expected authorize event")
        }
        if case .recordCompletion(_, _, let forwarded, _) = events[1] {
            #expect(forwarded == accountID)
        } else {
            Issue.record("Expected recordCompletion event")
        }
    }

    @Test("send failure-after-authorize: settle called exactly once, base error rethrown")
    func sendFailureAfterAuthorizeSettlesOnce() async throws {
        let accounting = RecordingBudgetAccounting()
        let inner = RecordingInnerLLM(behavior: .fail(LLMError.invalidRequest("bad")))
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        await #expect(throws: LLMError.self) {
            _ = try await wrapper.send([], config: LLMRequestConfig())
        }
        let inner_calls = await inner.observed()
        #expect(inner_calls.send == 1)
        let authorizeCount = await accounting.authorizeCount()
        let settleCount = await accounting.settleCount()
        #expect(authorizeCount == 1)
        #expect(settleCount == 1)
    }

    @Test("send cancellation between authorize and base call releases reservation via settle")
    func sendCancellationSettlesZero() async throws {
        let accounting = RecordingBudgetAccounting()
        let inner = RecordingInnerLLM(behavior: .fail(CancellationError()))
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        await #expect(throws: CancellationError.self) {
            _ = try await wrapper.send([], config: LLMRequestConfig())
        }
        let authorizeCount = await accounting.authorizeCount()
        let settleCount = await accounting.settleCount()
        #expect(authorizeCount == 1)
        #expect(settleCount == 1)
    }

    @Test("send cost-aware path provides projected and actual USD values")
    func sendProjectedAndActualCost() async throws {
        let accounting = RecordingBudgetAccounting()
        let metadata = LLMMetadata(promptTokens: 200, completionTokens: 100, totalTokens: 300)
        let inner = RecordingInnerLLM(behavior: .succeed(LLMResponse(content: "hi", toolCalls: [], metadata: metadata)))
        let wrapper = Self.makeWrapper(
            accounting: accounting,
            inner: inner,
            modelCost: ModelCostBudget(inputPer1MUSD: 1.0, outputPer1MUSD: 2.0)
        )

        _ = try await wrapper.send(
            [Message(id: UUID(), role: .user, content: String(repeating: "a", count: 800), timestamp: Date(), toolCalls: [])],
            config: LLMRequestConfig(maxTokens: 2048)
        )

        let events = await accounting.observed()
        if case .authorize(_, _, _, let projected) = events[0] {
            #expect((projected ?? 0) > 0)
        } else {
            Issue.record("Expected first event to be authorize")
        }
        if case .recordCompletion(_, _, _, let actual) = events[1] {
            #expect(abs((actual ?? 0) - 0.0004) < 0.0000001)
        } else {
            Issue.record("Expected second event to be recordCompletion")
        }
    }

    // MARK: - generateImage

    @Test("generateImage allow path: authorize then settle, base invoked, response surfaces")
    func generateImageAllowPath() async throws {
        let accounting = RecordingBudgetAccounting()
        let inner = RecordingInnerLLM(imageBehavior: .succeed(ImageGenerationResponse(images: [])))
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        _ = try await wrapper.generateImage(ImageGenerationRequestConfig(prompt: "x"))

        let inner_calls = await inner.observed()
        #expect(inner_calls.image == 1)
        let authorizeCount = await accounting.authorizeCount()
        let settleCount = await accounting.settleCount()
        #expect(authorizeCount == 1)
        #expect(settleCount == 1)
    }

    @Test("generateImage reject path: authorize throws → base not invoked, no settle")
    func generateImageRejectPath() async throws {
        let accounting = RecordingBudgetAccounting(throwOnAuthorize: LLMError.quotaExceeded)
        let inner = RecordingInnerLLM()
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        await #expect(throws: LLMError.self) {
            _ = try await wrapper.generateImage(ImageGenerationRequestConfig(prompt: "x"))
        }
        let inner_calls = await inner.observed()
        #expect(inner_calls.image == 0)
        let settleCount = await accounting.settleCount()
        #expect(settleCount == 0)
    }

    @Test("generateImage cancellation releases reservation via settle")
    func generateImageCancellationSettlesZero() async throws {
        let accounting = RecordingBudgetAccounting()
        let inner = RecordingInnerLLM(imageBehavior: .fail(CancellationError()))
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        await #expect(throws: CancellationError.self) {
            _ = try await wrapper.generateImage(ImageGenerationRequestConfig(prompt: "x"))
        }
        let authorizeCount = await accounting.authorizeCount()
        let settleCount = await accounting.settleCount()
        #expect(authorizeCount == 1)
        #expect(settleCount == 1)
    }

    @Test("generateImage cost-aware path uses projected cost for authorize and settle")
    func generateImageProjectedCostPath() async throws {
        let accounting = RecordingBudgetAccounting()
        let inner = RecordingInnerLLM(imageBehavior: .succeed(ImageGenerationResponse(images: [])))
        let wrapper = Self.makeWrapper(
            accounting: accounting,
            inner: inner,
            modelCost: ModelCostBudget(inputPer1MUSD: 1.0, outputPer1MUSD: 2.0)
        )

        _ = try await wrapper.generateImage(ImageGenerationRequestConfig(prompt: String(repeating: "x", count: 400)))
        let events = await accounting.observed()
        #expect(events.count == 2)
        if case .authorize(_, _, _, let projected) = events[0] {
            #expect((projected ?? 0) > 0)
        } else {
            Issue.record("Expected authorize event")
        }
        if case .recordCompletion(_, _, _, let actual) = events[1] {
            #expect(actual == eventsProjectedCost(events: events))
        } else {
            Issue.record("Expected recordCompletion event")
        }
    }

    // MARK: - stream

    @Test("stream allow path: authorize, partials yield, settle on finish")
    func streamAllowPath() async throws {
        let accounting = RecordingBudgetAccounting()
        let inner = RecordingInnerLLM(streamScripts: [
            .yieldThenComplete(partials: ["a", "b"], finalText: "ab"),
        ])
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        var partials: [String] = []
        var final: String?
        for try await result in wrapper.stream([], config: LLMRequestConfig()) {
            switch result {
            case .stream(let p): partials.append(p.content)
            case .complete(let f): final = f.content
            }
        }
        #expect(partials == ["a", "b"])
        #expect(final == "ab")
        let inner_calls = await inner.observed()
        #expect(inner_calls.stream == 1)
        let authorizeCount = await accounting.authorizeCount()
        let settleCount = await accounting.settleCount()
        #expect(authorizeCount == 1)
        #expect(settleCount == 1)
    }

    @Test("stream reject pre-iteration: consumer sees thrown error, no partials, no settle")
    func streamRejectPreIteration() async throws {
        let accounting = RecordingBudgetAccounting(throwOnAuthorize: LLMError.quotaExceeded)
        let inner = RecordingInnerLLM(streamScripts: [
            .yieldThenComplete(partials: ["unused"], finalText: "unused"),
        ])
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        var partials: [String] = []
        var thrown: Error?
        do {
            for try await result in wrapper.stream([], config: LLMRequestConfig()) {
                if case .stream(let p) = result { partials.append(p.content) }
            }
        } catch {
            thrown = error
        }
        #expect(partials.isEmpty)
        #expect(thrown is LLMError)
        let inner_calls = await inner.observed()
        #expect(inner_calls.stream == 0)
        let settleCount = await accounting.settleCount()
        #expect(settleCount == 0)
    }

    @Test("stream failure-after-authorize: settle called exactly once, error surfaces")
    func streamFailureAfterAuthorizeSettlesOnce() async throws {
        let accounting = RecordingBudgetAccounting()
        let inner = RecordingInnerLLM(streamScripts: [
            .throwBeforeFirstChunk(LLMError.invalidRequest("bad")),
        ])
        let wrapper = Self.makeWrapper(accounting: accounting, inner: inner)

        var thrown: Error?
        do {
            for try await _ in wrapper.stream([], config: LLMRequestConfig()) {}
        } catch {
            thrown = error
        }
        #expect(thrown is LLMError)
        let inner_calls = await inner.observed()
        #expect(inner_calls.stream == 1)
        let authorizeCount = await accounting.authorizeCount()
        let settleCount = await accounting.settleCount()
        #expect(authorizeCount == 1)
        #expect(settleCount == 1)
    }
}

private func eventsProjectedCost(events: [RecordingBudgetAccounting.Event]) -> Double? {
    guard case .authorize(_, _, _, let projected)? = events.first else { return nil }
    return projected
}
