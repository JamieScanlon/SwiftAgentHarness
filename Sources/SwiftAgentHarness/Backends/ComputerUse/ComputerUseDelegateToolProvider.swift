import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Publishes the computer-use specialist to parent conversations as `delegate_computer_use`.
///
/// Registration only: delegate calls are intercepted by the Sub-Agent Pool before provider execution, which runs
/// the specialist in an isolated child conversation and hands back a structured ``ComputerUseResult``.
struct ComputerUseDelegateToolProvider: ToolProvider, ToolDescriptorHinting {
    static let toolName = LocalAgentToolNaming.delegateToolPrefix + "computer_use"
    static let displayName = "Computer Use"
    /// What `tool_search` matches besides the description.
    static let searchHint = "computer use desktop app application GUI screen window click type mouse keyboard"

    let targets: [DisplayTargetManifest]
    let defaults: ComputerUseSpecialistDefaults

    var name: String { "ComputerUseDelegate" }

    var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [Self.toolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly, policyTags: Self.policyTags)]
    }

    /// Deferred: the parent sees `tool_search` first, so a cheaper channel for the job wins.
    static var policyTags: [ToolPolicyTag] {
        InProcessLocalAgentToolProvider.policyTags(for: specialistDefinition(ComputerUseSpecialistProfile()))
            + [DeferredToolLoading.deferLoadingTag, DeferredToolLoading.searchHintTag(searchHint)]
    }

    /// The computer-use family: everything the specialist may call.
    static let specialistToolNames = ComputerUseToolProvider.toolNames + ComputerUseNativeToolset.allRegisteredToolNames.sorted()

    /// The child's capability: the computer-use family and nothing else — no shell, files, or messaging.
    static func specialistDefinition(_ profile: ComputerUseSpecialistProfile) -> LocalAgentDefinition {
        LocalAgentDefinition(
            toolName: toolName,
            displayName: displayName,
            description: "Operates a computer screen to complete a task.",
            modeProfileID: profile.modeProfileID,
            modelRef: profile.modelRef,
            toolsAllow: specialistToolNames,
            longRunning: false,
            runTimeoutSeconds: profile.runTimeoutSeconds
        )
    }

    func availableTools() async -> [ToolDefinition] {
        let targetList = targets.map { "\($0.id) (\($0.label), \($0.isolation.rawValue))" }.joined(separator: ", ")
        return [
            ToolDefinition(
                name: Self.toolName,
                description: """
                Hand a task that needs a computer screen to a computer-use specialist. Use this only when no API, \
                MCP tool, or command line can do the job. The specialist works in its own conversation and cannot \
                see this one, so the goal, criteria, and constraints must stand alone. The user approves the apps \
                and domains before it starts. It returns JSON with status (done, done-unverified, needs-user, \
                blocked, budget-exhausted, failed), result, verification per criterion, and any handoff the user \
                must complete.
                """,
                parameters: [
                    .init(name: "goal", description: "What to accomplish, stated fully.", type: "string", required: true),
                    .init(
                        name: "success_criteria",
                        description: "One checkable criterion per line. Each is verified on screen before the task counts as done.",
                        type: "string",
                        required: true
                    ),
                    .init(name: "constraints", description: "Rules to keep throughout, one per line.", type: "string", required: false),
                    .init(
                        name: "apps",
                        description: "Apps to grant, comma-separated as bundle-id:tier[:flags], tier view, click, or full; flags clipboard-read, clipboard-write, system-keys joined with +. Example: com.apple.TextEdit:full",
                        type: "string",
                        required: false
                    ),
                    .init(
                        name: "domains",
                        description: "Web domains to grant, comma-separated as domain:tier. A web task needs a domain here and a browser in apps: browsers stay at view and aren't launched, and the specialist opens pages in the granted browser. Example: docs.example.com:click",
                        type: "string",
                        required: false
                    ),
                    .init(
                        name: "target",
                        description: "Display target id. Default \(defaults.target). Available: \(targetList.isEmpty ? "none" : targetList).",
                        type: "string",
                        required: false
                    ),
                    .init(
                        name: "steps",
                        description: "Expected size of the work in actions, for example about 15 to open an app and fill in a form. Default \(defaults.budgets.defaultSteps). The harness extends it while the task makes progress.",
                        type: "integer",
                        required: false
                    ),
                    .init(
                        name: "deadline",
                        description: "Only a cutoff the user stated, as an ISO 8601 date-time with a UTC offset, such as 2026-10-29T15:00:00-07:00. Never an estimate of how long the task takes.",
                        type: "string",
                        required: false
                    ),
                    .init(name: "return_schema", description: "Optional JSON Schema for the result.", type: "string", required: false),
                    .init(
                        name: InProcessLocalAgentToolProvider.descriptionParameterName,
                        description: "Short 3-5 word label for progress display.",
                        type: "string",
                        required: false
                    ),
                ],
                type: .function
            ),
        ]
    }

    func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        definition.name == Self.toolName ? Self.policyTags : []
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        throw InProcessLocalAgentToolProvider.Error.delegateDispatchNotIntercepted(toolCall.name)
    }
}
