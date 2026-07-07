import Foundation
import SwiftAgentKit

public enum ProviderPromptContribution {
    public static let cacheBoundaryMarker = "<!-- CACHE_BOUNDARY -->"

    public static func merge(
        basePrompt: String,
        contribution: ProviderSystemPromptContribution?
    ) -> String {
        guard let contribution else { return basePrompt }
        var parts: [String] = []
        if let stablePrefix = contribution.stablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stablePrefix.isEmpty {
            parts.append(stablePrefix)
            parts.append(cacheBoundaryMarker)
        }
        parts.append(basePrompt)
        return parts.joined(separator: "\n\n")
    }

    public static func applySectionOverrides(
        metadata: inout [String: String],
        contribution: ProviderSystemPromptContribution?
    ) {
        guard let contribution else { return }
        for (section, value) in contribution.sectionOverrides {
            metadata["providerSectionOverride.\(section.rawValue)"] = value
        }
    }
}
