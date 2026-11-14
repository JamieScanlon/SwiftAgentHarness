import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
@testable import SwiftAgentHarness

// MARK: - HTTP

/// Scripted HTTP transport that records every request.
actor MockDecisionTransport: DecisionHTTPTransport {
    enum Step: Sendable {
        case reply(status: Int, body: String, headers: [String: String])
        case fail(URLError.Code)

        static func ok(_ body: String, headers: [String: String] = [:]) -> Step {
            .reply(status: 200, body: body, headers: headers)
        }

        static func status(_ code: Int, _ body: String = "{}", headers: [String: String] = [:]) -> Step {
            .reply(status: code, body: body, headers: headers)
        }
    }

    private var steps: [Step]
    private let handler: (@Sendable (URLRequest) -> Step)?
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
        self.handler = nil
    }

    init(handler: @escaping @Sendable (URLRequest) -> Step) {
        self.steps = []
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let step: Step
        if let handler {
            step = handler(request)
        } else if !steps.isEmpty {
            step = steps.removeFirst()
        } else {
            step = .status(500, "{\"error\":\"script exhausted\"}")
        }
        switch step {
        case .reply(let status, let body, let headers):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (Data(body.utf8), response)
        case .fail(let code):
            throw URLError(code)
        }
    }

    var requestCount: Int { requests.count }
}

extension URLRequest {
    /// Decoded JSON body (uncompressed, JSON content type only).
    var jsonBody: JSON? {
        guard let httpBody else { return nil }
        return try? JSONDecoder().decode(JSON.self, from: httpBody)
    }

