import Foundation

/// Secrets in computer-use traffic. URLs that carry credentials are not opened, and text bound for helper models
/// (the intent check and the injection probe) has secret values replaced. Pattern-based, so it catches the common
/// shapes, not every secret.
enum ComputerUseSecrets {
    static let marker = "[redacted]"

    /// Query or fragment parameters whose value is a credential.
    static let secretParameterNames: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "auth", "authorization", "auth_token",
        "api_key", "apikey", "key", "secret", "client_secret", "password", "passwd", "pwd",
        "session", "sessionid", "session_id", "sid", "sig", "signature", "x-amz-signature", "x-amz-credential",
        "x-amz-security-token", "private_token",
    ]

    /// Token shapes that are secrets wherever they appear: JWTs and well-known key prefixes. Computed because
    /// `Regex` isn't `Sendable`.
    static var tokenPatterns: [Regex<Substring>] { [
        /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
        /\b(?:sk|pk|rk)-[A-Za-z0-9_-]{20,}/,
        /\bgh[pousr]_[A-Za-z0-9]{20,}/,
        /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
        /\bAKIA[0-9A-Z]{16}\b/,
        /\bAIza[0-9A-Za-z_-]{35}\b/,
    ] }

    /// Why `url` must not be opened, or `nil`.
    static func secretInURL(_ url: String) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        if components.user != nil || components.password != nil { return "it embeds credentials before the host" }
        var parameters = components.queryItems ?? []
        if let fragment = components.fragment, fragment.contains("=") {
            var fragmentComponents = URLComponents()
            fragmentComponents.query = fragment
            parameters += fragmentComponents.queryItems ?? []
        }
        if let named = parameters.first(where: { secretParameterNames.contains($0.name.lowercased()) && !($0.value ?? "").isEmpty }) {
            return "its \(named.name) parameter carries a credential"
        }
        if containsToken(url) { return "it carries a token" }
        return nil
    }

    /// `text` with credential values replaced by ``marker``: tokens, URL credentials and secret parameters, and
    /// values labelled as passwords, secrets, tokens, or keys.
    static func redacting(_ text: String) -> String {
        var result = text
        for pattern in tokenPatterns {
            result = result.replacing(pattern, with: marker)
        }
        result = result.replacing(/(?<scheme>[a-zA-Z][a-zA-Z0-9+.-]*:\/\/)[^\s\/@:]+:[^\s\/@]+@/) { match in
            "\(match.output.scheme)\(marker)@"
        }
        result = result.replacing(/(?<lead>[?&#])(?<name>[A-Za-z0-9_.-]+)=(?<value>[^&#\s]+)/) { match in
            let name = String(match.output.name)
            guard secretParameterNames.contains(name.lowercased()) else { return String(match.output.0) }
            return "\(match.output.lead)\(name)=\(marker)"
        }
        result = result.replacing(
            /(?i)(?<label>\b(?:password|passwd|pwd|passcode|secret|token|api[ _-]?key)\b\s*(?:is\s+|[:=]\s*))(?<value>[^\s,;&#?]+)/
        ) { match in
            "\(match.output.label)\(marker)"
        }
        return result
    }

    /// What the injection probe sees of a tool result: screen content redacted, anything else unchanged.
    static func probeInput(_ content: String, source: ExternalContentSourceLabel) -> String {
        source == .screen ? redacting(content) : content
    }

    private static func containsToken(_ text: String) -> Bool {
        let decoded = text.removingPercentEncoding ?? text
        return tokenPatterns.contains { decoded.contains($0) }
    }
}
