import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

enum HarnessRuntimeOutboundTestDoubles {
    private struct UnimplementedToolApproval: ToolApprovalRuntimeServicing {
        func consumeTimedOutToolApprovalsForRuntime(
            conversationID: UUID,
            runID: UUID?,
            iteration: Int?,
            modelID: UUID?,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter
        ) async { unimplementedVoid() }
        func configurationApplyingToolApprovals(
            _ configuration: HarnessRuntimeSession.Configuration,
            conversationID: UUID,
            runID: UUID?
        ) async -> HarnessRuntimeSession.Configuration { unimplemented() }
        func approvalContractSpec(
            toolName: String,
            route: ToolApprovalRoute,
            isElevated: Bool,
            arguments: JSON?
        ) -> ToolApprovalContractSpec { unimplemented() }
        func registerPendingToolApproval(
            conversationID: UUID,
            runID: UUID?,
            binding: ToolCallApprovalBinding,
            route: ToolApprovalRoute,
            isElevated: Bool,
            requestedAt: Date
        ) async -> Bool { unimplemented() }
        func registerPendingToolApproval(
            conversationID: UUID,
            runID: UUID?,
            call: ToolCallRequest,
            route: ToolApprovalRoute,
            isElevated: Bool,
            requestedAt: Date
        ) async -> Bool { unimplemented() }
        func toolApprovalResolution(
            conversationID: UUID,
            runID: UUID?,
            binding: ToolCallApprovalBinding,
            route: ToolApprovalRoute
        ) async -> ToolApprovalResolution? { unimplemented() }
        func waitForToolApprovalResolution(
            conversationID: UUID,
            runID: UUID?,
            binding: ToolCallApprovalBinding,
            route: ToolApprovalRoute
        ) async throws -> ToolApprovalResolution { unimplemented() }
    }

    private struct UnimplementedOrchestratorToolPolicy: OrchestratorRuntimeToolPolicyServicing {
        func allToolRegistryEntriesForOrchestration(orchestrator: SwiftAgentKitOrchestrator) async -> [ToolRegistryEntry] {
            unimplemented()
        }
        func buildToolTurnPolicySnapshot(
            allEntries: [ToolRegistryEntry],
            conversation: ModelConversation,
            configuration: HarnessRuntimeSession.Configuration
        ) async -> RuntimeToolTurnPolicySnapshot { unimplemented() }
        func orchestratorInvocationOptions(
            for conversation: ModelConversation?,
            toolTurnSnapshot: RuntimeToolTurnPolicySnapshot?,
            effectiveToolEntries: [ToolRegistryEntry],
            availabilitySnapshots: [RuntimeToolAvailabilitySnapshot],
            forcedToolChoiceRequired: Bool
        ) async -> OrchestratorInvocationOptions { unimplemented() }
        func acquireOrchestrator(
            conversation: ModelConversation,
            model: Model
        ) async -> OrchestratorAcquisition? { unimplemented() }
        func releaseOrchestrator(_ handle: OrchestratorHandle) async { unimplementedVoid() }
        func buildTransientOrchestratorForCatalog(
            model: Model,
            conversation: ModelConversation?
        ) async -> SwiftAgentKitOrchestrator? { unimplemented() }
    }

    private struct UnimplementedContextProjection: ContextProjectionTransformServicing {
        func transformedContextMessages(
            from originalMessages: [Message],
            conversation: ModelConversation,
            phase: ContextTransformInvocationPhase,
            configuration: HarnessRuntimeSession.Configuration,
            gatingOverride: ContextCompactionGatingOptions?
        ) async -> [Message] { unimplemented() }

        func cachedProjectedMemorySelectionKeys(conversationID: UUID) async -> Set<String> {
            let _ = conversationID
            return unimplemented()
        }
    }

    private struct UnimplementedLifecycle: ConversationLifecycleServicing {
        func deleteConversation(conversationID: UUID, hard: Bool) async throws { unimplementedVoid() }
        func branchConversation(
            conversationID: UUID,
            userMessageID: UUID,
            selectionBehavior: BranchSelectionBehavior,
            childLineageKind: ConversationLineageKind = .branch
        ) async throws -> UUID { unimplemented() }
        func copyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID {
            unimplemented()
        }
        func invalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws { unimplementedVoid() }
        func latestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? { unimplemented() }
        func listEngineArtifactKeys(conversationID: UUID) async throws -> [String] { unimplemented() }
        func getEngineArtifact(conversationID: UUID, key: String) async throws -> Data? { unimplemented() }
        func putEngineArtifact(conversationID: UUID, key: String, data: Data) async throws { unimplementedVoid() }
        func evictEngineArtifacts(conversationID: UUID, key: String?) async throws { unimplementedVoid() }
        func persistSplitSelectingNewThread(
            sourceConversationID: UUID,
            atUserMessageID: UUID,
            adoptSelection: Bool,
            childLineageKind: ConversationLineageKind = .branch
        ) async throws -> (newConversationID: UUID, anchorNewUserMessageID: UUID) { unimplemented() }
    }

    private struct UnimplementedSlashCommand: SlashCommandRuntimeDispatching {
        func runSlashCommandIfNeeded(_ text: String, conversationID: UUID) async throws -> ChatStreamResponse? {
            unimplemented()
        }

        func processControlInputBoundary(
            text: String,
            conversationID: UUID,
            trustClass: TrustPolicyClass?,
            senderLabel: String?
        ) async throws -> ControlInputBoundaryOutcome {
            unimplemented()
        }
    }

    private static func unimplementedVoid() -> Never {
        preconditionFailure("HarnessRuntimeOutboundTestDoubles stub invoked unexpectedly")
    }

    private static func unimplemented<T>() -> T {
        preconditionFailure("HarnessRuntimeOutboundTestDoubles stub invoked unexpectedly")
    }

    static func stubCollaborators() -> AgentRuntimeOutboundCollaborators {
        AgentRuntimeOutboundCollaborators(
            toolApproval: UnimplementedToolApproval(),
            orchestratorRuntime: UnimplementedOrchestratorToolPolicy(),
            contextProjection: UnimplementedContextProjection(),
            lifecycle: UnimplementedLifecycle(),
            slashCommand: UnimplementedSlashCommand()
        )
    }
}
