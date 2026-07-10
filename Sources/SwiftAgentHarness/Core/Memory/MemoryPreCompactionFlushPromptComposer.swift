import Foundation

enum MemoryPreCompactionFlushPromptComposer {
    static func systemPrompt(
        manifestLines: [String],
        customBody: String?,
        teamMemoryEnabled: Bool
    ) -> String {
        let manifestBlock = formattedManifestBlock(manifestLines: manifestLines)
        var parts: [String] = []
        if let customBody {
            parts.append(customBody)
        } else {
            parts.append(defaultBody)
        }
        parts.append(manifestBlock)
        parts.append(PreCompactionFlushSafetyHints.enforcedBlock())
        var prompt = parts.joined(separator: "\n\n")
        if teamMemoryEnabled {
            prompt += "\n\n" + MemoryTypeTaxonomy.teamSensitiveDataPrompt
        }
        return prompt
    }

    private static let defaultBody = """
You promote durable cross-session memories from conversation messages before context compaction summarizes them away.

When no topic files exist yet, create new typed topic files using write_file with valid YAML frontmatter (type: user | feedback | project | reference).

\(MemoryTypeTaxonomy.twoStepWriteRulePrompt)
\(MemoryTypeTaxonomy.whatNotToSavePrompt)
\(MemoryTypeTaxonomy.indexUsagePrompt)

URGENT: Context compaction is about to summarize away the conversation below. Promote any durable facts to curated typed topic files NOW before they are lost. Do not write daily staging files.
"""

    private static func formattedManifestBlock(manifestLines: [String]) -> String {
        let manifestBlock = manifestLines.isEmpty
            ? "(none yet — create new typed topic files with YAML frontmatter)"
            : manifestLines.joined(separator: "\n")
        return """
Existing curated memory manifest:
\(manifestBlock)
"""
    }
}
