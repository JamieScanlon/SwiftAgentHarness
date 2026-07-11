import Foundation

/// Maps legacy string metadata and provider wire models into typed SP2 assembly inputs.
enum SystemPromptLegacyMetadataAdapter: Sendable {
    static let knownMetadataKeys: Set<String> = [
        "conversationID",
        "conversationStartDate",
        "registryProfileId",
        "modeMemoryInjection",
        "modeIncludeSkills",
        "modeIncludeToolGuidance",
        "modeDirective",
        "modeCompactionLevel",
        "modeSuppressSections",
        "interactionMode",
        "planPath",
        "agentWorkflowBlock",
        "conversationLineageKind",
        "conversationOrigin",
        "subAgentRootConversationID",
        "subAgentParentConversationID",
        "subAgentDepth",
        SystemPromptAssemblyMetadataKeys.tier1MemoryContent,
        SystemPromptAssemblyMetadataKeys.memorySnapshotGeneration,
        SystemPromptAssemblyMetadataKeys.providerStablePrefix,
        SystemPromptAssemblyMetadataKeys.assembledPromptDigest,
        SystemPromptAssemblyMetadataKeys.assembleReferenceDateISO,
    ]

    static func unknownKeys(in metadata: [String: String]) -> [String] {
        metadata.keys.filter { key in
            if knownMetadataKeys.contains(key) { return false }
            if key.hasPrefix("modeSectionOverride.") { return false }
            if key.hasPrefix("providerSectionOverride.") { return false }
            return true
        }.sorted()
    }

    static func assemblyContext(
        from metadata: [String: String],
        userSystemPrompt: String?,
        referenceDate: Date? = nil
    ) -> SystemPromptAssemblyContext {
        let ref = referenceDate ?? SystemPrompt.referenceDate(from: metadata)
        let tier1 = metadata[SystemPromptAssemblyMetadataKeys.tier1MemoryContent]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = metadata[SystemPromptAssemblyMetadataKeys.memorySnapshotGeneration].flatMap(Int.init)
        let subAgent = metadata["modeSectionOverride.sub_agent_context"]
            ?? metadata["providerSectionOverride.sub_agent_context"]
        return SystemPromptAssemblyContext(
            conversationID: metadata["conversationID"] ?? "unknown",
            conversationStartDate: metadata["conversationStartDate"] ?? "unknown",
            referenceDate: ref,
            userSystemPrompt: userSystemPrompt ?? "",
            workflowBlock: metadata["agentWorkflowBlock"] ?? "",
            memoryInjectionMode: metadata["modeMemoryInjection"] ?? "on",
            tier1MemoryContent: tier1?.isEmpty == false ? tier1 : nil,
            memorySnapshotGeneration: generation,
            includeAgentSkills: (metadata["modeIncludeSkills"] ?? "true").lowercased() != "false",
            includeToolGuidance: (metadata["modeIncludeToolGuidance"] ?? "true").lowercased() != "false",
            subAgentContextPrompt: subAgent?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            registryProfileID: metadata["registryProfileId"],
            modeCompactionLevel: metadata["modeCompactionLevel"],
            assembledPromptDigest: metadata[SystemPromptAssemblyMetadataKeys.assembledPromptDigest]
        )
    }

    static func contributions(from metadata: [String: String]) -> [SystemPromptContribution] {
        var mode = SystemPromptContribution(source: .mode)

        let suppressions = (metadata["modeSuppressSections"] ?? "")
            .split(separator: ",")
            .compactMap { SystemPromptSectionName.canonicalSection(forLegacyKey: String($0)) }
        mode.suppress = Set(suppressions)

        for (key, value) in metadata {
            if key.hasPrefix("modeSectionOverride.") {
                let raw = String(key.dropFirst("modeSectionOverride.".count))
                if let section = SystemPromptSectionName.canonicalSection(forLegacyKey: raw) {
                    mode.sectionOverrides[section] = value
                }
            }
        }

        if let directive = metadata["modeDirective"]?.trimmedOrNil {
            mode.sectionDirectives[.modeDirective] = directive
        }

        var provider = SystemPromptContribution(source: .provider)
        if let prefix = metadata[SystemPromptAssemblyMetadataKeys.providerStablePrefix]?.trimmedOrNil {
            provider.stablePrefix = prefix
        }
        for (key, value) in metadata where key.hasPrefix("providerSectionOverride.") {
            let raw = String(key.dropFirst("providerSectionOverride.".count))
            if let section = SystemPromptSectionName.canonicalSection(forLegacyKey: raw) {
                provider.sectionOverrides[section] = value
            }
        }

        var result: [SystemPromptContribution] = []
        if !provider.sectionOverrides.isEmpty || provider.stablePrefix != nil {
            result.append(provider)
        }
        if !mode.suppress.isEmpty || !mode.sectionOverrides.isEmpty || !mode.sectionDirectives.isEmpty {
            result.append(mode)
        }
        return result
    }
}

private extension String {
    var trimmedOrNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var nilIfEmpty: String? { trimmedOrNil }
}
