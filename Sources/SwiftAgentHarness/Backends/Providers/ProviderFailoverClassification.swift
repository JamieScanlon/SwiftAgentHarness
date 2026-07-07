import Foundation
import SwiftAgentKit

/// Provider-owned error taxonomy (spec: failover classification).
public enum ProviderFailoverClassification: String, Sendable, Codable, Hashable {
    case transient
    case rateLimited = "rate-limited"
    case credentialExhausted = "credential-exhausted"
    case authError = "auth-error"
    case contextOverflow = "context-overflow"
    case modelNotFound = "model-not-found"
    case policyBlocked = "policy-blocked"
    case permanent
}

public struct ProviderFailoverRecoveryHints: Sendable, Equatable, Hashable {
    public var shouldRotateCredential: Bool
    public var shouldFallback: Bool
    public var shouldCompress: Bool

    public init(
        shouldRotateCredential: Bool = false,
        shouldFallback: Bool = false,
        shouldCompress: Bool = false
    ) {
        self.shouldRotateCredential = shouldRotateCredential
        self.shouldFallback = shouldFallback
        self.shouldCompress = shouldCompress
    }

    public static func hints(for classification: ProviderFailoverClassification) -> ProviderFailoverRecoveryHints {
        switch classification {
        case .transient:
            return ProviderFailoverRecoveryHints(shouldFallback: false)
        case .rateLimited:
            return ProviderFailoverRecoveryHints(shouldRotateCredential: true, shouldFallback: true)
        case .credentialExhausted:
            return ProviderFailoverRecoveryHints(shouldRotateCredential: true)
        case .authError:
            return ProviderFailoverRecoveryHints(shouldRotateCredential: true)
        case .contextOverflow:
            return ProviderFailoverRecoveryHints(shouldCompress: true)
        case .modelNotFound:
            return ProviderFailoverRecoveryHints(shouldFallback: true)
        case .policyBlocked, .permanent:
            return ProviderFailoverRecoveryHints()
        }
    }
}

/// Default classifier used when a provider plugin does not override failover semantics.
public enum DefaultProviderFailoverClassifier {
    public static func classify(_ error: Error) -> ProviderFailoverClassification {
        if error is CancellationError { return .permanent }

        if let llmError = error as? LLMError {
            switch llmError {
            case .timeout, .networkError:
                return .transient
            case .rateLimitExceeded:
                return .rateLimited
            case .quotaExceeded:
                return .credentialExhausted
            case .authenticationFailed:
                return .authError
            case .modelNotFound:
                return .modelNotFound
            case .invalidRequest:
                if isContextOverflow(error) { return .contextOverflow }
                return .permanent
            case .unsupportedCapability:
                return .permanent
            default:
                return .permanent
            }
        }

        if TransientErrorClassifier.classify(error) == .transient {
            return .transient
        }
        if isCredentialExhausted(error) {
            return .credentialExhausted
        }
        return .permanent
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("context") && (message.contains("length") || message.contains("token"))
    }

    public static func isCredentialExhausted(_ error: Error) -> Bool {
        if case LLMError.quotaExceeded = error { return true }
        let message = String(describing: error).lowercased()
        if message.contains("402") { return true }
        if message.contains("insufficient credits") || message.contains("insufficient_credit") {
            return true
        }
        if message.contains("payment required") { return true }
        return false
    }
}

public enum ProviderFailoverBridge {
    public static func bindingDecision(for classification: ProviderFailoverClassification) -> BindingFailoverDecision {
        switch classification {
        case .transient, .rateLimited, .modelNotFound:
            return .tryNextBinding
        case .credentialExhausted, .authError:
            return .tryNextBinding
        case .contextOverflow, .policyBlocked, .permanent:
            return .terminal
        }
    }
}
