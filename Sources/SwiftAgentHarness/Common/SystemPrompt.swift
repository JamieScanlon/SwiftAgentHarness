import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitSkills

public struct SystemPrompt: Sendable {

    public let includeCurrentDateTime: Bool
    public let includeAgentSkills: Bool
    public let skillLoader: SkillLoader?
    /// When `.plan` or `.agent`, the system prompt template includes the plan workflow block for that mode.
    public let interactionMode: InteractionMode
    /// Resolved harness prompt slice; drives template section selection (defaults track ``interactionMode``).
    public let assemblyKind: SystemPromptAssemblyKind
    /// From `PromptConfig.json` → `agentHarness.strictAgentHarnessPrompts` (default `true`).
    public let strictAgentHarnessPrompts: Bool

    private let promptTemplate: String
    private let skillMetadata: [SkillMetadata]?

    public init(
        skillLoader: SkillLoader?,
        logger: Logger? = nil,
        interactionMode: InteractionMode = .chat,
        assemblyKind: SystemPromptAssemblyKind? = nil,
        routingPolicyConversation: ModelConversation? = nil,
        modePolicyContext: ModePolicyContext? = nil
    ) async throws {
        try await self.init(
            includeCurrentDateTime: nil,
            includeAgentSkills: modePolicyContext?.resolvedProfile.context.includeSkills,
            skillLoader: skillLoader,
            logger: logger,
            interactionMode: interactionMode,
            assemblyKind: assemblyKind,
            routingPolicyConversation: routingPolicyConversation,
            modePolicyContext: modePolicyContext
        )
    }

    /// Internal initializer for testing; allows overriding config without loading from file.
    internal init(
        includeCurrentDateTime: Bool?,
        includeAgentSkills: Bool?,
        skillLoader: SkillLoader?,
        skipConfigLoad: Bool = false,
        allowSkillLoaderAbsence: Bool = false,
        logger: Logger? = nil,
        interactionMode: InteractionMode = .chat,
        assemblyKind: SystemPromptAssemblyKind? = nil,
        routingPolicyConversation: ModelConversation? = nil,
        modePolicyContext: ModePolicyContext? = nil
    ) async throws {
        let resolvedAssemblyKind = assemblyKind ?? interactionMode.harnessAssemblyKind
        var resolvedIncludeCurrentDateTime = true
        var resolvedIncludeAgentSkills = true
        var resolvedStrictAgentHarnessPrompts = true

        if skipConfigLoad {
            if let includeCurrentDateTime {
                resolvedIncludeCurrentDateTime = includeCurrentDateTime
            }
            if let includeAgentSkills {
                resolvedIncludeAgentSkills = includeAgentSkills
            }
        } else if let includeAgentSkills {
            resolvedIncludeAgentSkills = includeAgentSkills
        }

        var effectiveIncludeAgentSkills = resolvedIncludeAgentSkills
        if effectiveIncludeAgentSkills, skillLoader == nil, !allowSkillLoaderAbsence {
            if skipConfigLoad {
                throw PromptsConfigError.skillLoaderNotFound
            }
            effectiveIncludeAgentSkills = false
        }

        let resolvedSkillMetadata: [SkillMetadata]?
        if effectiveIncludeAgentSkills, let skillLoader {
            var loaded = try await skillLoader.loadMetadata()
            loaded = loaded.filter { meta in
                let allowed: Bool = if let modePolicyContext {
                    modePolicyContext.resolvedProfile.skills.isSkillAllowed(name: meta.name, context: modePolicyContext)
                } else {
                    true
                }
                guard allowed else { return false }
                guard let routingPolicyConversation else { return true }
                return ModeProfileSkillsSlice.isSkillAllowedByRoutingPolicy(
                    name: meta.name,
                    conversation: routingPolicyConversation
                )
            }
            resolvedSkillMetadata = loaded
        } else {
            resolvedSkillMetadata = nil
        }

        self.interactionMode = interactionMode
        self.assemblyKind = resolvedAssemblyKind
        self.skillLoader = skillLoader
        self.includeCurrentDateTime = resolvedIncludeCurrentDateTime
        self.includeAgentSkills = effectiveIncludeAgentSkills
        self.strictAgentHarnessPrompts = resolvedStrictAgentHarnessPrompts
        self.skillMetadata = resolvedSkillMetadata
        self.promptTemplate = Self.makePromptTemplate(includeCurrentDateTime: resolvedIncludeCurrentDateTime)
    }

