import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolApprovalRuntimeService")
struct ToolApprovalRuntimeServiceTests {
    private func makeDependencies(container: ModelContainer) -> ConversationRuntimeDependencies {
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        return ConversationRuntimeDependencies(
            persistenceDomain: domain,
            compactionCoordinator: CompactionConcurrencyCoordinator(),
            contextEngine: DefaultContextEngine(compactionCoordinator: CompactionConcurrencyCoordinator(), logger: nil),
            contextAssemblyRuntime: ContextAssemblyRuntimeFacade(
                persistenceDomain: domain,
                conversationTransformConfiguration: .default
            ),
            modeRegistry: ModeRegistryTestSupport.makePort(),
            llmFactory: StandardModelLLMFactory(),
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            runtimeLaneCoordinator: RuntimeLaneCoordinator(configuration: .default),
            toolPolicy: .unrestricted,
            trustPolicyConfiguration: .disabled,
            agentHarness: .default,
            thinkingPolicyConfiguration: .default,
            conversationTransformConfiguration: .default,
            conversationTransformer: NoOpConversationTransformer(),
            registryEntryProvider: nil,
            rankedRegistryEntriesProvider: nil,
            delegateCostTracker: nil,
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.defaultInternal,
            logger: nil
        )
    }

    @Test("approvalRouteForConversation returns user for root conversation")
    func approvalRouteUserForRoot() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container)
        let services = HarnessRuntimeSessionFactory.makeServices(
            deps: deps,
            persistenceDomain: deps.persistenceDomain
        )
        let service = services.toolApprovalRuntimeService
        let conversationID = UUID()

        let route = await service.approvalRouteForConversation(conversationID: conversationID)
        #expect(route == .user)
    }

    @Test("configurationApplyingToolApprovals unions bindings for allow-once and names for allow-always")
    func configurationApplyingToolApprovalsUnionsPreApprovals() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container)
        let services = HarnessRuntimeSessionFactory.makeServices(
            deps: deps,
            persistenceDomain: deps.persistenceDomain
        )
        let service = services.toolApprovalRuntimeService
        let conversationID = UUID()
        var configuration = HarnessRuntimeSession.Configuration()
        configuration.preApprovedToolNames = ["caller_tool"]
        let onceBinding = ToolCallApprovalBinding.from(
            toolName: "store_tool",
            arguments: .object(["path": .string("/a")])
        )
        await service.applyToolApprovalResolution(
            conversationID: conversationID,
            runID: nil,
            binding: onceBinding,
            route: .user,
            status: .approved,
            source: "test",
            reason: nil,
            kind: .manual,
            decision: .allowOnce,
            policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
            publicationSource: "test"
        )
        await service.applyToolApprovalResolution(
            conversationID: conversationID,
            runID: nil,
            binding: ToolCallApprovalBinding.from(toolName: "durable_tool", arguments: .object([:])),
            route: .user,
            status: .approved,
            source: "test",
            reason: nil,
            kind: .manual,
            decision: .allowAlways,
            policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
            publicationSource: "test"
        )
        let merged = await service.configurationApplyingToolApprovals(
            configuration,
            conversationID: conversationID,
            runID: nil
        )
        #expect(merged.preApprovedToolNames.contains("caller_tool"))
        #expect(merged.preApprovedToolNames.contains("durable_tool"))
        #expect(merged.preApprovedToolNames.contains("store_tool") == false)
        #expect(merged.preApprovedCallBindings.contains(onceBinding))
    }
}
