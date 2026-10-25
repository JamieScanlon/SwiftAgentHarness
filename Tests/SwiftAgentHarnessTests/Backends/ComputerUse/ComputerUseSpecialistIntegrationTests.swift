import EasyJSON
import Foundation
import SwiftAgentKit
import Synchronization
import Testing
@testable import SwiftAgentHarness

/// End to end: a parent delegates a task, the specialist child drives a fake display target through the
/// computer-use tools, and the parent receives only the structured result.
@Suite("Computer use specialist sub-agent")
struct ComputerUseSpecialistIntegrationTests {
    private final class Box<Value: Sendable>: Sendable {
        private let state: Mutex<Value?>
        init() { state = Mutex(nil) }
        var value: Value? {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    private actor ChildRecorder {
        private(set) var childIDs: [UUID] = []
        private(set) var prompts: [String] = []
        private(set) var toolResults: [ToolResult] = []

        func record(childID: UUID, prompt: String) {
            childIDs.append(childID)
            prompts.append(prompt)
        }

        func record(_ result: ToolResult) {
            toolResults.append(result)
        }
    }

    /// What the scripted specialist does: a sequence of computer tool calls, then a final reply.
    private typealias Script = [(name: String, arguments: [String: JSON])]

    private static let observe: (String, [String: JSON]) = (ComputerUseToolProvider.observeToolName, [:])
    private static func verify(_ criterion: String) -> (String, [String: JSON]) {
        (ComputerUseToolProvider.verifyToolName, [
            "criterion": .string(criterion), "met": .boolean(true),
            "evidence": .string("seen on screen"), "observation": .string("o_2"),
        ])
    }
    private static let fullScript: Script = [
        observe,
        (ComputerUseToolProvider.clickToolName, ["observation": .string("o_1"), "ref": .string("e2")]),
        observe,
        verify("title is bold"),
        verify("2"),
    ]

    private func makeModel(capabilities: [LLMCapability] = [.completion, .tools, .vision]) -> Model {
        Model(
            id: UUID(),
            protocol: .anthropic,
            modelName: "cu-model",
            serverURL: URL(string: "https://api.anthropic.com")!,
            capabilities: capabilities,
            modelProtocol: .anthropic
        )
    }

    private func makeSession(
        model: Model,
        target: FakeDisplayTarget,
        approve: @escaping ComputerUseGrantApprover = { $0.grantable.map(\.grant) },
        script: Script,
        reply: String,
        recorder: ChildRecorder,
        publish: ComputerUseOversightCoordinator.Publish? = nil
    ) async throws -> (HarnessRuntimeSession, ModelConversation) {
        let container = try HarnessTestModelContainer.makeInMemory()
        let entry = ModelRegistryEntry(
            id: model.id,
            displayName: model.modelName,
            capabilities: Set(model.capabilities),
            providers: [ProviderBinding(
                providerId: "anthropic",
                modelProtocol: model.modelProtocol,
                endpointModelId: model.modelName,
                serverURL: model.serverURL
            )]
        )
        let session = HarnessRuntimeSession(
            container: container,
            registryEntryProvider: { id in id == entry.id ? entry : nil },
            rankedRegistryEntriesProvider: { _ in [entry] },
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let configuration = ComputerUseConfiguration(
            registry: DisplayTargetRegistry(targets: [target]),
            defaults: ComputerUseSpecialistDefaults(
                target: target.manifest.id,
                budgets: ComputerUseBudgets(maxSteps: 40, maxDuration: .seconds(600)),
                maxBudgets: ComputerUseBudgets(maxSteps: 200, maxDuration: .seconds(1_800))
            ),
            approveGrants: approve
        )
        if let publish {
            session.installComputerUse(configuration, publish: publish)
        } else {
            session.installComputerUse(configuration)
        }
        try await session.createConversation(with: model, userSystemPrompt: "parent")
        let parent = try #require(await session.currentConversation())

        let box = Box<HarnessRuntimeSession>()
        box.value = session
        await session.subAgentSpawnService.installLocalAgentChildRunPort { childID, prompt in
            await recorder.record(childID: childID, prompt: prompt)
            guard let session = box.value,
                  let computerSession = await session.runtimeDependencies.computerUse.sessions.session(for: childID) else {
                throw NSError(domain: "ComputerUseSpecialistIntegrationTests", code: 1)
            }
            let tools = ComputerUseToolProvider(session: computerSession)
            for step in script {
                await recorder.record(try await tools.executeTool(ToolCall(name: step.name, arguments: .object(step.arguments), id: UUID().uuidString)))
            }
            guard var child = await session.persistenceDomain.modelConversation(id: childID) else {
                throw NSError(domain: "ComputerUseSpecialistIntegrationTests", code: 2)
            }
            child.messages.append(Message(id: UUID(), role: .assistant, content: reply))
            await session.persistenceDomain.replaceConversationInRegistry(child, transcript: .authoritativeTip)
        }
        return (session, parent)
    }

    private func toolEntry() -> ToolRegistryEntry {
        let definition = ToolDefinition(name: ComputerUseDelegateToolProvider.toolName, description: "", parameters: [], type: .function)
        return ToolRegistryEntry(
            descriptor: RegisteredToolDescriptor(
                definition: definition,
                source: .local,
                effectClass: .mutating,
                parallelHint: .serialOnly,
                policyTags: ComputerUseDelegateToolProvider.policyTags,
                normalizedSchema: ToolSchemaNormalizer().normalize(rawSchema: definition.inferredSchemaJSON, source: .local)
            )
        )
    }

    private func delegateCall(_ extra: [String: JSON] = [:]) -> ToolCallRequest {
        var arguments: [String: JSON] = [
            "goal": .string("Make the title bold in TextEdit."),
            "success_criteria": .string("title is bold\nthe document is saved"),
            "constraints": .string("Do not close other documents"),
            "apps": .string("com.apple.TextEdit:full"),
            "description": .string("Bold the title"),
        ]
        arguments.merge(extra) { _, new in new }
        return ToolCallRequest(id: "call-cu-1", name: ComputerUseDelegateToolProvider.toolName, arguments: .object(arguments))
    }

    private func invoke(
        _ session: HarnessRuntimeSession,
        parent: ModelConversation,
        call: ToolCallRequest? = nil,
        origin: ComputerUseRunOrigin = .interactiveOwner
    ) async throws -> (outcome: ToolDispatchOutcome, result: [String: Any]) {
        let outcome = await session.subAgentSpawnService.invokeComputerUseSpecialist(
            call: call ?? delegateCall(),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: toolEntry(),
            origin: origin
        )
        guard case .completed(let message) = outcome else {
            Issue.record("expected a completed result, got \(outcome)")
            return (outcome, [:])
        }
        let json = try #require(try JSONSerialization.jsonObject(with: Data(message.content.utf8)) as? [String: Any])
        return (outcome, json)
    }

    @Test("A verified run returns done with per-criterion evidence; the parent sees JSON only and the lease is released")
    func happyPath() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: recorder
        )
        let (outcome, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "done")
        #expect(result["result"] as? String == "Bolded and saved.")
        let verification = try #require(result["verification"] as? [[String: Any]])
        #expect(verification.map { $0["met"] as? Bool } == [true, true])
        #expect((result["actionsLog"] as? String)?.contains("blob://") == true)
        if case .completed(let message) = outcome {
            #expect(message.images.isEmpty)
            #expect(!message.content.contains("[e2]"))
            #expect(message.toolCallId == "call-cu-1")
        }

        #expect(await target.actCalls.count == 1)
        #expect(await target.releases == [.completed])
        let childID = try #require(await recorder.childIDs.first)
        #expect(await session.runtimeDependencies.computerUse.sessions.session(for: childID) == nil)
        #expect(await recorder.prompts.first?.contains("Make the title bold in TextEdit.") == true)
        #expect(await recorder.prompts.first?.contains("1. title is bold") == true)
    }

