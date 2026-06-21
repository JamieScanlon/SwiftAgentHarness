import Foundation
import SwiftAgentKit
import SwiftAgentKitACP
import Testing
@testable import SwiftAgentHarness

@Suite("Harness ACP client delegate")
struct HarnessACPClientDelegateTests {
    private func makeDelegate(denyBash: Bool, trustGatesExecution: Bool = true) -> HarnessACPClientDelegate {
        let bashEntry = ToolRegistryEntry(
            definition: ToolDefinition(
                name: WorkspaceFilesystemToolProvider.bashToolName,
                description: "bash",
                parameters: [],
                type: .function
            ),
            source: .local
        )
        let processEntry = ToolRegistryEntry(
            definition: ToolDefinition(
                name: WorkspaceFilesystemToolProvider.processToolName,
                description: "process",
                parameters: [],
                type: .function
            ),
            source: .local
        )
        let conversation = ModelConversation(
            id: UUID(),
            model: Model(
                protocol: .openAIAPI,
                modelName: "test",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion, .tools],
                modelProtocol: .openAIAPI
            ),
            systemPrompt: "sys",
            interactionMode: .chat
        )
        var runtimeConfiguration = AgentRuntimeTurnConfiguration(
            managerConfiguration: .init(enableTools: true, enableAgents: true)
        )
        runtimeConfiguration.inputTrustRaw = SubAgentTrustLevel.unknownParty.rawValue
        var resolved = ResolvedModeProfile.builtIn(for: conversation.interactionMode)
        resolved.tools = ModeProfileToolsSlice(
            allow: ["*"],
            deny: denyBash ? [WorkspaceFilesystemToolProvider.bashToolName] : [],
            approvalPolicy: nil
        )
        let context = SubAgentACPToolDispatchContext(
            conversation: conversation,
            workspaceRoot: FileManager.default.currentDirectoryPath,
            execRuntime: ExecRuntimeService(workspaceRoot: FileManager.default.currentDirectoryPath),
            runtimeContext: ExecRuntimeContext(sessionKey: "test", agentID: "test", isMainSession: true),
            gateway: DefaultToolSystemGateway(),
            toolPolicy: ToolPolicyConfiguration(),
            trustPolicy: trustGatesExecution
                ? TrustPolicyConfiguration(mode: .gateExecution, safeDefaultClass: .lowTrust)
                : .disabled,
            modePolicyContext: ModePolicyContext(conversation: conversation, resolvedProfile: resolved),
            runtimeConfiguration: runtimeConfiguration,
            subAgentPool: DefaultSubAgentPool(),
            toolEntries: denyBash ? [bashEntry] : [processEntry],
            permissionPolicy: .askUser,
            permissionAlreadyGranted: false,
            delegateToolName: "delegate_acp"
        )
        return HarnessACPClientDelegate(
            context: context,
            executor: LocalSandboxBashExecutor(
                execRuntime: context.execRuntime,
                runtimeContext: context.runtimeContext
            ),
            lifecycleID: "lifecycle-test"
        )
    }

    @Test("createTerminal rejected when bash denied for unknown-party child")
    func createTerminalRejectedWhenDenied() async {
        let delegate = makeDelegate(denyBash: true)
        do {
            _ = try await delegate.createTerminal(ACPCreateTerminalRequest(sessionId: "s1", command: "echo", args: ["hi"]))
            Issue.record("Expected rejection")
        } catch let error as JSONRPCConnectionError {
            if case .invalidRequest = error {
                #expect(Bool(true))
            } else {
                Issue.record("Expected invalidRequest, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("waitForTerminalExit uses extended poll budget")
    func waitForTerminalExitPollBudget() {
        #expect(ACPTerminalWaitPolicy.maxPolls == 3000)
    }

    @Test("waitForTerminalExit returns immediately for foreground snapshot")
    func waitForTerminalExitForegroundSnapshot() async throws {
        let registry = ACPTerminalForegroundOutputRegistry.shared
        let terminalID = "foreground-life-test-\(UUID().uuidString.lowercased())"
        await registry.store(terminalID: terminalID, stdout: "done", exitCode: 0)
        defer { Task { await registry.remove(terminalID: terminalID) } }
        let delegate = makeDelegate(denyBash: false, trustGatesExecution: false)
        let response = try await delegate.waitForTerminalExit(
            ACPWaitForExitRequest(sessionId: "s1", terminalId: terminalID)
        )
        #expect(response.exitStatus.exitCode == 0)
    }

    @Test("foreground terminal registry sweeps by lifecycle prefix")
    func registrySweepByLifecycle() async {
        let registry = ACPTerminalForegroundOutputRegistry.shared
        let terminalA = "foreground-life-1-\(UUID().uuidString.lowercased())"
        let terminalB = "foreground-life-2-\(UUID().uuidString.lowercased())"
        await registry.store(terminalID: terminalA, stdout: "out", exitCode: 0)
        await registry.store(terminalID: terminalB, stdout: "out", exitCode: 0)
        await registry.sweep(lifecycleIDPrefix: "life-1")
        #expect(await registry.snapshot(terminalID: terminalA) == nil)
        #expect(await registry.snapshot(terminalID: terminalB) != nil)
        await registry.remove(terminalID: terminalB)
    }
}
