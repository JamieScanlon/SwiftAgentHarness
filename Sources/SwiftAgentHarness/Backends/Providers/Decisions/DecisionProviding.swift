import Foundation
import Logging

/// What a decision provider needs to answer one request on one binding.
public struct DecisionDispatchTarget: Sendable {
    public var entry: ModelRegistryEntry
    public var binding: ProviderBinding
    /// The `decide` profile this binding serves (model profile narrowed by the binding).
    public var profile: ContractProfile
    /// Total time budget across retries for this call.
    public var timeBudget: Duration?

    public init(entry: ModelRegistryEntry, binding: ProviderBinding, profile: ContractProfile, timeBudget: Duration? = nil) {
        self.entry = entry
        self.binding = binding
        self.profile = profile
        self.timeBudget = timeBudget
    }
}

/// Provider-side half of the `decide` contract (spec: the `decision` slot). The provider encodes and classifies;
/// the Pool selects, falls back, cascades, budgets, and emits receipts.
public protocol DecisionProviding: Sendable {
    var manifest: ProviderManifest { get }

    /// Registry rows carrying a `decide` contract profile.
    func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry]

    func decide(_ request: DecisionRequest, target: DecisionDispatchTarget) async throws -> DecisionResult

    func failoverError(_ error: Error) -> ProviderFailoverClassification

    /// Pre-connect so the first ~100 ms call does not pay a cold TLS handshake.
    func warmConnections(target: DecisionDispatchTarget) async
}

public extension DecisionProviding {
    func failoverError(_ error: Error) -> ProviderFailoverClassification {
        DecisionErrorClassifier.classify(error)
    }

    func warmConnections(target: DecisionDispatchTarget) async {}
}

/// Errors raised by decision codecs and transports.
public enum DecisionProviderError: Error, Sendable, Equatable {
    case http(status: Int, body: String, requestID: String?)
    case invalidResponse(String)
    case unsupportedQuestionKind(DecisionQuestionKind, surface: ContractSurface)
    case unsupportedSurface(ContractSurface)
    case inconsistentModelVersions([String])
    case image(String)
    case missingCredential(ProviderID)
    case timeBudgetExhausted
}

/// Maps decision errors onto the provider failover taxonomy (spec: decision-models § Transport).
public enum DecisionErrorClassifier {
    public static func classify(_ error: Error) -> ProviderFailoverClassification {
        if error is CancellationError { return .permanent }
        if let decisionError = error as? DecisionProviderError {
            switch decisionError {
            case .http(let status, let body, _):
                return classify(status: status, body: body)
            case .timeBudgetExhausted:
                return .transient
            case .missingCredential:
                return .authError
            case .invalidResponse, .unsupportedQuestionKind, .unsupportedSurface, .inconsistentModelVersions, .image:
                return .permanent
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .permanent : .transient
        }
        if let authError = error as? AuthProfileStoreError {
            switch authError {
            case .credentialNotFound, .credentialExpired, .credentialRequiresOnboarding:
                return .authError
            case .manifestNotFound, .refreshNotImplemented:
                return .permanent
            }
        }
        return DefaultProviderFailoverClassifier.classify(error)
    }

    public static func classify(status: Int, body: String) -> ProviderFailoverClassification {
        switch status {
        case 401, 403:
            return .authError
        case 400:
            return isTokenLimit(body) ? .contextOverflow : .permanent
        case 404:
            return .modelNotFound
        case 408, 529:
            return .transient
        case 413, 415, 422:
            return .permanent
        case 429:
            return .rateLimited
        case 500...599:
            return .transient
        default:
            return .permanent
        }
    }

    public static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || status == 529 || (500...599).contains(status)
    }

    static func isTokenLimit(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("max_tokens_exceeded")
            || lowered.contains("context_length_exceeded")
            || lowered.contains("token limit")
            || (lowered.contains("too many") && lowered.contains("tokens"))
    }
}
