import Foundation

public struct SystemPromptContributionResolution: Sendable, Equatable {
    public var resolved: ResolvedSystemPromptSections
    public var stablePrefix: String?

    public init(resolved: ResolvedSystemPromptSections, stablePrefix: String?) {
        self.resolved = resolved
        self.stablePrefix = stablePrefix
    }
}

/// Merges layered contributions with conflict detection and cache-boundary rules.
public enum SystemPromptContributionResolver: Sendable {
    private static let layerOrder: [SystemPromptContributionSource] = [
        .harness, .provider, .mode, .memory, .conversation, .engine,
    ]

    private static let stablePrefixAllowedSources: Set<SystemPromptContributionSource> = [
        .harness, .provider,
    ]

    public static func resolve(
        contributions: [SystemPromptContribution]
    ) throws -> SystemPromptContributionResolution {
        var merged = ResolvedSystemPromptSections()
        var stablePrefix: String?

        for layer in layerOrder {
            let layerContributions = contributions.filter { $0.source == layer }
            guard !layerContributions.isEmpty else { continue }
            let layerMerged = try mergeWithinLayer(layerContributions)

            if let prefix = layerMerged.stablePrefix {
                stablePrefix = prefix
            }

            merged.suppressions.formUnion(layerMerged.suppressions)
            for (section, value) in layerMerged.sectionOverrides {
                merged.sectionOverrides[section] = value
                merged.provenance[section] = layer
            }
            for (section, value) in layerMerged.sectionDirectives {
                if let existing = merged.sectionDirectives[section], !existing.isEmpty {
                    merged.sectionDirectives[section] = existing + "\n\n" + value
                } else {
                    merged.sectionDirectives[section] = value
                }
                if merged.provenance[section] == nil {
                    merged.provenance[section] = layer
                }
            }
        }

        return SystemPromptContributionResolution(
            resolved: merged,
            stablePrefix: stablePrefix
        )
    }

    private struct LayerMerge: Sendable {
        var stablePrefix: String?
        var suppressions: Set<SystemPromptSectionName>
        var sectionOverrides: [SystemPromptSectionName: String]
        var sectionDirectives: [SystemPromptSectionName: String]
    }

    private static func mergeWithinLayer(
        _ contributions: [SystemPromptContribution]
    ) throws -> LayerMerge {
        var result = LayerMerge(
            stablePrefix: nil,
            suppressions: [],
            sectionOverrides: [:],
            sectionDirectives: [:]
        )
        var stablePrefixSet = false
        var overrideSources: [SystemPromptSectionName: SystemPromptContributionSource] = [:]

        for contribution in contributions {
            if let prefix = contribution.stablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prefix.isEmpty {
                guard stablePrefixAllowedSources.contains(contribution.source) else {
                    throw SystemPromptContributionConflict.stablePrefixFromVolatileLayer(contribution.source)
                }
                if stablePrefixSet {
                    throw SystemPromptContributionConflict.duplicateStablePrefix(
                        first: contribution.source,
                        second: contribution.source
                    )
                }
                result.stablePrefix = prefix
                stablePrefixSet = true
            }

            for section in contribution.suppress {
                guard !SystemPromptSectionName.overrideProof.contains(section) else { continue }
                result.suppressions.insert(section)
            }

            for (section, override) in contribution.sectionOverrides {
                let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard !SystemPromptSectionName.overrideProof.contains(section) else { continue }
                if let prior = overrideSources[section] {
                    throw SystemPromptContributionConflict.duplicateSectionOverride(
                        section: section,
                        first: prior,
                        second: contribution.source
                    )
                }
                result.sectionOverrides[section] = override
                overrideSources[section] = contribution.source
            }

            for (section, directive) in contribution.sectionDirectives {
                let trimmed = directive.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard !SystemPromptSectionName.overrideProof.contains(section) else { continue }
                if let existing = result.sectionDirectives[section], !existing.isEmpty {
                    result.sectionDirectives[section] = existing + "\n\n" + directive
                } else {
                    result.sectionDirectives[section] = directive
                }
            }
        }

        return result
    }
}
