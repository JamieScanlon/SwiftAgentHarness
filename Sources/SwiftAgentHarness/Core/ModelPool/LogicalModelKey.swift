import Foundation

/// Canonical logical-model identity helpers (family + version, distinct from coarse ``ModelRegistryEntry/family``).
enum LogicalModelKey {
    /// Infers a coarse family from a canonical key by dropping trailing numeric version segments.
    /// Example: `claude-sonnet-4-6` → `claude-sonnet`.
    static func inferredFamily(from canonicalModelKey: String) -> String? {
        var parts = canonicalModelKey.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }
        while parts.count > 1, isVersionSegment(parts.last!) {
            parts.removeLast()
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "-")
    }

    /// Derives a canonical key for aggregator providers when the endpoint id is `vendor/model`
    /// and the tail exactly matches an existing explicit key.
    static func deriveCanonicalKey(
        providerId: String,
        endpointModelId: String,
        explicitKeys: Set<String>
    ) -> String? {
        guard providerId == "openrouter", endpointModelId.contains("/") else { return nil }
        guard let tail = endpointModelId.split(separator: "/").last.map(String.init) else { return nil }
        if explicitKeys.contains(tail) { return tail }
        let lowered = tail.lowercased()
        if explicitKeys.contains(where: { $0.lowercased() == lowered }) {
            return explicitKeys.first { $0.lowercased() == lowered }
        }
        return nil
    }

    private static func isVersionSegment(_ segment: String) -> Bool {
        !segment.isEmpty && segment.allSatisfy { $0.isNumber || $0 == "." }
    }
}
