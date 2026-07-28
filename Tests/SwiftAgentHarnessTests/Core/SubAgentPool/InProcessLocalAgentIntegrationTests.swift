import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import SwiftData
import Testing
@testable import SwiftAgentHarness

/// End-to-end cover for the in-process delegate model-turn path: one prepared launch, one lifecycle
/// row keyed by tool-call id, one run-lane acquisition released on terminal, and no disturbance to
/// the parent's foreground selection.
@Suite("In-process local agent delegate")
struct InProcessLocalAgentIntegrationTests {
    private static let toolName = "delegate_test_agent"
    private static let modelRef = "test/local-delegate"

    private func makeDefinition(
        toolsAllow: [String]? = nil,
        runTimeoutSeconds: TimeInterval = 30
    ) -> LocalAgentDefinition {
        LocalAgentDefinition(
            toolName: Self.toolName,
            displayName: "Test Agent",
            description: "Test in-process delegate.",
            modeProfileID: "subagent-minimal",
            modelRef: Self.modelRef,
            toolsAllow: toolsAllow,
            longRunning: false,
            runTimeoutSeconds: runTimeoutSeconds
        )
    }

    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "local-delegate-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func makeRegistryEntry(for model: Model) -> ModelRegistryEntry {
        ModelRegistryEntry(
            id: model.id,
            displayName: model.modelName,
            capabilities: [.completion, .tools],
            providers: [
                ProviderBinding(
                    providerId: model.modelProtocol.rawValue,
                    modelProtocol: model.modelProtocol,
                    endpointModelId: model.modelName,
                    serverURL: model.serverURL
                ),
            ]
        )
    }

    private func makeToolEntry() -> ToolRegistryEntry {
        let normalizer = ToolSchemaNormalizer()
        // `availableTools()` is async; build the definition directly to keep this helper synchronous.
        // Schema fidelity with the provider is asserted in InProcessLocalAgentToolProviderTests.
        let definition = ToolDefinition(
            name: Self.toolName,
            description: "Test in-process delegate.",
            parameters: [
                .init(name: "instructions", description: "brief", type: "string", required: true),
                .init(name: "description", description: "label", type: "string", required: false),
            ],
            type: .function
        )
        return ToolRegistryEntry(
            descriptor: RegisteredToolDescriptor(
                definition: definition,
                source: .local,
                effectClass: .mutating,
                parallelHint: .parallelizable,
                policyTags: InProcessLocalAgentToolProvider.policyTags(for: makeDefinition()),
                normalizedSchema: normalizer.normalize(rawSchema: definition.inferredSchemaJSON, source: .local)
            )
        )
    }

    /// Builds a session whose local-agent delegate is backed by a scripted child run.
    private func makeSession(
        definition: LocalAgentDefinition,
        childRun: @escaping LocalAgentChildRunPort
    ) async throws -> (session: HarnessRuntimeSession, parent: ModelConversation) {
        let container = try HarnessTestModelContainer.makeInMemory()
        let model = makeModel()
        let entry = makeRegistryEntry(for: model)
        let session = HarnessRuntimeSession(
            container: container,
            rankedRegistryEntriesProvider: { _ in [entry] },
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container),
            localAgents: LocalAgentConfiguration(definitionsByToolName: [definition.toolName: definition])
        )
        try await session.createConversation(with: model, userSystemPrompt: "parent")
        let parent = try #require(await session.currentConversation())
        await session.subAgentSpawnService.installLocalAgentChildRunPort(childRun)
        return (session, parent)
    }

    /// Scripted child run: records the child id and prompt, then appends an assistant reply so the
    /// spawn service's `lastAssistantText` read has something to hand back.
    private actor ChildRunRecorder {
        private(set) var childConversationIDs: [UUID] = []
        private(set) var prompts: [String] = []

        func record(childConversationID: UUID, prompt: String) {
            childConversationIDs.append(childConversationID)
            prompts.append(prompt)
        }
    }

    private func replyingChildRun(
        session: @escaping @Sendable () -> HarnessRuntimeSession?,
        recorder: ChildRunRecorder,
        reply: String
    ) -> LocalAgentChildRunPort {
        { childID, prompt in
            await recorder.record(childConversationID: childID, prompt: prompt)
            guard let session = session(),
                  var child = await session.persistenceDomain.modelConversation(id: childID) else {
                return
            }
            child.messages.append(
                Message(id: UUID(), role: .assistant, content: reply, timestamp: Date(), toolCalls: [])
            )
            await session.persistenceDomain.replaceConversationInRegistry(child, transcript: .authoritativeTip)
        }
    }

    private func call(instructions: String, description: String? = nil, id: String) -> ToolCallRequest {
        var arguments: [String: JSON] = ["instructions": .string(instructions)]
        if let description {
            arguments["description"] = .string(description)
        }
        return ToolCallRequest(id: id, name: Self.toolName, arguments: .object(arguments))
    }

    // MARK: - Happy path

    @Test("A delegate call spawns an isolated child and returns its last assistant text")
    func returnsChildReport() async throws {
        let definition = makeDefinition()
        let recorder = ChildRunRecorder()
        let box = SessionBox()
        let (session, parent) = try await makeSession(
            definition: definition,
            childRun: replyingChildRun(session: { box.value }, recorder: recorder, reply: "Refactored the parser.\n\n")
        )
        box.value = session

        let outcome = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: "Refactor the parser.", description: "Refactor parser", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )

        guard case .completed(let message) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(message.content == "Refactored the parser.")
        #expect(message.toolCallId == "call-1")
        #expect(await recorder.prompts == ["Refactor the parser."])
    }

    @Test("The child runs on the definition's model and mode profile, isolated from the parent")
    func childUsesDefinitionCapabilities() async throws {
        let definition = makeDefinition(toolsAllow: ["read_file"])
        let recorder = ChildRunRecorder()
        let box = SessionBox()
        let (session, parent) = try await makeSession(
            definition: definition,
            childRun: replyingChildRun(session: { box.value }, recorder: recorder, reply: "done")
        )
        box.value = session

        _ = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: "Read the file.", description: "Read file", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )

        let childID = try #require(await recorder.childConversationIDs.first)
        let child = try #require(await session.persistenceDomain.modelConversation(id: childID))
        #expect(child.parentConversationID == parent.id)
        #expect(child.modeProfileID == "subagent-minimal")
        #expect(child.model.modelName == "local-delegate-model")
        // Layer 2 hard block: the child's tool surface comes from the definition, not the parent.
        if case .allowlist(let tools, _)? = child.routingPrefs?.explicitToolPolicy {
            #expect(tools == ["read_file"])
        } else {
            Issue.record("expected an allowlist tool policy on the child, got \(String(describing: child.routingPrefs?.explicitToolPolicy))")
        }
    }

    @Test("The short description becomes the child's topic, not the full brief")
    func descriptionBecomesTopic() async throws {
        let definition = makeDefinition()
        let recorder = ChildRunRecorder()
        let box = SessionBox()
        let (session, parent) = try await makeSession(
            definition: definition,
            childRun: replyingChildRun(session: { box.value }, recorder: recorder, reply: "done")
        )
        box.value = session
        let brief = String(repeating: "a very long task brief. ", count: 40)

        _ = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: brief, description: "Refactor parser", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )

        let childID = try #require(await recorder.childConversationIDs.first)
        let child = try #require(await session.persistenceDomain.modelConversation(id: childID))
        #expect(child.topic == "Refactor parser")
    }

    // MARK: - The invariants the refactor exists to protect

    @Test("One delegate call produces exactly one lifecycle row, keyed by tool-call id")
    func singleLifecycleRowPerCall() async throws {
        let definition = makeDefinition()
        let recorder = ChildRunRecorder()
        let box = SessionBox()
        let (session, parent) = try await makeSession(
            definition: definition,
            childRun: replyingChildRun(session: { box.value }, recorder: recorder, reply: "done")
        )
        box.value = session

        _ = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: "Do the thing.", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )

        let snapshot = await session.subAgentSpawnService.lifecycleSnapshot(parentConversationID: parent.id)
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.lifecycleID == "call-1")
        #expect(snapshot.entries.first?.phase == .done)
        #expect(snapshot.entries.first?.toolCallID == "call-1")
    }

    @Test("The run lane is released once the delegate reaches a terminal phase")
    func releasesRunLaneOnTerminal() async throws {
        let definition = makeDefinition()
        let recorder = ChildRunRecorder()
        let box = SessionBox()
        let (session, parent) = try await makeSession(
            definition: definition,
            childRun: replyingChildRun(session: { box.value }, recorder: recorder, reply: "done")
        )
        box.value = session

        // Two sequential calls: the second can only be admitted if the first released its slot.
        for index in 0 ..< 2 {
            let outcome = await session.subAgentSpawnService.invokeInProcessLocalAgent(
                call: call(instructions: "Do the thing.", id: "call-\(index)"),
                conversationID: parent.id,
                parentConversation: parent,
                toolEntry: makeToolEntry(),
                definition: definition
            )
            guard case .completed = outcome else {
                Issue.record("call \(index) was not admitted: \(outcome)")
                return
            }
        }
        #expect(await session.subAgentSpawnService.listActiveInvocations(parentConversationID: parent.id).isEmpty)
    }

    @Test("A delegate call leaves the parent's foreground selection untouched")
    func doesNotAdoptChildSelection() async throws {
        let definition = makeDefinition()
        let recorder = ChildRunRecorder()
        let box = SessionBox()
        let (session, parent) = try await makeSession(
            definition: definition,
            childRun: replyingChildRun(session: { box.value }, recorder: recorder, reply: "done")
        )
        box.value = session
        let selectedBefore = await session.currentConversationID

        _ = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: "Do the thing.", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )

        #expect(await session.currentConversationID == selectedBefore)
        #expect(await session.currentConversationID == parent.id)
    }

    @Test("longRunning:false takes the synchronous path, never a pending handle")
    func synchronousPathForShortAgents() async throws {
        let definition = makeDefinition()
        let recorder = ChildRunRecorder()
        let box = SessionBox()
        let (session, parent) = try await makeSession(
            definition: definition,
            childRun: replyingChildRun(session: { box.value }, recorder: recorder, reply: "done")
        )
        box.value = session

        let outcome = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: "Do the thing.", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )
        if case .pendingHandle = outcome {
            Issue.record("short-lived in-process delegate must not return a pending handle")
        }
    }

    // MARK: - Routing from the model turn

    @Test("The model-turn entry point routes a configured local agent to the in-process path")
    func modelTurnRoutesToInProcessPath() async throws {
        let definition = makeDefinition()
        let recorder = ChildRunRecorder()
        let box = SessionBox()
        let (session, parent) = try await makeSession(
            definition: definition,
            childRun: replyingChildRun(session: { box.value }, recorder: recorder, reply: "Routed.")
        )
        box.value = session

        let entry = makeToolEntry()
        let outcome = await session.subAgentSpawnService.invokeDelegateToolFromModelTurn(
            call: call(instructions: "Do the thing.", id: "call-1"),
            conversationID: parent.id,
            runID: nil,
            orchestrator: SwiftAgentKitOrchestrator(
                llm: StubTurnLoopLLM(),
                config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
            ),
            snapshot: RuntimeToolTurnPolicySnapshot(
                availabilitySnapshots: [RuntimeToolAvailabilitySnapshot(entry: entry, decision: .allowedDefault)],
                effectiveEntries: [entry],
                dispatchContract: .conservativeDefault
            )
        )

        guard case .completed(let message) = outcome else {
            Issue.record("expected the in-process path to complete, got \(outcome)")
            return
        }
        #expect(message.content == "Routed.")
        #expect(await recorder.childConversationIDs.count == 1)
    }

    @Test("A delegate tool with no matching definition is denied, not silently dropped")
    func modelTurnDeniesUnconfiguredInProcessDelegate() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let session = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        try await session.createConversation(with: makeModel(), userSystemPrompt: "parent")
        let parent = try #require(await session.currentConversation())

        let entry = makeToolEntry()
        let outcome = await session.subAgentSpawnService.invokeDelegateToolFromModelTurn(
            call: call(instructions: "Do the thing.", id: "call-1"),
            conversationID: parent.id,
            runID: nil,
            orchestrator: SwiftAgentKitOrchestrator(
                llm: StubTurnLoopLLM(),
                config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
            ),
            snapshot: RuntimeToolTurnPolicySnapshot(
                availabilitySnapshots: [RuntimeToolAvailabilitySnapshot(entry: entry, decision: .allowedDefault)],
                effectiveEntries: [entry],
                dispatchContract: .conservativeDefault
            )
        )
        guard case .denied(let message) = outcome else {
            Issue.record("expected .denied, got \(outcome)")
            return
        }
        #expect(message.content.contains("no matching localAgents definition"))
    }

    // MARK: - Failure handling

    @Test("An unresolvable model reference is denied before any child is created")
    func deniesUnresolvableModel() async throws {
        let definition = makeDefinition()
        let container = try HarnessTestModelContainer.makeInMemory()
        let session = HarnessRuntimeSession(
            container: container,
            rankedRegistryEntriesProvider: { _ in [] },
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container),
            localAgents: LocalAgentConfiguration(definitionsByToolName: [definition.toolName: definition])
        )
        try await session.createConversation(with: makeModel(), userSystemPrompt: "parent")
        let parent = try #require(await session.currentConversation())

        let outcome = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: "Do the thing.", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )
        guard case .denied(let message) = outcome else {
            Issue.record("expected .denied, got \(outcome)")
            return
        }
        #expect(message.content.contains(Self.modelRef))
        #expect(await session.subAgentSpawnService.lifecycleSnapshot(parentConversationID: parent.id).entries.isEmpty)
    }

    @Test("Empty instructions are denied without spawning a child")
    func deniesEmptyInstructions() async throws {
        let definition = makeDefinition()
        let recorder = ChildRunRecorder()
        let box = SessionBox()
        let (session, parent) = try await makeSession(
            definition: definition,
            childRun: replyingChildRun(session: { box.value }, recorder: recorder, reply: "done")
        )
        box.value = session

        let outcome = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: "   \n ", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )
        guard case .denied = outcome else {
            Issue.record("expected .denied, got \(outcome)")
            return
        }
        #expect(await recorder.childConversationIDs.isEmpty)
    }

    @Test("A child that produces no reply is reported as failed, and the lane is still released")
    func failsWhenChildProducesNoReply() async throws {
        let definition = makeDefinition()
        let recorder = ChildRunRecorder()
        let (session, parent) = try await makeSession(definition: definition) { childID, prompt in
            await recorder.record(childConversationID: childID, prompt: prompt)
        }

        let outcome = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: "Do the thing.", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )
        guard case .completed(let message) = outcome else {
            Issue.record("expected .completed carrying a failure report, got \(outcome)")
            return
        }
        #expect(message.content.contains("failed"))
        let snapshot = await session.subAgentSpawnService.lifecycleSnapshot(parentConversationID: parent.id)
        #expect(snapshot.entries.first?.phase == .failed)
        #expect(await session.subAgentSpawnService.listActiveInvocations(parentConversationID: parent.id).isEmpty)
    }

    @Test("A child run that exceeds its budget times out rather than wedging the parent turn")
    func timesOutSlowChild() async throws {
        let definition = makeDefinition(runTimeoutSeconds: 0.05)
        let (session, parent) = try await makeSession(definition: definition) { _, _ in
            try? await Task.sleep(for: .seconds(10))
        }

        let outcome = await session.subAgentSpawnService.invokeInProcessLocalAgent(
            call: call(instructions: "Do the thing.", id: "call-1"),
            conversationID: parent.id,
            parentConversation: parent,
            toolEntry: makeToolEntry(),
            definition: definition
        )
        guard case .completed(let message) = outcome else {
            Issue.record("expected .completed carrying a timeout report, got \(outcome)")
            return
        }
        #expect(message.content.contains("budget"))
        let snapshot = await session.subAgentSpawnService.lifecycleSnapshot(parentConversationID: parent.id)
        #expect(snapshot.entries.first?.phase == .failed)
        #expect(await session.subAgentSpawnService.listActiveInvocations(parentConversationID: parent.id).isEmpty)
    }
}

/// Lets a scripted child-run closure reach the session that owns it (the closure is needed to build
/// the session, so the reference can only be filled in afterwards).
private final class SessionBox: @unchecked Sendable {
    // Written once immediately after construction, then only read from the child-run closure, which
    // cannot execute until a delegate call is made. No concurrent access window exists.
    var value: HarnessRuntimeSession?
}
