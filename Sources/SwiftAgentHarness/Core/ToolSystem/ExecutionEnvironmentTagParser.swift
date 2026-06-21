import Foundation

enum ExecutionEnvironmentTagParser {
    static let kindPrefix = "execution.environment.kind:"
    static let kindLegacyPrefix = "executionenvironmentkind:"
    static let adapterPrefix = "execution.environment.adapter:"
    static let adapterLegacyPrefix = "executionenvironmentadapterid:"
    static let isolationPrefix = "execution.environment.isolation:"
    static let isolationLegacyPrefix = "executionisolationlevel:"

    static func extractTaggedValue(raw: String, prefixes: [String]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in prefixes {
            let lowerPrefix = prefix.lowercased()
            guard lower.hasPrefix(lowerPrefix) else { continue }
            let value = String(trimmed.dropFirst(lowerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
