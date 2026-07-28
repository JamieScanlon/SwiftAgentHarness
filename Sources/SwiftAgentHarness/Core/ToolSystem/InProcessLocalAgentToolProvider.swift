import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Publishes operator-declared local agents as `delegate_*` function tools.
///
/// The provider is a *registration* surface only. Delegate calls are intercepted upstream by
/// ``SubAgentDelegateInvocationService/dispatchModelTurnIfDelegate(call:conversationID:runID:orchestrator:snapshot:spawnService:)``
/// and routed to the Sub-Agent Pool, so ``executeTool(_:)`` is unreachable on the dispatch path and
/// fails loudly rather than silently returning an empty result if that routing ever regresses.
public struct InProcessLocalAgentToolProvider: ToolProvider, ToolDescriptorHinting {
    /// Full task brief handed to the child. Read back by `SubAgentSpawnService.delegateInstructions(from:)`.
    public static let instructionsParameterName = "instructions"
    /// Short label used for the child's topic and for lifecycle/UI rows.
    public static let descriptionParameterName = "description"

    private let definitions: [LocalAgentDefinition]
    private let logger: Logger?

    public var name: String { "InProcessLocalAgents" }

    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        var hints: [String: ToolDescriptorHints] = [:]
        for definition in definitions {
            hints[definition.toolName] = ToolDescriptorHints(
                effectClass: .mutating,
                parallelHint: .parallelizable,
                policyTags: Self.policyTags(for: definition)
            )
        }
        return hints
    }

    public init(definitions: [LocalAgentDefinition], logger: Logger? = nil) {
        self.definitions = definitions.sorted { $0.toolName < $1.toolName }
        self.logger = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "InProcessLocalAgentToolProvider")
        )
    }

    public func availableTools() async -> [ToolDefinition] {
        definitions.map { definition in
            ToolDefinition(
                name: definition.toolName,
                description: Self.toolDescription(for: definition),
                parameters: [
                    .init(
                        name: Self.instructionsParameterName,
                        description: """
The complete task brief for the delegate. It starts from a fresh conversation and has zero \
knowledge of this conversation, prior tool calls, or anything discussed before now — include every \
file path, constraint, and success criterion it needs.
""",
                        type: "string",
                        required: true
                    ),
                    .init(
                        name: Self.descriptionParameterName,
                        description: "Short 3-5 word label for this delegation, used for progress display.",
                        type: "string",
                        required: false
                    ),
                ],
                type: .function
            )
        }
    }

    public func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        guard let local = definitions.first(where: { $0.toolName == definition.name }) else { return [] }
        return Self.policyTags(for: local)
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        logger?.error(
            "[InProcessLocalAgentToolProvider] delegate '\(toolCall.name)' reached provider execution; Sub-Agent Pool routing did not intercept it"
        )
        throw Error.delegateDispatchNotIntercepted(toolCall.name)
    }

    /// Declares the execution environment so `resolvedTransportKind` resolves these tools to
    /// ``SubAgentTransportKind/inProcess``, and carries the exact-content/compaction protection that
    /// delegate results require.
    static func policyTags(for _: LocalAgentDefinition) -> [ToolPolicyTag] {
        [
            ToolPolicyTag(
                rawValue: ExecutionEnvironmentTagParser.kindPrefix
                    + ToolRegistryEntry.ExecutionEnvironmentKind.local.rawValue
            ),
            ToolPolicyTag(
                rawValue: ExecutionEnvironmentTagParser.adapterPrefix + SubAgentTransportKind.inProcess.rawValue
            ),
            ToolPolicyTag(
                rawValue: ExecutionEnvironmentTagParser.isolationPrefix
                    + ToolRegistryEntry.ExecutionIsolationLevel.inProcess.rawValue
            ),
            ToolRegistryResultFormattingPolicy.exactContentObservationPolicyTag(),
            ToolRegistryResultFormattingPolicy.compactionProtectedPolicyTag(),
        ]
    }

    static func toolDescription(for definition: LocalAgentDefinition) -> String {
        """
        \(definition.description)

        Delegates to the "\(definition.displayName)" agent, which runs in its own isolated \
        conversation and returns its final report as this tool's result. Put the full brief in \
        `instructions` — the delegate cannot see this conversation.
        """
    }

    enum Error: Swift.Error, Equatable {
        case delegateDispatchNotIntercepted(String)
    }
}
