import Foundation

/// Resolves Anthropic Messages / Models paths from a provider base URL.
///
/// Accepts the shapes already used in fixtures:
/// - `https://api.anthropic.com`
/// - `https://api.anthropic.com/v1`
/// - `https://api.anthropic.com/v1/messages`
enum AnthropicEndpointURLs {
    static func messagesURL(from base: URL) -> URL {
        let path = normalizedPath(base)
        if path.hasSuffix("/v1/messages") {
            return base
        }
        if path.hasSuffix("/v1") {
            return base.appendingPathComponent("messages")
        }
        return base.appendingPathComponent("v1").appendingPathComponent("messages")
    }

    static func modelsURL(from base: URL) -> URL {
        let path = normalizedPath(base)
        if path.hasSuffix("/v1/models") {
            return base
        }
        if path.hasSuffix("/v1/messages") {
            return base.deletingLastPathComponent().appendingPathComponent("models")
        }
        if path.hasSuffix("/v1") {
            return base.appendingPathComponent("models")
        }
        return base.appendingPathComponent("v1").appendingPathComponent("models")
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.path.lowercased()
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
