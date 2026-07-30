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

extension RetryAfterRateLimitError: LocalizedError {
    /// Without this, `localizedDescription` bridges to Foundation's placeholder
    /// ("… error 1"), which is what a persisted terminal reason would show.
    public var errorDescription: String? {
        let base = (underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying)
        guard let retryAfterSeconds else { return base }
        return "\(base) (retry after \(retryAfterSeconds)s)"
    }
}

/// An error that can restate itself with the number of attempts that produced it.
///
/// Exists so a retry wrapper can annotate an error without *wrapping* it — wrapping would hide
/// the concrete type from the `as?` checks and classifiers downstream.
public protocol AttemptAnnotatableError: Error {
    /// Returns a copy carrying `attempts`. Implementations should keep their own type.
    func annotatedWithAttempts(_ attempts: Int) -> any Error
}

/// A model stream that terminated without delivering anything the caller can act on.
///
/// Deliberately *not* an ``LLMError`` case. A degenerate stream is a response-*shape* failure,
/// not a transport or request failure, and the two have to classify differently: widening
/// ``LLMError/invalidResponse`` to transient would also make SSE `error` events and non-HTTP
/// responses retryable. Keeping degenerate responses on their own axis matches how every
/// surveyed harness separates "the provider returned something unusable" from its HTTP/status
/// error taxonomy.
///
/// Classified ``RetryDecision/transient``: the usual cause is a truncated or replayed body, and
/// re-issuing is the right move. Where re-issuing is *not* safe — partial output already reached
/// the consumer — ``RetryingLLM`` stops the retry via its `firstYielded` guard, not this
/// classification.
public struct DegenerateStreamError: Error, Sendable, CustomStringConvertible {
    /// What the stream failed to deliver. Carried for diagnostics and metrics, not for control
    /// flow — every kind classifies the same way.
    public enum Kind: String, Sendable {
        /// The stream closed without producing a single event.
        case noEvents
        /// A tool-use block was announced but no call could be assembled from it.
        case announcedToolCallLost
        /// Events arrived but carried no text, tool calls, or terminal stop reason.
        case noOutcome
    }

    public let kind: Kind
    public let provider: String
    public let detail: String
    /// Attempts made before the failure surfaced. `nil` until a retry wrapper annotates it, so a
    /// reader can tell "not retried" apart from "retried once".
    public let attempts: Int?

    public init(kind: Kind, provider: String, detail: String, attempts: Int? = nil) {
        self.kind = kind
        self.provider = provider
        self.detail = detail
        self.attempts = attempts
    }

    public var description: String { errorDescription ?? detail }
}

extension DegenerateStreamError: LocalizedError, CustomNSError, AttemptAnnotatableError {
    public static var errorDomain: String { "SwiftAgentHarness.DegenerateStreamError" }

    /// Distinguishes the kinds for anything reading the bridged `NSError` code, which otherwise
    /// reports `1` for every case of a Swift struct error.
    public var errorCode: Int {
        switch kind {
        case .noEvents: return 1
        case .announcedToolCallLost: return 2
        case .noOutcome: return 3
        }
    }

    /// Drives `localizedDescription`, which is what reaches a persisted terminal reason.
    public var errorDescription: String? {
        guard let attempts, attempts > 1 else { return detail }
        return "\(detail) (after \(attempts) attempts)"
    }

    /// `CustomNSError` fixes this as `[String: Any]`; EasyJSON cannot satisfy the Foundation
    /// contract, so this is a deliberate exception to the repo-wide preference.
    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: errorDescription ?? detail,
            "kind": kind.rawValue,
            "provider": provider,
        ]
        if let attempts { info["attempts"] = attempts }
        return info
    }

    public func annotatedWithAttempts(_ attempts: Int) -> any Error {
        DegenerateStreamError(kind: kind, provider: provider, detail: detail, attempts: attempts)
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

        if error is DegenerateStreamError { return .transient }

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
/// Transient errors (rate limits, timeouts, network blips) advance to the next binding via
/// ``TransientErrorClassifier``. The ``LLMError`` switch below handles binding-scoped terminal
/// classes that should still rotate (`modelNotFound`, `unsupportedCapability`, …) versus
/// truly terminal classes (`authenticationFailed`, `invalidRequest`, …).
public enum BindingFailoverClassifier {
    public static func classify(_ error: Error, providerID: ProviderID? = nil) -> BindingFailoverDecision {
        if error is CancellationError { return .terminal }
        // Resolved ahead of the provider hook: a degenerate stream is diagnosed by the harness
        // from the assembled response, so a provider's own error mapper has nothing to add and
        // could only misfile it.
        if error is DegenerateStreamError { return .tryNextBinding }
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
        case .rateLimitExceeded, .timeout:
            return .tryNextBinding
        case .networkError(let inner):
            return classify(inner, providerID: providerID)
        case .invalidRequest, .quotaExceeded, .authenticationFailed, .unknown,
             .queueFull, .queueTimeout:
            return .terminal
        }
    }
}
