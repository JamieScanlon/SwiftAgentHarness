import Foundation
import Logging

/// A `decide` provider that speaks SystemOne or OpenAI Decisions over HTTP. The surface on each binding's
/// `decide` profile selects the codec, and per-server quirks come from that profile's features and limits.
public struct HTTPDecisionProvider: DecisionProviding {
    public typealias CredentialResolver = @Sendable (ProviderBinding) throws -> String?

    public let manifest: ProviderManifest
    private let entries: [ModelRegistryEntry]
    private let transport: any DecisionHTTPTransport
    private let retryExecutor: DecisionRetryExecutor
    private let credential: CredentialResolver

    public init(
        manifest: ProviderManifest,
        entries: [ModelRegistryEntry],
        transport: any DecisionHTTPTransport = URLSessionDecisionTransport(),
        retryExecutor: DecisionRetryExecutor = DecisionRetryExecutor(),
        credential: CredentialResolver? = nil,
        authStore: AuthProfileStore = .production()
    ) {
        self.manifest = manifest
        self.entries = entries
        self.transport = transport
        self.retryExecutor = retryExecutor
        self.credential = credential ?? { binding in
            let resolved = try authStore.resolveCredential(
                providerID: binding.providerId,
                authProfileLabel: binding.authProfile
            )
            return resolved.bearerToken.isEmpty ? nil : resolved.bearerToken
        }
    }

    public func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry] {
        entries
    }

    public func decide(_ request: DecisionRequest, target: DecisionDispatchTarget) async throws -> DecisionResult {
        try request.validate()
        let codec = try Self.codec(for: target.profile.surface)
        let options = DecisionSurfaceOptions(profile: target.profile)
        if let kind = request.questionKinds.subtracting(options.questionKinds).sorted(by: { $0.rawValue < $1.rawValue }).first {
            throw DecisionProviderError.unsupportedQuestionKind(kind, surface: target.profile.surface)
        }
        let bearer = try credential(target.binding)
        let prepared = try Self.normalizingImages(request, options: options)
        let chunks = Self.split(prepared, maxQuestions: options.maxQuestionsPerCall)

        let responses = try await withThrowingTaskGroup(of: (Int, [ChunkResponse]).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    let response = try await send(
                        chunk, codec: codec, options: options, target: target, bearer: bearer, allowSplit: true
                    )
                    return (index, response)
                }
            }
            var ordered: [(Int, [ChunkResponse])] = []
            for try await item in group { ordered.append(item) }
            return ordered.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }

        let versions = Set(responses.compactMap(\.decoded.modelVersion))
        guard versions.count <= 1 else {
            throw DecisionProviderError.inconsistentModelVersions(versions.sorted())
        }
        var raw: [String: DecisionAnswer] = [:]
        var usage = DecisionUsage()
        for response in responses {
            raw.merge(response.decoded.answers) { first, _ in first }
            usage = usage + response.decoded.usage
        }
        return DecisionResult(
            modelVersion: versions.first ?? target.binding.endpointModelId,
            calibrated: true,
            guarantee: .calibratedDistribution,
            answers: DecisionAnswerValidator.reconcile(request: request, raw: raw),
            usage: usage,
            requestIDs: responses.compactMap(\.requestID)
        )
    }

    public func failoverError(_ error: Error) -> ProviderFailoverClassification {
        DecisionErrorClassifier.classify(error)
    }

    public func warmConnections(target: DecisionDispatchTarget) async {
        var request = URLRequest(url: DecisionEndpoint.url(base: target.binding.serverURL, path: "v1/models"))
        request.httpMethod = "GET"
        if let bearer = try? credential(target.binding) {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await transport.send(request)
    }

    // MARK: - Internals

    private struct ChunkResponse: Sendable {
        var decoded: DecodedDecisionResponse
        var requestID: String?
    }

    static func codec(for surface: ContractSurface) throws -> any DecisionWireCodec {
        switch surface {
        case .systemOne: return SystemOneDecisionCodec()
        case .openAIDecisions: return OpenAIDecisionsCodec()
        default: throw DecisionProviderError.unsupportedSurface(surface)
        }
    }

    /// Answers are independent, so questions split across requests and merge back by id.
    static func split(_ request: DecisionRequest, maxQuestions: Int?) -> [DecisionRequest] {
        guard let maxQuestions, maxQuestions > 0, request.questions.count > maxQuestions else { return [request] }
        return stride(from: 0, to: request.questions.count, by: maxQuestions).map { start in
            var chunk = request
            chunk.questions = Array(request.questions[start..<min(start + maxQuestions, request.questions.count)])
            return chunk
        }
    }

    static func normalizingImages(_ request: DecisionRequest, options: DecisionSurfaceOptions) throws -> DecisionRequest {
        guard let window = options.imageWindow, !request.assets.isEmpty else { return request }
        var normalized = request
        for (key, asset) in request.assets {
            normalized.assets[key] = try DecisionImageNormalizer.normalize(asset, window: window)
        }
        return normalized
    }

    private func send(
        _ chunk: DecisionRequest,
        codec: any DecisionWireCodec,
        options: DecisionSurfaceOptions,
        target: DecisionDispatchTarget,
        bearer: String?,
        allowSplit: Bool
    ) async throws -> [ChunkResponse] {
        let encoded = try codec.encode(chunk, modelID: target.binding.endpointModelId, options: options)
        var urlRequest = URLRequest(url: DecisionEndpoint.url(base: target.binding.serverURL, path: options.path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(encoded.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in encoded.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let header = options.longContextOptInHeader, let standard = options.standardContextTokens,
           DecisionCostEstimator.estimateInputTokens(characterCount: encoded.body.count) > standard {
            urlRequest.setValue("true", forHTTPHeaderField: header)
        }
        if options.gzip, encoded.body.count > DecisionBodyCompression.threshold {
            urlRequest.httpBody = try DecisionBodyCompression.gzip(encoded.body)
            urlRequest.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            urlRequest.httpBody = encoded.body
        }

        do {
            let (data, response) = try await retryExecutor.execute(urlRequest, transport: transport, budget: target.timeBudget)
            let decoded = try codec.decode(data, request: chunk, options: options)
            return [ChunkResponse(decoded: decoded, requestID: DecisionRetryExecutor.requestID(from: response))]
        } catch let error as DecisionProviderError {
            // A token-limit 400 may be retried once by splitting the questions across two requests.
            guard allowSplit, chunk.questions.count > 1, DecisionErrorClassifier.classify(error) == .contextOverflow else {
                throw error
            }
            let half = chunk.questions.count / 2
            var first = chunk
            first.questions = Array(chunk.questions[..<half])
            var second = chunk
            second.questions = Array(chunk.questions[half...])
            let a = try await send(first, codec: codec, options: options, target: target, bearer: bearer, allowSplit: false)
            let b = try await send(second, codec: codec, options: options, target: target, bearer: bearer, allowSplit: false)
            return a + b
        }
    }
}