    var bodyString: String {
        httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

extension JSON {
    subscript(test key: String) -> JSON? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    subscript(test index: Int) -> JSON? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    var testString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var testNumber: Double? {
        switch self {
        case .double(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    var testArray: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var testObject: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

/// Retry executor that never sleeps and uses a fixed jitter.
func instantRetryExecutor(
    _ policy: DecisionRetryPolicy = DecisionRetryPolicy(maxAttempts: 4, totalBudget: .seconds(60))
) -> DecisionRetryExecutor {
    DecisionRetryExecutor(policy: policy, sleep: { _ in }, jitter: { 0.5 })
}

// MARK: - Providers

/// Counts calls without shared global state.
actor CallCounter {
    private(set) var count = 0
    private(set) var targets: [String] = []

    func record(_ target: String) {
        count += 1
        targets.append(target)
    }
}

/// Decision provider whose answers come from a closure.
struct FakeDecisionProvider: DecisionProviding {
    typealias Handler = @Sendable (DecisionRequest, DecisionDispatchTarget) async throws -> DecisionResult

    let manifest: ProviderManifest
    let entries: [ModelRegistryEntry]
    let counter: CallCounter
    let handler: Handler

    init(providerID: ProviderID, entries: [ModelRegistryEntry] = [], counter: CallCounter = CallCounter(), handler: @escaping Handler) {
        self.manifest = DecisionFixtures.manifest(providerID)
        self.entries = entries
        self.counter = counter
        self.handler = handler
    }

    func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry] {
        entries
    }

    func decide(_ request: DecisionRequest, target: DecisionDispatchTarget) async throws -> DecisionResult {
        await counter.record(target.binding.endpointModelId)
        return try await handler(request, target)
    }

    /// Answers every yes-no question with `pYes`.
    static func constant(providerID: ProviderID, pYes: Double, version: String? = nil, inputTokens: Int = 100, counter: CallCounter = CallCounter()) -> FakeDecisionProvider {
        FakeDecisionProvider(providerID: providerID, counter: counter) { request, target in
            var answers: [String: DecisionAnswer] = [:]
            for item in request.questions { answers[item.id] = .yesNo(pYes: pYes) }
            return DecisionResult(
                modelVersion: version ?? target.binding.endpointModelId,
                calibrated: true,
                guarantee: .calibratedDistribution,
                answers: answers,
                usage: DecisionUsage(inputTokens: inputTokens, outputTokens: 0),
                requestIDs: ["req-\(target.binding.endpointModelId)"]
            )
        }
    }

    static func failing(providerID: ProviderID, status: Int, counter: CallCounter = CallCounter()) -> FakeDecisionProvider {
        FakeDecisionProvider(providerID: providerID, counter: counter) { _, _ in
            throw DecisionProviderError.http(status: status, body: "{}", requestID: nil)
        }
    }
}

// MARK: - LLM

/// Scripted `generate` model for the emulation codec.
actor ScriptedDecisionLLM: LLMProtocol {
    private var responses: [LLMResponse]
    private(set) var configs: [LLMRequestConfig] = []
    private(set) var prompts: [[Message]] = []
    nonisolated let name: String

    init(name: String = "chat-emulator-1", responses: [LLMResponse]) {
        self.name = name
        self.responses = responses
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { name }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        configs.append(config)
        prompts.append(messages)
        guard !responses.isEmpty else { throw LLMError.invalidRequest("no scripted response") }
        return responses.removeFirst()
    }

    nonisolated func stream(_: [Message], config _: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func generateImage(_: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        throw LLMError.unsupportedCapability(.imageGeneration)
    }

    var callCount: Int { configs.count }

    static func logprobs(_ pairs: [(String, Double)], content: String? = nil, promptTokens: Int = 50) -> LLMResponse {
        let candidates: [JSON] = pairs.map { .object(["token": .string($0.0), "logprob": .double(log($0.1))]) }
        return LLMResponse(
            content: content ?? pairs.first?.0 ?? "",
            metadata: LLMMetadata(
                promptTokens: promptTokens,
                completionTokens: 1,
                modelMetadata: .object([LLMEmulationDecisionCodec.topLogprobsMetadataKey: .array(candidates)])
            )
        )
    }
}

struct FixedEmulationProvider: DecisionEmulationLLMProviding {
    let llm: any LLMProtocol

    func emulationLLM(for entry: ModelRegistryEntry) async throws -> any LLMProtocol {
        llm
    }
}

// MARK: - Scheduler / budget

actor RecordingScheduler: ModelCallScheduling {
    private(set) var reservations: [ModelCallReservation] = []
    private(set) var releases = 0

    func acquire(for modelID: UUID, priority: ModelRequestPriority) async {}
    func release(for modelID: UUID) async {}
    func inFlightCount(for modelID: UUID) async -> Int { 0 }

    func acquire(reservation: ModelCallReservation) async -> ModelCallAcquisition {
        reservations.append(reservation)
        return ModelCallAcquisition(modelID: reservation.modelID, credentialKey: nil, ownerScopeKey: nil, reservedRequestUnits: 0, reservedTokenUnits: 0)
    }

    func release(acquisition: ModelCallAcquisition) async {
        releases += 1
    }
}

struct DenyingBudget: BudgetAccounting {
    struct Denied: Error {}

    func authorize(policy: BudgetPolicy, modelID: UUID, conversationID: UUID?, accountID: UUID?, projectedCostUSD: Double?) async throws {
        throw Denied()
    }

    func recordCompletion(policy: BudgetPolicy, modelID: UUID, conversationID: UUID?, accountID: UUID?, actualCostUSD: Double?) async {}
}

actor RecordingBudget: BudgetAccounting {
    private(set) var projected: [Double?] = []
    private(set) var settled: [Double?] = []

    func authorize(policy: BudgetPolicy, modelID: UUID, conversationID: UUID?, accountID: UUID?, projectedCostUSD: Double?) async throws {
        projected.append(projectedCostUSD)
    }

    func recordCompletion(policy: BudgetPolicy, modelID: UUID, conversationID: UUID?, accountID: UUID?, actualCostUSD: Double?) async {
        settled.append(actualCostUSD)
    }
}

// MARK: - Fixtures

enum DecisionFixtures {
    static let baseURL = URL(string: "https://decider.example")!

    static func manifest(_ providerID: ProviderID, envVars: [String] = ["DECIDER_KEY"]) -> ProviderManifest {
        ProviderManifest(
            id: providerID,
            label: providerID,
            providerEndpoints: [ProviderEndpoint(id: "\(providerID)-default", baseURL: baseURL)],
            providerAuthChoices: envVars.isEmpty ? [] : [ProviderAuthChoice(id: "api-key", label: "Key", envVars: envVars)],
            modelSupport: ProviderModelSupport(modelPrefixes: []),
            capabilitySlots: [.decision]
        )
    }

    static func decider(
        _ endpointModelID: String,
        provider: ProviderID = "decider",
        profile: ContractProfile = DecisionProfiles.systemOne(),
        compatGroup: String? = "decider-family",
        lifecycle: ModelLifecycle = .active,
        locality: ModelLocality? = .vendor,
        roles: [String] = [],
        prices: PriceVector = [PriceComponent(unit: .inputToken, usd: 0.10, per: 1_000_000)],
        family: String? = "decider",
        performance: ModelObservedPerformance? = nil,
        serverURL: URL = baseURL
    ) -> ModelRegistryEntry {
        ModelRegistryEntry(
            id: UUID(),
            family: family,
            displayName: endpointModelID,
            capabilities: [],
            providers: [ProviderBinding(
                providerId: provider, modelProtocol: .openAIAPI, endpointModelId: endpointModelID, serverURL: serverURL
            )],
            performance: performance,
            contracts: [profile],
            compatGroup: compatGroup,
            lifecycle: lifecycle,
            prices: prices,
            locality: locality,
            roles: roles
        )
    }

    static func chatModel(_ endpointModelID: String, logprobs: Bool = false) -> ModelRegistryEntry {
        var entry = ModelRegistryEntry(
            id: UUID(),
            family: "chat",
            displayName: endpointModelID,
            capabilities: [.completion, .tools],
            requestFeatures: ModelRequestFeatures(streaming: true, responseFormats: [.text, .jsonSchema], parallelToolCalls: .unsupported, reasoningEfforts: []),
            maxContextLength: 128_000,
            providers: [ProviderBinding(
                providerId: "chat", modelProtocol: .openAIAPI, endpointModelId: endpointModelID,
                serverURL: URL(string: "https://chat.example/v1")!
            )]
        )
        if logprobs {
            var generate = entry.synthesizedGenerateProfile
            generate.features["logprobs"] = FeatureSupport()
            entry.contracts = [generate]
        }
        return entry
    }

    static func yesNoRequest(_ ids: [String] = ["safe"], state: JSON = .string("rm -rf build/")) -> DecisionRequest {
        DecisionRequest(
            state: state,
            questions: ids.map { DecisionQuestionItem($0, .yesNo(instructions: .string("Is the action safe?"))) }
        )
    }

    /// Act at p ≥ 0.9, confirm in [0.5, 0.9), refuse below 0.5, for each listed version.
    static func gatePolicy(
        versions: [String],
        question: String = "safe",
        escalate: DecisionEscalation? = nil,
        acceptsUncalibrated: Bool = false
    ) -> DecisionPolicy {
        let bands = DecisionBands.ranges(
            refuse: DecisionRange(0, 0.5, upperOpen: true),
            confirm: DecisionRange(0.5, 0.9, upperOpen: true),
            act: DecisionRange(0.9, 1)
        )
        return DecisionPolicy(
            question: question,
            bands: Dictionary(uniqueKeysWithValues: versions.map { ($0, bands) }),
            acceptsUncalibrated: acceptsUncalibrated,
            escalate: escalate
        )
    }
}
