import Foundation

/// The built-in delegate roles, seeded so delegation works with no operator configuration.
///
/// Each entry pairs with a built-in mode profile of the same shape (`subagent-explore`,
/// `subagent-plan`, `subagent-general`) that carries the actual capability grant — the definition
/// only names the role and its delivery mode. A `localAgents` row with a matching slug replaces the
/// built-in outright.
enum LocalAgentBuiltInCatalog {
    static let exploreToolName = "delegate_explore"
    static let planToolName = "delegate_plan"
    static let generalPurposeToolName = "delegate_general_purpose"

    /// Template default: flat delegation. A delegate may be spawned from the main loop but cannot
    /// itself spawn (its mode profile denies sub-agents outright).
    private static let flatSpawnDepth = 1

    static func all() -> [LocalAgentDefinition] {
        [
            LocalAgentDefinition(
                toolName: exploreToolName,
                displayName: "Explore",
                description: """
Fast read-only codebase search. Use for locating code, tracing usages, or answering \
"where is X handled?" across many files without pulling the search noise into this conversation. \
Cannot modify anything.
""",
                modeProfileID: "subagent-explore",
                modelRef: nil,
                longRunning: false,
                maxRecursionDepth: flatSpawnDepth
            ),
            LocalAgentDefinition(
                toolName: planToolName,
                displayName: "Plan",
                description: """
Read-only architecture and planning. Use for "how should I implement X?" — it investigates, then \
returns an approach, trade-offs, risks, and the critical files to change. Cannot modify anything.
""",
                modeProfileID: "subagent-plan",
                modelRef: nil,
                longRunning: false,
                maxRecursionDepth: flatSpawnDepth
            ),
            LocalAgentDefinition(
                toolName: generalPurposeToolName,
                displayName: "General Purpose",
                description: """
Runs a self-contained task in its own context window and reports back. Use when the work is \
complex enough that its intermediate steps would crowd this conversation. Has the full tool \
surface but cannot delegate further.
""",
                modeProfileID: "subagent-general",
                modelRef: nil,
                longRunning: false,
                maxRecursionDepth: flatSpawnDepth
            ),
        ]
    }
}
