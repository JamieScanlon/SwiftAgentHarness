import Foundation

enum SystemPromptSectionProvenanceFormatter {
    static func label(
        for section: SystemPromptSectionName,
        resolved: ResolvedSystemPromptSections,
        providerID: String?,
        modeProfileID: String?
    ) -> String {
        if SystemPromptSectionName.overrideProof.contains(section) {
            return "defaults"
        }
        if let source = resolved.provenance[section] {
            return contributorLabel(for: source, providerID: providerID, modeProfileID: modeProfileID)
        }
        return "defaults"
    }

    static func provenanceMap(
        resolved: ResolvedSystemPromptSections,
        sections: [SystemPromptSectionName: String],
        providerID: String?,
        modeProfileID: String?
    ) -> [SystemPromptSectionName: String] {
        var map: [SystemPromptSectionName: String] = [:]
        for section in SystemPromptSectionName.allCases {
            guard let body = sections[section]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { continue }
            if SystemPromptSectionName.overrideProof.contains(section) { continue }
            map[section] = label(for: section, resolved: resolved, providerID: providerID, modeProfileID: modeProfileID)
        }
        return map
    }

    static func provenanceComment(for label: String) -> String {
        "<!-- provenance: \(label) -->"
    }

    static func encodeSectionProvenanceJSON(_ map: [SystemPromptSectionName: String]) -> String? {
        guard !map.isEmpty else { return nil }
        let stringMap = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stringMap) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func stringSectionProvenanceMap(from product: SystemPromptAssemblyRenderProduct) -> [String: String] {
        Dictionary(uniqueKeysWithValues: product.sectionProvenance.map { ($0.key.rawValue, $0.value) })
    }

    private static func contributorLabel(
        for source: SystemPromptContributionSource,
        providerID: String?,
        modeProfileID: String?
    ) -> String {
        switch source {
        case .harness:
            return "defaults"
        case .provider:
            if let providerID, !providerID.isEmpty {
                return "provider:\(providerID)"
            }
            return "provider"
        case .mode:
            if let modeProfileID, !modeProfileID.isEmpty {
                return "mode:\(modeProfileID)"
            }
            return "mode"
        case .workspace:
            return "workspace"
        case .memory:
            return "memory"
        case .conversation:
            return "conversation"
        case .engine:
            return "engine"
        }
    }
}
