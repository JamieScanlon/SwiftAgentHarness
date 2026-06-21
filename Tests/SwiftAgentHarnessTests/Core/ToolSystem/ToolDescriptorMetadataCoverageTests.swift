import Foundation
import EasyJSON
import SwiftAgentKit
import SwiftAgentKitSkills
import Testing
@testable import SwiftAgentHarness

@Suite("Tool descriptor metadata coverage")
struct ToolDescriptorMetadataCoverageTests {
    private final class StubConversationsDataProvider: ConversationsDataProviding, Sendable {
        func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
        func getConversation(id: UUID) async -> ModelConversation? { nil }
        func switchConversation(id: UUID, message: String?) async throws -> String? { nil }
    }

    private final class StubModeTransitionDataProvider: ModeTransitionDataProviding, Sendable {
        func getConversation(id: UUID) async -> ModelConversation? { nil }
        func transitionConversationMode(
            conversationID: UUID,
            targetMode: InteractionMode,
            initiatedBy: String,
            reason: String?
        ) async throws -> ModeTransitionApplyResult { .applied }
    }

    private actor StubCompactionPerformer: ContextCompactionPerforming {
        func performManualCompaction(
            conversationID: UUID,
            trigger: ContextCompactionManualTrigger,
            reason: String?
        ) async throws -> ContextCompactionManualResult {
            ContextCompactionManualResult(
                trigger: trigger,
                conversationID: conversationID,
                originalMessages: [],
                compactedMessages: [],
                diagnostics: nil,
                messageProvenance: nil,
                noopReason: nil,
                refusalReason: nil,
                persisted: true,
                promptTokens: 0,
                thresholdTokens: 0
            )
        }
    }

    @Test("local providers annotate effectClass and executionParallelHint for all declared tools")
    func localProvidersAnnotateDescriptors() async {
        let conversations = ConversationsToolProvider(dataProvider: StubConversationsDataProvider(), logger: nil)
        let plans = AgentPlanToolProvider(dataProvider: StubConversationsDataProvider(), logger: nil)
        let terminations = TerminationToolProvider(dataProvider: StubConversationsDataProvider(), logger: nil)
        let transitions = ModeTransitionToolProvider(dataProvider: StubModeTransitionDataProvider(), logger: nil)
        let compaction = ContextCompactionToolProvider(performer: StubCompactionPerformer(), logger: nil)

        let providers: [any ToolProvider] = [conversations, plans, terminations, transitions, compaction]
        for provider in providers {
            let tools = await provider.availableTools()
            #expect(!tools.isEmpty)
            for tool in tools {
                #expect(await provider.effectClass(for: tool) != .unknown)
                #expect(await provider.executionParallelHint(for: tool) != .unknown)
            }
        }
    }

    @Test("skill policy wrapper annotates skill tool descriptors")
    func skillPolicyWrapperAnnotatesSkillDescriptors() async {
        let loader = SkillLoader(skillsDirectoryURL: FileManager.default.temporaryDirectory)
        let provider = SkillPolicySkillsToolProvider(
            inner: SkillsToolProvider(loader: loader, logger: nil),
            canActivateSkill: { _ in true }
        )
        let listDefinition = ToolDefinition(
            name: SkillsToolProvider.listActivatedToolName,
            description: "",
            parameters: [],
            type: .function
        )
        let activateDefinition = ToolDefinition(
            name: SkillsToolProvider.activateToolName,
            description: "",
            parameters: [],
            type: .function
        )
        let deactivateDefinition = ToolDefinition(
            name: SkillsToolProvider.deactivateToolName,
            description: "",
            parameters: [],
            type: .function
        )

        #expect(await provider.effectClass(for: listDefinition) == .readOnly)
        #expect(await provider.executionParallelHint(for: listDefinition) == .parallelizable)
        #expect(await provider.effectClass(for: activateDefinition) == .mutating)
        #expect(await provider.executionParallelHint(for: activateDefinition) == .serialOnly)
        #expect(await provider.effectClass(for: deactivateDefinition) == .mutating)
        #expect(await provider.executionParallelHint(for: deactivateDefinition) == .serialOnly)
    }

    @Test("terminal tools are flagged as halting loop")
    func terminalToolsCarryHaltingMetadata() {
        let haltNames: Set<String> = [
            AgentPlanToolProvider.declareAgentBuildCompleteToolName,
            ModeTransitionToolProvider.exitPlanModeToolName,
            "finish",
            "ask_user",
        ]
        let entries = haltNames.map { name in
            ToolRegistryEntry(
                definition: ToolDefinition(name: name, description: "d", parameters: [], type: .function),
                source: .local
            )
        }
        for entry in entries {
            #expect(entry.haltsLoop)
        }
        let thinkEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: TerminationToolProvider.thinkToolName, description: "d", parameters: [], type: .function),
            source: .local
        )
        #expect(thinkEntry.haltsLoop == false)
        let nonTerminal = ToolRegistryEntry(
            definition: ToolDefinition(name: AgentPlanToolProvider.getPlanToolName, description: "d", parameters: [], type: .function),
            source: .local
        )
        #expect(nonTerminal.haltsLoop == false)
    }
}
