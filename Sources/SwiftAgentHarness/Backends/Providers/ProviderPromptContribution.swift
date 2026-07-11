import Foundation
import SwiftAgentKit

public enum ProviderPromptContribution {
    public static let cacheBoundaryMarker = "<!-- CACHE_BOUNDARY -->"

    public static func systemPromptContribution(
        from contribution: ProviderSystemPromptContribution?
    ) -> SystemPromptContribution? {
        guard let contribution else { return nil }
        var sectionOverrides: [SystemPromptSectionName: String] = [:]
        for (section, value) in contribution.sectionOverrides {
            guard let canonical = SystemPromptSectionName.canonicalSection(forLegacyKey: section.rawValue) else {
                continue
            }
            sectionOverrides[canonical] = value
        }
        let stablePrefix = contribution.stablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard stablePrefix != nil || !sectionOverrides.isEmpty else { return nil }
        return SystemPromptContribution(
            source: .provider,
            stablePrefix: stablePrefix,
            sectionOverrides: sectionOverrides
        )
    }

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
        guard let typed = systemPromptContribution(from: contribution) else { return }
        for (section, value) in typed.sectionOverrides {
            metadata["providerSectionOverride.\(section.rawValue)"] = value
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
