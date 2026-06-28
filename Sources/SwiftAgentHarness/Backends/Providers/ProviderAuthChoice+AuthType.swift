import Foundation

public extension AuthProfileType {
    static func inferred(fromChoiceID choiceID: String) -> AuthProfileType {
        switch choiceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "api-key", "apikey", "api_key": return .apiKey
        case "oauth": return .oauth
        case "iam": return .iam
        case "adc": return .adc
        case "local": return .local
        default: return .apiKey
        }
    }

    var requiresWireCredential: Bool {
        switch self {
        case .apiKey, .oauth, .iam, .adc: true
        case .local: false
        }
    }
}

public extension ProviderAuthChoice {
    var resolvedAuthType: AuthProfileType {
        authType ?? AuthProfileType.inferred(fromChoiceID: id)
    }
}
