import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import Testing
@testable import SwiftAgentHarness

@Suite("ToolCallBoundApproval")
struct ToolCallBoundApprovalTests {
    @Test("allow-once approval binds to arguments; swapped args re-prompt")
    func allowOnceBindsToArguments() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container)
        let services = HarnessRuntimeSessionFactory.makeServices(
            deps: deps,
            persistenceDomain: deps.persistenceDomain
        )
        let service = services.toolApprovalRuntimeService
        let conversationID = UUID()
        let runID = UUID()
        let approvedArgs = JSON.object(["path": .string("/a")])
        let binding = ToolCallApprovalBinding.from(toolName: "write_file", arguments: approvedArgs)

        await service.applyToolApprovalResolution(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
            route: .user,
            status: .approved,
            source: "test",
            reason: nil,
            kind: .manual,
            decision: .allowOnce,
            policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
            publicationSource: "test"
        )

        var configuration = HarnessRuntimeSession.Configuration()
        let merged = await service.configurationApplyingToolApprovals(
            configuration,
            conversationID: conversationID,
            runID: runID
        )

        let approvedCall = ToolCallRequest(
            id: "c1",
            name: "write_file",
            arguments: approvedArgs
        )
        let swappedCall = ToolCallRequest(
            id: "c1",
            name: "write_file",
            arguments: .object(["path": .string("/b")])
        )
        #expect(ToolCallApprovalPolicy.isPreApproved(call: approvedCall, configuration: merged))
        #expect(ToolCallApprovalPolicy.isPreApproved(call: swappedCall, configuration: merged) == false)
    }

    @Test("durable preApprovedToolNames bypasses all argument variants")
    func durableNameBypassesAllArgs() async {
        var configuration = HarnessRuntimeSession.Configuration()
        configuration.preApprovedToolNames = ["write_file"]
        let callA = ToolCallRequest(
            id: "c1",
            name: "write_file",
            arguments: .object(["path": .string("/a")])
        )
        let callB = ToolCallRequest(
            id: "c2",
            name: "write_file",
            arguments: .object(["path": .string("/b")])
        )
        #expect(ToolCallApprovalPolicy.isPreApproved(call: callA, configuration: configuration))
        #expect(ToolCallApprovalPolicy.isPreApproved(call: callB, configuration: configuration))
    }

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
}
