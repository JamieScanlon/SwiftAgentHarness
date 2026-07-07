import EasyJSON
import Foundation

/// Restricts project-local mode profile overlays to cosmetic / prompt-tuning fields.
enum ModeProfileProjectOverlayPolicy {
    private static let builtInProfileIDs: Set<String> = Set(InteractionMode.allCases.map(\.rawValue))

    private static let protectedProfileIDs: Set<String> = builtInProfileIDs
        .union(ConversationLineageInference.machineSubAgentModeProfileIDs)

    private static let trustAdjacentContextKeys: Set<String> = [
        "memoryInjection",
        "includeSkills",
        "includeToolGuidance",
        "suppressSections",
    ]

    private static let allowedContextKeys: Set<String> = [
        "compactionLevel",
        "modeDirective",
        "sectionOverrides",
    ]

    static func sanitize(
        _ raw: ModeProfileConfiguration.RawProfile,
        diagnostics: inout [String]
    ) -> ModeProfileConfiguration.RawProfile? {
        if protectedProfileIDs.contains(raw.id) {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay rejected: protected profile id")
            return nil
        }
        guard raw.extends != nil else {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay rejected: requires extends")
            return nil
        }

        if raw.tools != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped security slice 'tools'")
        }
        if raw.skills != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped security slice 'skills'")
        }
        if raw.runtime != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped security slice 'runtime'")
        }
        if raw.model != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped security slice 'model'")
        }
        if raw.subAgents != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped security slice 'subAgents'")
        }
        if raw.hooks != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped security slice 'hooks'")
        }
        if raw.interactionMode != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped structural field 'interactionMode'")
        }
        if raw.assemblyKind != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped structural field 'assemblyKind'")
        }
        if raw.allowsProactiveCompactionTriggers != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped structural field 'allowsProactiveCompactionTriggers'")
        }
        if raw.appliesAgentBuildOrchestratorHarness != nil {
            diagnostics.append("modeProfiles[\(raw.id)] project overlay stripped structural field 'appliesAgentBuildOrchestratorHarness'")
        }

        let sanitizedContext = sanitizeContextOverlay(raw.context, profileID: raw.id, diagnostics: &diagnostics)

        return ModeProfileConfiguration.RawProfile(
            id: raw.id,
            extends: raw.extends,
            interactionMode: nil,
            assemblyKind: nil,
            allowsProactiveCompactionTriggers: nil,
            appliesAgentBuildOrchestratorHarness: nil,
            semanticLayerTags: raw.semanticLayerTags,
            label: raw.label,
            profileDescription: raw.profileDescription,
            symbol: raw.symbol,
            tools: nil,
            skills: nil,
            context: sanitizedContext,
            runtime: nil,
            model: nil,
            subAgents: nil,
            hooks: nil
        )
    }

    static func sanitizeAll(
        _ profiles: [ModeProfileConfiguration.RawProfile],
        diagnostics: inout [String]
    ) -> [ModeProfileConfiguration.RawProfile] {
        profiles.compactMap { sanitize($0, diagnostics: &diagnostics) }
    }

    private static func sanitizeContextOverlay(
        _ overlay: JSON?,
        profileID: String,
        diagnostics: inout [String]
    ) -> JSON? {
        guard let overlay, let fields = overlay.objectFields else { return nil }

        for key in fields.keys where trustAdjacentContextKeys.contains(key) {
            diagnostics.append("modeProfiles[\(profileID)] project overlay stripped trust-adjacent context field '\(key)'")
        }

        var kept: [String: JSON] = [:]
        for key in allowedContextKeys {
            if let value = fields[key] {
                kept[key] = value
            }
        }
        return kept.isEmpty ? nil : .object(kept)
    }
}
