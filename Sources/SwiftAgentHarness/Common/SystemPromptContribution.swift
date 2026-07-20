import Foundation

public enum SystemPromptContributionSource: String, Sendable, Equatable, Codable {
    case harness
    case provider
    case mode
    case workspace
    case memory
    case conversation
    case engine
}

/// Named-section contribution record; contributors never receive the assembled string.
public struct SystemPromptContribution: Sendable, Equatable {
    public var source: SystemPromptContributionSource
    public var stablePrefix: String?
    public var sectionOverrides: [SystemPromptSectionName: String]
    public var sectionDirectives: [SystemPromptSectionName: String]
    public var suppress: Set<SystemPromptSectionName>

    public init(
        source: SystemPromptContributionSource,
        stablePrefix: String? = nil,
        sectionOverrides: [SystemPromptSectionName: String] = [:],
        sectionDirectives: [SystemPromptSectionName: String] = [:],
        suppress: Set<SystemPromptSectionName> = []
    ) {
        self.source = source
        self.stablePrefix = stablePrefix
        self.sectionOverrides = sectionOverrides
        self.sectionDirectives = sectionDirectives
        self.suppress = suppress
    }
}

public struct ResolvedSystemPromptSections: Sendable, Equatable {
    public var suppressions: Set<SystemPromptSectionName>
    public var sectionOverrides: [SystemPromptSectionName: String]
    public var sectionDirectives: [SystemPromptSectionName: String]
    public var provenance: [SystemPromptSectionName: SystemPromptContributionSource]

    public init(
        suppressions: Set<SystemPromptSectionName> = [],
        sectionOverrides: [SystemPromptSectionName: String] = [:],
        sectionDirectives: [SystemPromptSectionName: String] = [:],
        provenance: [SystemPromptSectionName: SystemPromptContributionSource] = [:]
    ) {
        self.suppressions = suppressions
        self.sectionOverrides = sectionOverrides
        self.sectionDirectives = sectionDirectives
        self.provenance = provenance
    }
}

public enum SystemPromptContributionConflict: Error, Sendable, Equatable {
    case duplicateSectionOverride(
        section: SystemPromptSectionName,
        first: SystemPromptContributionSource,
        second: SystemPromptContributionSource
    )
    case duplicateStablePrefix(
        first: SystemPromptContributionSource,
        second: SystemPromptContributionSource
    )
    case stablePrefixFromVolatileLayer(SystemPromptContributionSource)
}
