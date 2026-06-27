import Foundation
import SwiftAgentKit

/// Optional retry-after hint for rate-limited responses when adapter transport exposes it.
public struct RetryAfterRateLimitError: Error, Sendable {
    public let retryAfterSeconds: Double?
    public let underlying: Error

    public init(retryAfterSeconds: Double?, underlying: Error = LLMError.rateLimitExceeded) {
        self.retryAfterSeconds = retryAfterSeconds
        self.underlying = underlying
    }
}

/// Outcome of inspecting a thrown error to decide whether ``RetryingLLM`` should retry.
///
/// `transient` means the error is plausibly self-healing (rate limits, timeouts, dropped
/// connections) and a backoff retry is appropriate. `terminal` means the error is
/// caller-actionable or definitive (auth failure, missing model, bad request) and retrying
/// would just burn budget.
public enum RetryDecision: Equatable, Sendable {
    case transient
    case terminal
}

/// Decision for advancing across ordered provider bindings.
public enum BindingFailoverDecision: Equatable, Sendable {
    case tryNextBinding
    case terminal
}

/// Pure mapping from thrown errors to ``RetryDecision``.
///
/// Recognizes ``LLMError`` (recursing through ``LLMError/networkError(_:)``) and `URLError`
/// families. Anything unrecognized — including `CancellationError`, bare `NSError`, or
/// upstream-client error types — is treated as `.terminal`. Cancellation must NOT be
/// retried (the caller asked us to stop), and unknown errors are treated conservatively so
/// we don't accidentally retry a budget-burning failure.
public enum TransientErrorClassifier {
    public static func classify(_ error: Error) -> RetryDecision {
        if error is CancellationError { return .terminal }

        if let hinted = error as? RetryAfterRateLimitError {
            return classify(hinted.underlying)
        }

        if let llm = error as? LLMError {
            switch llm {
            case .rateLimitExceeded, .timeout:
                return .transient
            case .networkError(let inner):
                return classify(inner)
            case .invalidRequest, .quotaExceeded, .modelNotFound,
                 .authenticationFailed, .invalidResponse,
                 .unsupportedCapability, .unknown,
                 .imageGenerationError,
                 .queueFull, .queueTimeout:
                return .terminal
            }
        }

        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .resourceUnavailable, .internationalRoamingOff:
                return .transient
            case .cancelled:
                return .terminal
            // .badServerResponse arrives only from un-tightened sites once OllamaLLM
            // is normalized; conservatively terminal so we don't retry 4xx user errors.
            default:
                return .terminal
            }
        }

        return .terminal
    }

    /// Extracts provider-supplied retry-after delay in seconds when available.
    public static func retryAfterSeconds(_ error: Error) -> Double? {
        if let hinted = error as? RetryAfterRateLimitError {
            if let retryAfter = sanitizeRetryAfter(hinted.retryAfterSeconds) {
                return retryAfter
            }
            return retryAfterSeconds(hinted.underlying)
        }
        if let llm = error as? LLMError,
           case .networkError(let inner) = llm {
            return retryAfterSeconds(inner)
        }
        return nil
    }

    public static func isRateLimited(_ error: Error) -> Bool {
        if error is RetryAfterRateLimitError { return true }
        if let llm = error as? LLMError {
            switch llm {
            case .rateLimitExceeded:
                return true
            case .networkError(let inner):
                return isRateLimited(inner)
            default:
                return false
            }
        }
        return false
    }

    private static func sanitizeRetryAfter(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

/// Mapping from thrown errors to cross-binding failover decisions.
///
/// Uses ``TransientErrorClassifier`` for transient classes, and additionally marks
/// binding-scoped terminal classes (for example `modelNotFound` on one backend) as
/// eligible to try the next binding for the same logical model.
public enum BindingFailoverClassifier {
    public static func classify(_ error: Error, providerID: ProviderID? = nil) -> BindingFailoverDecision {
        if error is CancellationError { return .terminal }
        if let providerID,
           let provider = ProviderRegistry.textInferenceProvider(for: providerID) {
            let classification = provider.failoverError(error)
            return ProviderFailoverBridge.bindingDecision(for: classification)
        }
        if TransientErrorClassifier.classify(error) == .transient {
            return .tryNextBinding
        }
        guard let llmError = error as? LLMError else {
            return .terminal
        }
        switch llmError {
        case .modelNotFound, .unsupportedCapability, .invalidResponse, .imageGenerationError:
            return .tryNextBinding
        case .networkError(let inner):
            return classify(inner, providerID: providerID)
        case .invalidRequest, .quotaExceeded, .authenticationFailed, .unknown,
             .rateLimitExceeded, .timeout, .queueFull, .queueTimeout:
            return .terminal
        }
    }
}