    public func generateSystemPrompt(
        context assemblyContext: SystemPromptAssemblyContext,
        resolved: ResolvedSystemPromptSections,
        stablePrefix: String?
    ) async throws -> String {
        try await renderAssemblyProduct(
            context: assemblyContext,
            resolved: resolved,
            stablePrefix: stablePrefix,
            providerID: nil,
            modeProfileID: assemblyContext.registryProfileID
        ).text
    }

    func renderAssemblyProduct(
        context assemblyContext: SystemPromptAssemblyContext,
        resolved: ResolvedSystemPromptSections,
        stablePrefix: String?,
        providerID: String?,
        modeProfileID: String?
    ) async throws -> SystemPromptAssemblyRenderProduct {
        let dateString = Self.dateString(from: assemblyContext.referenceDate)
        var skillsFolderPathValue = ""
        var availableSkillsValue = ""
        var skillSnapshot = SystemPromptSkillRenderSnapshot(
            activatedSkillNames: [],
            skillsIndexDigest: nil
        )
        var capturedFrozenIndexXML: String?
        if includeAgentSkills {
            if let frozenIndex = assemblyContext.frozenSkillsIndexXML?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !frozenIndex.isEmpty {
                availableSkillsValue = frozenIndex
                capturedFrozenIndexXML = frozenIndex
            } else {
                availableSkillsValue = SkillPromptFormatter.formatAsXML(skillMetadata ?? [])
                if !availableSkillsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    capturedFrozenIndexXML = availableSkillsValue
                }
            }
            if let skillLoader {
                skillsFolderPathValue = await skillLoader.skillsDirectoryURL.absoluteString
            }
            let activatedNames: [String]
            if let skillLoader {
                activatedNames = Array(await skillLoader.activatedSkills).sorted()
            } else {
                activatedNames = []
            }
            skillSnapshot = SystemPromptSkillRenderSnapshot.capture(
                activatedSkillNames: activatedNames,
                skillsIndexXML: capturedFrozenIndexXML
            )
        }

        var sections = Self.finalSections(
            assemblyContext: assemblyContext,
            resolved: resolved,
            skillsFolderPath: skillsFolderPathValue,
            availableSkills: availableSkillsValue,
            includeAgentSkills: includeAgentSkills,
            assemblyKind: assemblyKind,
            strictAgentHarnessPrompts: strictAgentHarnessPrompts
        )
        Self.applySectionProvenanceTags(
            sections: &sections,
            resolved: resolved,
            providerID: providerID,
            modeProfileID: modeProfileID
        )
        let provenanceMap = SystemPromptSectionProvenanceFormatter.provenanceMap(
            resolved: resolved,
            sections: sections,
            providerID: providerID,
            modeProfileID: modeProfileID
        )

        var dynamicPrompt = DynamicPrompt(template: promptTemplate)
        if includeCurrentDateTime {
            dynamicPrompt["datetime"] = dateString
        }
        dynamicPrompt["conversationID"] = assemblyContext.conversationID
        dynamicPrompt["conversationStartDate"] = assemblyContext.conversationStartDate
        if assemblyKind != .chat {
            dynamicPrompt["agentWorkflowBlock"] = assemblyContext.workflowBlock
        }
        dynamicPrompt["userSystemPrompt"] = assemblyContext.userSystemPrompt
        if includeAgentSkills {
            dynamicPrompt["skillsFolderPath"] = skillsFolderPathValue
            dynamicPrompt["agentSkillsMetadata"] = availableSkillsValue
        }
        for section in SystemPromptSectionName.allCases {
            dynamicPrompt[section.dynamicPromptToken] = sections[section] ?? ""
        }