    @Test("The child runs on a narrow tool surface: the computer-use family only, no shell or files")
    func childToolSurface() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "ok", recorder: recorder
        )
        _ = try await invoke(session, parent: parent)
        let childID = try #require(await recorder.childIDs.first)
        let child = try #require(await session.persistenceDomain.modelConversation(id: childID))
        #expect(child.parentConversationID == parent.id)
        #expect(child.modeProfileID == "subagent-minimal")
        guard case .allowlist(let tools, _)? = child.routingPrefs?.explicitToolPolicy else {
            Issue.record("expected an allowlist on the child")
            return
        }
        #expect(tools == ComputerUseToolProvider.toolNames)
    }

    @Test("Every specialist step restates the task's constraints")
    func constraintsEveryStep() async throws {
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() }),
            script: Self.fullScript, reply: "ok", recorder: recorder
        )
        _ = try await invoke(session, parent: parent)
        let screenResults = await recorder.toolResults.prefix(3)
        #expect(screenResults.allSatisfy { $0.content.contains("Do not close other documents") })
    }

    @Test("Parents see the delegate tool; a specialist child sees the computer tools instead")
    func toolBuilding() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let toolNames = Box<[String]>()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: [], reply: "ok", recorder: recorder
        )
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let parentTools = await session.orchestratorRuntimeService.testing_buildToolManagerToolNames(systemPrompt: prompt, activeConversation: parent)
        #expect(parentTools.contains(ComputerUseDelegateToolProvider.toolName))
        #expect(!parentTools.contains(ComputerUseToolProvider.observeToolName))

        await session.subAgentSpawnService.installLocalAgentChildRunPort { childID, _ in
            guard let child = await session.persistenceDomain.modelConversation(id: childID) else { return }
            toolNames.value = await session.orchestratorRuntimeService.testing_buildToolManagerToolNames(
                systemPrompt: prompt, activeConversation: child
            )
            var updated = child
            updated.messages.append(Message(id: UUID(), role: .assistant, content: "ok"))
            await session.persistenceDomain.replaceConversationInRegistry(updated, transcript: .authoritativeTip)
        }
        _ = try await invoke(session, parent: parent)
        let childTools = try #require(toolNames.value)
        #expect(childTools.contains(ComputerUseToolProvider.observeToolName))
        #expect(!childTools.contains(ComputerUseDelegateToolProvider.toolName))
    }

    @Test("The host's kill switch stops a running specialist and blocks it")
    func killSwitch() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: [], reply: "ok", recorder: recorder
        )
        await session.subAgentSpawnService.installLocalAgentChildRunPort { childID, _ in
            await session.stopComputerUse()
            guard var child = await session.persistenceDomain.modelConversation(id: childID) else { return }
            child.messages.append(Message(id: UUID(), role: .assistant, content: "stopped"))
            await session.persistenceDomain.replaceConversationInRegistry(child, transcript: .authoritativeTip)
        }
        let (_, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "blocked")
        #expect(result["reason"] as? String == "stopped by the user")
        #expect(await target.releases == [.killSwitch])
    }

    @Test("Questions and activity go to the parent conversation, and the answer reaches the specialist")
    func oversightRoutedToParent() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let published = RecordingIntentPublisher()
        let sessionBox = Box<HarnessRuntimeSession>()
        let parentBox = Box<UUID>()
        let script: Script = [Self.observe, (ComputerUseToolProvider.askUserToolName, ["question": .string("Which document?")])]
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: script, reply: "ok", recorder: recorder,
            publish: { conversationID, intent in
                await published.publish(conversationID, intent)
                // Play the user: answer the question as soon as it appears.
                guard intent.kind == .computerUseRequest, let id = intent.computerUse?.requestID,
                      let coordinator = await sessionBox.value?.runtimeDependencies.computerUse.coordinator else { return }
                _ = await coordinator.resolve(id: id, conversationID: conversationID, resolution: .answered("The quarterly report"))
            }
        )
        sessionBox.value = session
        parentBox.value = parent.id
        let (_, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "done-unverified")

        let answer = await recorder.toolResults.last
        #expect(answer?.content.contains("The quarterly report") == true)
        let events = await published.published
        #expect(events.allSatisfy { $0.0 == parent.id })
        let kinds = events.map(\.1.kind)
        #expect(kinds.first == .computerUseActivity)
        #expect(kinds.contains(.computerUseRequest))
        #expect(kinds.contains(.computerUseRequestCleared))
        let statuses = events.compactMap { $0.1.kind == .computerUseActivity ? $0.1.computerUse?.status : nil }
        #expect(statuses.first == .started)
        #expect(statuses.contains(.acting))
        #expect(statuses.last == .ended)
        #expect(events.last { $0.1.kind == .computerUseActivity }?.1.computerUse?.lifecycleID == "call-cu-1")
    }

    @Test("Without verification the run is done-unverified")
    func unverified() async throws {
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() }),
            script: [Self.observe], reply: "I think it worked.", recorder: recorder
        )
        let (_, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "done-unverified")
    }

    @Test("Running out of steps ends the run as budget-exhausted")
    func stepBudget() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "ok", recorder: recorder
        )
        let (_, result) = try await invoke(session, parent: parent, call: delegateCall(["max_steps": .integer(1)]))
        #expect(result["status"] as? String == "budget-exhausted")
        #expect(await target.releases == [.budgetExhausted])
    }

    @Test("Declined grants block the task before any child is spawned")
    func grantsDeclined() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, approve: { _ in nil }, script: [], reply: "ok", recorder: recorder
        )
        let (_, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "blocked")
        #expect(await recorder.childIDs.isEmpty)
        #expect(await target.releases.isEmpty)
    }

    @Test("A trigger-started run cannot drive the host desktop; it needs the user")
    func headlessHostNeedsUser() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest, now: { Date() })
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: [], reply: "ok", recorder: recorder
        )
        let (_, result) = try await invoke(
            session,
            parent: parent,
            origin: ComputerUseRunOrigin(laneOrigin: .trigger(.cron), senderIsOwner: true)
        )
        #expect(result["status"] as? String == "needs-user")
        #expect(await recorder.childIDs.isEmpty)
    }

    @Test("A model that cannot see images is refused before leasing")
    func modelWithoutVision() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(capabilities: [.completion, .tools]), target: target, script: [], reply: "ok", recorder: recorder
        )
        let (_, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "blocked")
        #expect((result["reason"] as? String)?.contains("see images") == true)
        #expect(await target.releases.isEmpty)
    }

    @Test("Malformed delegate arguments are denied with the reason")
    func malformedArguments() async throws {
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() }),
            script: [], reply: "ok", recorder: recorder
        )
        let outcome = await session.subAgentSpawnService.invokeComputerUseSpecialist(
            call: ToolCallRequest(id: "c", name: ComputerUseDelegateToolProvider.toolName, arguments: .object(["goal": .string("x")])),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: toolEntry(),
            origin: .interactiveOwner
        )
        guard case .denied(let message) = outcome else {
            Issue.record("expected denied")
            return
        }
        #expect(message.content.contains("success_criteria"))
    }
}
