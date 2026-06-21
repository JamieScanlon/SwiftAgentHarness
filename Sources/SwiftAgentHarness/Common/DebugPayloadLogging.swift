import Foundation

enum DebugPayloadLogging {
    private static let envKey = "SAH_LOG_FULL_PAYLOADS"

    /// Controls verbose request/response payload logging.
    ///
    /// - When unset: defaults to `true` to preserve historical debug behavior.
    /// - Truthy values: `1`, `true`, `yes`, `on`
    /// - Falsey values: `0`, `false`, `no`, `off`
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment[envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty else {
            return true
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }
}