        let text = Self.assemblePromptWithCacheBoundary(
            sections: sections,
            includeDateTimePrefix: includeCurrentDateTime ? "Today is \(dateString).\n" : "",
            providerStablePrefix: stablePrefix
        )
        return SystemPromptAssemblyRenderProduct(
            text: text,
            sectionProvenance: provenanceMap,
            skillSnapshot: skillSnapshot,
            frozenSkillsIndexXML: capturedFrozenIndexXML
        )
    }

    private static func applySectionProvenanceTags(
        sections: inout [SystemPromptSectionName: String],
        resolved: ResolvedSystemPromptSections,
        providerID: String?,
        modeProfileID: String?
    ) {
        for section in SystemPromptSectionName.allCases {
            guard SystemPromptSectionName.overrideProof.contains(section) == false else { continue }
            guard let body = sections[section]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { continue }
            let label = SystemPromptSectionProvenanceFormatter.label(
                for: section,
                resolved: resolved,
                providerID: providerID,
                modeProfileID: modeProfileID
            )
            let tag = SystemPromptSectionProvenanceFormatter.provenanceComment(for: label)
            guard !body.contains(tag) else { continue }
            sections[section] = tag + "\n" + body
        }
    }

    public func generateSystemPrompt(withUserSystemPrompt userSystemPrompt: String? = nil, additionalMetadata: [String: String] = [:]) async throws -> String {
        let unknown = SystemPromptLegacyMetadataAdapter.unknownKeys(in: additionalMetadata)
        if !unknown.isEmpty {
            // Legacy shim only; production paths must use typed context + resolver.
        }
        var context = SystemPromptLegacyMetadataAdapter.assemblyContext(
            from: additionalMetadata,
            userSystemPrompt: userSystemPrompt
        )
        if let user = userSystemPrompt {
            context.userSystemPrompt = user
        }
        let contributions = SystemPromptLegacyMetadataAdapter.contributions(from: additionalMetadata)
        let resolution = try SystemPromptContributionResolver.resolve(contributions: contributions)
        return try await generateSystemPrompt(
            context: context,
            resolved: resolution.resolved,
            stablePrefix: resolution.stablePrefix
        )
    }

    private static func assemblePromptWithCacheBoundary(
        sections: [SystemPromptSectionName: String],
        includeDateTimePrefix: String,
        providerStablePrefix: String?
    ) -> String {
        let stablePart = SystemPromptSectionName.stableAssemblyOrder.map { sections[$0] ?? "" }.joined()
        var volatilePart = SystemPromptSectionName.volatileAssemblyOrder.map { sections[$0] ?? "" }.joined()
        if !includeDateTimePrefix.isEmpty {
            volatilePart = includeDateTimePrefix + volatilePart
        }
        var parts: [String] = []
        if let prefix = providerStablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty {
            parts.append(prefix)
            parts.append(ProviderPromptContribution.cacheBoundaryMarker)
        }
        let trimmedStable = stablePart.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStable.isEmpty {
            parts.append(stablePart)
        }
        let trimmedVolatile = volatilePart.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVolatile.isEmpty {
            if !parts.isEmpty {
                parts.append(ProviderPromptContribution.cacheBoundaryMarker)
            }
            parts.append(volatilePart)
        }
        return parts.joined(separator: "\n\n")
    }

    public enum PromptsConfigError: Error {
        case fileNotFound
        case invalidJSON
        case skillLoaderNotFound
    }

    private struct PromptConfigValues {
        let includeCurrentDateTime: Bool
        let includeAgentSkills: Bool
        let strictAgentHarnessPrompts: Bool
    }

    private static func makePromptTemplate(includeCurrentDateTime: Bool) -> String {
        var template = ""
        if includeCurrentDateTime {
            template += "Today is {{datetime}}.\n"
        }
        template += """
{{sectionIdentity}}{{sectionCapabilities}}{{sectionConstraints}}{{sectionPersonality}}{{sectionModeDirective}}{{sectionMemory}}{{sectionSkills}}{{sectionToolGuidance}}{{sectionAttachments}}{{sectionExtraInstructions}}{{sectionDynamicAdditions}}
"""
        return template
    }

    static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d, yyyy"
        return formatter.string(from: date)
    }

    static func finalSections(
        assemblyContext: SystemPromptAssemblyContext,
        resolved: ResolvedSystemPromptSections,
        skillsFolderPath: String,
        availableSkills: String,
        includeAgentSkills: Bool,
        assemblyKind: SystemPromptAssemblyKind,
        strictAgentHarnessPrompts: Bool
    ) -> [SystemPromptSectionName: String] {
        var sections = defaultSections(
            assemblyContext: assemblyContext,
            skillsFolderPath: skillsFolderPath,
            availableSkills: availableSkills,
            includeAgentSkills: includeAgentSkills,
            assemblyKind: assemblyKind,
            strictAgentHarnessPrompts: strictAgentHarnessPrompts
        )

        for section in resolved.suppressions where !SystemPromptSectionName.overrideProof.contains(section) {
            sections[section] = ""
        }

        for (section, override) in resolved.sectionOverrides where !SystemPromptSectionName.overrideProof.contains(section) {
            sections[section] = sectionOverrideBlock(section: section, body: override)
        }

        for (section, directive) in resolved.sectionDirectives where !SystemPromptSectionName.overrideProof.contains(section) {
            let block = sectionDirectiveBlock(section: section, body: directive)
            if let existing = sections[section]?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
                sections[section] = existing + "\n\n" + block
            } else {
                sections[section] = block
            }
        }

        applyMemorySection(
            context: assemblyContext,
            sections: &sections,
            skipWhenMemoryContributionApplied: resolved.provenance[.memory] == .memory,
            suppressions: resolved.suppressions
        )
        if !assemblyContext.includeToolGuidance {
            sections[.toolGuidance] = ""
        }
        if !includeAgentSkills {
            sections[.skills] = ""
        }

        return sections
    }

    private static func sectionOverrideBlock(section: SystemPromptSectionName, body: String) -> String {
        """
---
# \(section.displayTitle)
\(body)

"""
    }

    private static func sectionDirectiveBlock(section: SystemPromptSectionName, body: String) -> String {
        """
---
# \(section.displayTitle)
\(body)

"""
    }

    private static func applyMemorySection(
        context: SystemPromptAssemblyContext,
        sections: inout [SystemPromptSectionName: String],
        skipWhenMemoryContributionApplied: Bool,
        suppressions: Set<SystemPromptSectionName> = []
    ) {
        if suppressions.contains(.memory) {
            sections[.memory] = ""
            return
        }
        if skipWhenMemoryContributionApplied {
            let memoryMode = context.memoryInjectionMode.lowercased()
            if memoryMode == "off" {
                sections[.memory] = ""
            } else if memoryMode == "skills-only", !context.includeAgentSkills {
                sections[.memory] = ""
            }
            return
        }
        let memoryMode = context.memoryInjectionMode.lowercased()
        let tier1 = context.tier1MemoryContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch memoryMode {
        case "off":
            sections[.memory] = ""
        case "skills-only":
            guard context.includeAgentSkills else {
                sections[.memory] = ""
                return
            }
            sections[.memory] = memorySectionText(
                guidance: "Use retrieved memory context only when directly relevant to active skills and tool execution.",
                tier1Content: tier1
            )
        default:
            sections[.memory] = memorySectionText(
                guidance: "Use retrieved memory context when it helps maintain correctness and continuity.",
                tier1Content: tier1
            )
        }
    }

    static func memoryLayerSectionOverride(
        memoryInjectionMode: String,
        includeAgentSkills: Bool,
        tier1Content: String
    ) -> String? {
        let tier1 = tier1Content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch memoryInjectionMode.lowercased() {
        case "off":
            return nil
        case "skills-only":
            guard includeAgentSkills else { return nil }
            return memorySectionBody(
                guidance: "Use retrieved memory context only when directly relevant to active skills and tool execution.",
                tier1Content: tier1
            )
        default:
            return memorySectionBody(
                guidance: "Use retrieved memory context when it helps maintain correctness and continuity.",
                tier1Content: tier1
            )
        }
    }

    private static func memorySectionBody(guidance: String, tier1Content: String) -> String {
        var body = guidance
        if !tier1Content.isEmpty {
            body += "\n\n<!-- provenance: engine:memory -->\n"
            body += MemoryContextFencer.fence(tier1Content)
        }
        return body
    }

    private static func defaultSections(
        assemblyContext: SystemPromptAssemblyContext,
        skillsFolderPath: String,
        availableSkills: String,
        includeAgentSkills: Bool,
        assemblyKind: SystemPromptAssemblyKind,
        strictAgentHarnessPrompts: Bool
    ) -> [SystemPromptSectionName: String] {
        var dynamicBody = ""
        if let subAgent = assemblyContext.subAgentContextPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subAgent.isEmpty {
            dynamicBody += """
---
# Sub-Agent Context
\(subAgent)

"""
        }
        var sections: [SystemPromptSectionName: String] = [
            .identity: """
---
# Conversation
This conversation id is: \(assemblyContext.conversationID)
This conversation was started on: \(assemblyContext.conversationStartDate)

""",
            .capabilities: "",
            .constraints: constraintsSectionTemplate(),
            .personality: "",
            .modeDirective: workflowSectionTemplate(
                workflowBlock: assemblyContext.workflowBlock,
                assemblyKind: assemblyKind,
                strictAgentHarnessPrompts: strictAgentHarnessPrompts
            ),
            .memory: "",
            .toolGuidance: toolGuidanceSectionTemplate(workspaceRoot: assemblyContext.workspaceRoot),
            .skills: skillsSectionTemplate(
                skillsFolderPath: skillsFolderPath,
                availableSkills: availableSkills
            ),
            .attachments: "",
            .extraInstructions: """
---
# Additional Requirements
\(assemblyContext.userSystemPrompt)

""",
            .dynamicAdditions: dynamicBody,
        ]
        if !includeAgentSkills {
            sections[.skills] = ""
        }
        return sections
    }

    private static func toolGuidanceSectionTemplate(workspaceRoot: String? = nil) -> String {
        var filesystemGuidance = """

## Filesystem paths (read_file, write_file, edit_file, glob, grep)
- Paths resolve against the **workspace root**, not your shell home directory.
- Prefer workspace-relative paths: `MyProject/Sources/App.swift`
- Absolute paths are OK when they lie under the workspace root.
- Do not use `~` or `$HOME` in file tool paths.
"""
        if let workspaceRoot = workspaceRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !workspaceRoot.isEmpty {
            filesystemGuidance += "\n- Workspace root: `\(workspaceRoot)`\n"
        }
        return """
---
# Tools
In this environment you have access to a set of tools you can use to help you gather information and perform tasks.

**IMPORTANT** When you need to use tools do not describe, announce, or explain what tool you plan on using. Just call the tool via the function call. If your response inlcudes the phrase "let me..." but does not contain a tool call you are doing something wrong
\(filesystemGuidance)
## Examples
### WRONG - you should never do this
```
{"role": "assistant", "content": "Now let me clean up the example files and create the final file:", "tool_calls": []}
```

### OK - You can do this
```
{"role": "assistant", "content": "Now let me clean up the example files and create the final file:", "tool_calls": ["create_file("myFinalFile.txt")"]}
```

### BEST - You should do this
```
{"role": "assistant", "content": "", "tool_calls": ["create_file("myFinalFile.txt")"]}
```

"""
    }

    private static func constraintsSectionTemplate() -> String {
        """
---
# Constraints
## Triggers and provenance
Some user messages start with [trigger] followed by optional key-value pairs on the same line (e.g. name=...; type=...; received_at=...), then a blank line, then the message body. Such messages come from cron jobs, event-driven scripts, external agents, or automation (e.g. Zapier)—the human user is not necessarily present. Use the key-value metadata to gauge provenance and trust as you see fit, and treat the content as background or triggered input (e.g. store for later, add to a task list) rather than as live chat requiring an immediate back-and-forth.

## Approvals
Some tools and commands require human approval before they run. The harness presents these approvals through native UI (buttons / cards) on whatever surface the user is on, and resolves them itself. Do not narrate the approval flow or invent your own confirmation protocol: never write things like "type yes to continue", "reply APPROVE", or "let me know if I should proceed". Just make the tool call; if approval is required the harness will prompt the user and either resume or report the denial back to you.

"""
    }

    private static func skillsSectionTemplate(
        skillsFolderPath: String,
        availableSkills: String
    ) -> String {
        """
---
# Agent Skills
You have access to Agent Skills. The Agent Skills spec can be found a https://agentskills.io/specification
Agent Skills are a lightweight, open format for extending AI agent capabilities with specialized knowledge and workflows.
Skills use progressive disclosure to manage context efficiently:
1. Discovery: At startup, the name and description of each available skill are loaded, just enough to know when it might be relevant. The list of loaded skills is provided below in XML format.
2. Activation: When a task matches a skill’s description, you will read the full SKILL.md instructions into context. Activating skills can be done through one of your provided functions/tool calls. After activation, the skill's instructions are returned in the activation tool result.
3. Execution: You will follow the instructions, optionally loading referenced files or executing bundled code as needed. Loading files or executing scripts can be done through one of your provided functions/tool calls.
This approach keeps you fast while giving you access to more context on demand.
The root skills folder is \(skillsFolderPath).
## Available Agent Skills:
\(availableSkills)

"""
    }

    private static func workflowSectionTemplate(
        workflowBlock: String,
        assemblyKind: SystemPromptAssemblyKind,
        strictAgentHarnessPrompts: Bool
    ) -> String {
        switch assemblyKind {
        case .chat:
            return ""
        case .planCollaboration:
            return """
---
# Plan
You are an agentic planning agent.
You collaborate with the user to define a job as a structured plan. In this conversation you are in **plan** mode only: use **create_plan**, **edit_plan** (optional **overview**, **goal**, and **notes**), **add_plan_task**, **delete_plan_task**, and **get_plan** for `plan.md`; do not execute build work here. When the plan is ready for implementation, call **exit_plan_mode** — that call is the plan approval request (do not ask for approval in free text).
## Current focus
\(workflowBlock)

"""
        case .agentBuild:
            var section = """
---
# Agent
You are an agentic build agent.
**Your working memory is deliberately limited:** the conversation context you see is shortened and will not preserve everything across turns. Anything important you learn while building—paths, APIs, commands, doc URLs, decisions, env var **names**—**must** be saved with **add_plan_note** into `## Notes` in plan.md, or it will almost certainly be **forgotten** later.
You are executing the plan in build mode: update task status with **update_plan_task**; use **add_plan_note** for durable discoveries in `## Notes`. **create_plan** and **edit_plan** are denied in this mode—use **plan** mode (via **enter_plan_mode** with user consent) for full-document plan authoring and task-list mutations. Use tools until the work is done or you need user input.
## Examples: prose vs tool calls (same intent: read a file)
- **Bad:** Assistant message: “Let me read the file located at `/path/to/file.md`.” with **no tool call**—nothing was actually read.
- **Better:** That same sentence **and** a tool call that reads `/path/to/file.md` (the call does the work; the sentence is optional noise).
- **Best:** **Empty** assistant message content—**only** the tool call that reads the file. **Prefer this.**
## Current focus
\(workflowBlock)

"""
            if strictAgentHarnessPrompts {
                section += """
## Harness behavior (build)
- Your objective is to **finish the job**, not to chat. Prefer **tool calls** over long natural-language explanations.
- Each cycle: **observe** the latest messages and plan state → **decide** the single best next action → **act** via a tool call (or **declare_agent_build_complete** only when every plan task line is complete and nothing is blocked).
- Do **not** ask the user questions unless you are **blocked** (use task status blocked / `[!]` when waiting on the user or external systems).
- Do not claim work is done until plan.md reflects reality via the plan tools.
- Treat **add_plan_note** as mandatory for non-obvious facts you will need again: the harness does not give you unbounded recall. Do **not** store raw secrets, API keys, or token values in plan.md—use placeholders or refer to the user’s secret store.

"""
            }
            return section
        }
    }

    private static func memorySectionText(guidance: String, tier1Content: String) -> String {
        var body = """
---
# Memory
\(guidance)

"""
        if !tier1Content.isEmpty {
            body += """
<!-- provenance: engine:memory -->
\(MemoryContextFencer.fence(tier1Content))

"""
        }
        return body
    }

    static func referenceDate(from additionalMetadata: [String: String]) -> Date {
        guard let iso = additionalMetadata[SystemPromptAssemblyMetadataKeys.assembleReferenceDateISO]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !iso.isEmpty else {
            return Date()
        }
        return referenceDate(fromAssembleReferenceDateISO: iso) ?? Date()
    }

    static func referenceDate(fromAssembleReferenceDateISO iso: String) -> Date? {
        let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: trimmed) {
            return parsed
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    static func assembleReferenceDateISOString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func assemblyFingerprintHex(
        resolved: ResolvedModeProfile,
        toolPolicySignature: String,
        routingPolicyTools: [String],
        routingPolicySkills: [String]
    ) -> String {
        SystemPromptAssemblyFingerprint.hexDigest(
            resolved: resolved,
            strictAgentHarnessPrompts: strictAgentHarnessPrompts,
            includeAgentSkills: includeAgentSkills,
            includeDateTime: includeCurrentDateTime,
            toolPolicySignature: toolPolicySignature,
            routingPolicyTools: routingPolicyTools,
            routingPolicySkills: routingPolicySkills
        )
    }
}
