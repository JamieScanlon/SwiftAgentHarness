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
        approve: @escaping ComputerUseGrantApprover = { $0.review.grantable.map(\.grant) },
        script: Script,
        reply: String,
        recorder: ChildRecorder,
        publish: ComputerUseOversightCoordinator.Publish? = nil,
        activityObserver: (@Sendable (ComputerUseSurfaceIntentPayload) async -> Void)? = nil,
        contracts: [ContractProfile] = []
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
            )],
            contracts: contracts
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
            approveGrants: approve,
            activityObserver: activityObserver
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
                let callID = UUID().uuidString
                let result = try await tools.executeTool(ToolCall(name: step.name, arguments: .object(step.arguments), id: callID))
                await recorder.record(result)
                // Persist the result as a live child loop would, so tool images take the real offload path.
                let message = Message(id: UUID(), role: .tool, content: "", toolCallId: callID).replacingToolResult(result)
                await session.conversationMessagingRuntimeService.appendMessagesToConversation([message], conversationID: childID)
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

    @Test("The host's activity observer sees the whole run, for its HUD")
    func activityObserver() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let seen = RecordingIntentPublisher()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder(),
            activityObserver: { await seen.publish(UUID(), .computerUseActivity($0)) }
        )
        _ = try await invoke(session, parent: parent)
        let statuses = await seen.published.compactMap(\.1.computerUse?.status)
        #expect(statuses.first == .started)
        #expect(statuses.last == .ended)
        #expect(statuses.contains(.acting))
        #expect(await seen.published.allSatisfy { $0.1.computerUse?.lifecycleID == "call-cu-1" })
    }

    @Test("A finished run leaves a replay for the parent conversation, with thumbnails readable through the control plane")
    func replayRecorded() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        await target.setScreenshot(try ComputerUseFixtures.pngScreenshot())
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder()
        )
        let (_, result) = try await invoke(session, parent: parent)
        let control = session.computerUseControl
        let summary = try #require(await control.replays(conversationID: parent.id).first)
        #expect(summary.lifecycleID == "call-cu-1")
        #expect(summary.thumbnailCount > 0)
        #expect(summary.actionCount > 0)

        let replay = try #require(await control.replay(conversationID: parent.id, lifecycleID: "call-cu-1"))
        let first = try #require(replay.thumbnails.first)
        let thumbnail = try #require(await control.replayThumbnail(conversationID: parent.id, lifecycleID: "call-cu-1", observationID: first.observationID))
        #expect(thumbnail.width == first.width)
        #expect(max(thumbnail.width, thumbnail.height) <= ComputerUseSessionConfiguration.defaultReplayThumbnailEdgePx)
        // The ref in the parent's result is the stored replay document.
        let ref = try #require((result["actionsLog"] as? String)?.components(separatedBy: "full log: ").last?.dropLast())
        let blobID = try #require(SessionBlobImageRef.parsePath(String(ref)))
        let harness = await session.runtimeDependencies.persistenceDomain.harnessSessionPersistence
        let stored = try JSONDecoder.computerUseReplay.decode(ComputerUseReplay.self, from: harness.getBlob(blobId: blobID))
        #expect(stored == replay)
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
        #expect(tools == ComputerUseToolProvider.toolNames + ComputerUseNativeToolset.allRegisteredToolNames.sorted())
        #expect(!tools.contains { $0.contains("bash") || $0.contains("file") || $0.contains("shell") })
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

    @Test("Parents are offered tool_search, not the delegate, until a search loads it")
    func delegateDeferred() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let (session, parent) = try await makeSession(model: makeModel(), target: target, script: [], reply: "ok", recorder: ChildRecorder())
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let runtime = await session.orchestratorRuntimeService
        let manager = await runtime.testing_buildToolManager(systemPrompt: prompt, activeConversation: parent)
        let entries = OrchestrationToolCatalog.registryEntries(from: await manager.allRegisteredToolsAsync())
        let configuration = HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)

        let before = await runtime.buildToolTurnPolicySnapshot(allEntries: entries, conversation: parent, configuration: configuration)
        let beforeNames = before.effectiveEntries.map(\.name)
        #expect(beforeNames.contains(DeferredToolLoading.searchToolName))
        #expect(!beforeNames.contains(ComputerUseDelegateToolProvider.toolName))
        #expect(before.availabilitySnapshots.first { $0.entry.name == ComputerUseDelegateToolProvider.toolName }?.decision.blockReason
            == .deferredUntilLoaded)

        let found = try await manager.executeTool(ToolCall(
            name: DeferredToolLoading.searchToolName,
            arguments: .object(["query": .string("click through a desktop app")]),
            id: "search-1"
        ))
        #expect(found.content.contains(ComputerUseDelegateToolProvider.toolName))

        let reloaded = try #require(await session.persistenceDomain.modelConversation(id: parent.id))
        let after = await runtime.buildToolTurnPolicySnapshot(allEntries: entries, conversation: reloaded, configuration: configuration)
        let afterNames = after.effectiveEntries.map(\.name)
        #expect(afterNames.contains(ComputerUseDelegateToolProvider.toolName))
        #expect(!afterNames.contains(DeferredToolLoading.searchToolName), "nothing left to search for")
    }

    @Test("A Claude specialist on Anthropic's API drives the screen with the native toolset")
    func nativeToolset() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let generate = ContractProfile(
            contract: .generate,
            surface: .anthropicMessages,
            interaction: [.unary],
            input: [.text, .image],
            output: [.text, .toolCalls],
            guarantee: .freeText,
            features: [
                "tools": FeatureSupport(),
                ComputerUseModelSupport.featureKey: FeatureSupport(version: "computer_toolset_20260801", params: ["coordinates": .string("pixels")]),
            ],
            limits: ContractLimits(maxImageEdgePx: 2576)
        )
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: [], reply: "ok", recorder: ChildRecorder(), contracts: [generate]
        )
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let seen = Box<([String], JSON?, ComputerUseNativeDialect?)>()
        await session.subAgentSpawnService.installLocalAgentChildRunPort { childID, _ in
            guard let child = await session.persistenceDomain.modelConversation(id: childID),
                  let computer = await session.runtimeDependencies.computerUse.sessions.session(for: childID) else { return }
            let runtime = await session.orchestratorRuntimeService
            seen.value = (
                await runtime.testing_buildToolManagerToolNames(systemPrompt: prompt, activeConversation: child),
                await runtime.orchestratorAdditionalParameters(for: child),
                computer.configuration.nativeDialect
            )
            var updated = child
            updated.messages.append(Message(id: UUID(), role: .assistant, content: "ok"))
            await session.persistenceDomain.replaceConversationInRegistry(updated, transcript: .authoritativeTip)
        }
        _ = try await invoke(session, parent: parent)
        let (tools, parameters, dialect) = try #require(seen.value)
        #expect(dialect == ComputerUseNativeDialect(toolset: .toolset20260801))
        #expect(tools.contains("left_click") && tools.contains("screenshot"))
        #expect(tools.contains(ComputerUseToolProvider.verifyToolName))
        #expect(!tools.contains(ComputerUseToolProvider.clickToolName), "native members replace the harness's pointer tools")
        #expect(ComputerUseNativeDialect(additionalParameters: parameters) == dialect)
        let allowed = ComputerUseDelegateToolProvider.specialistDefinition(ComputerUseSpecialistProfile()).toolsAllow
        #expect(allowed?.contains("left_click") == true)
    }

    @Test("Dialect selection: Anthropic's API and a known version; older versions declare the screenshot size")
    func dialectSelection() {
        let profile = { (version: String) in
            ContractProfile(
                contract: .generate, surface: .anthropicMessages, interaction: [.unary], input: [.text, .image],
                output: [.text, .toolCalls], guarantee: .freeText,
                features: [ComputerUseModelSupport.featureKey: FeatureSupport(version: version)]
            )
        }
        let layout = TargetLayout(displays: [DisplayInfo(id: "main", frame: DisplayRect(x: 0, y: 0, width: 1440, height: 900), scaleFactor: 2, isPrimary: true)])
        let limit = ObservationImageLimit(longEdgePx: 1200, maxPixels: 1_150_000)
        let claude = makeModel()
        #expect(SubAgentSpawnService.nativeDialect(model: claude, profile: profile("computer_toolset_20260801"), imageLimit: limit, layout: layout)
            == ComputerUseNativeDialect(toolset: .toolset20260801))
        #expect(SubAgentSpawnService.nativeDialect(model: claude, profile: profile("computer_20251124"), imageLimit: limit, layout: layout)
            == ComputerUseNativeDialect(toolset: .computer20251124, displayWidthPx: 1200, displayHeightPx: 750))
        #expect(SubAgentSpawnService.nativeDialect(model: claude, profile: profile("toolset-2026-08"), imageLimit: limit, layout: layout) == nil)
        let openAI = Model(
            id: UUID(), protocol: .openAIAPI, modelName: "gpt", serverURL: URL(string: "https://example.com")!,
            capabilities: [.completion, .tools, .vision], modelProtocol: .openAIAPI
        )
        #expect(SubAgentSpawnService.nativeDialect(model: openAI, profile: profile("computer_toolset_20260801"), imageLimit: limit, layout: layout) == nil)
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

    @Test("At release a run's screenshots, thumbnails, and replay move from held to the release TTL")
    func retentionAtRelease() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        await target.setScreenshot(try ComputerUseFixtures.pngScreenshot())
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder()
        )
        let started = Date()
        _ = try await invoke(session, parent: parent)
        let entry = try #require(await session.runtimeDependencies.computerUse.replays.entry(parent: parent.id, lifecycleID: "call-cu-1"))
        // Screenshots from the child's tool results are held too, not only the replay's own blobs.
        #expect(entry.blobIDs.count > entry.replay.thumbnails.count + 1)
        let harness = await session.runtimeDependencies.persistenceDomain.harnessSessionPersistence
        let ttl = ComputerUseRetention().afterRelease.timeInterval
        for blobID in entry.blobIDs {
            let ref = try harness.statBlob(blobId: blobID)
            #expect(ref.durability == .ephemeral, "\(ref.originalName ?? "?") \(ref.mimeType) \(ref.size)")
            let expiresAt = try #require(ref.expiresAt)
            #expect(expiresAt >= started.addingTimeInterval(ttl) && expiresAt <= Date().addingTimeInterval(ttl))
        }
        #expect(entry.expiresAt == entry.releasedAt.addingTimeInterval(ttl))
    }

    @Test("After a restart, replays are rediscovered from the parent's delegate results and can still be audit-marked")
    func replaysSurviveRestart() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        await target.setScreenshot(try ComputerUseFixtures.pngScreenshot())
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder()
        )
        let (outcome, _) = try await invoke(session, parent: parent)
        // The delegate result lands in the parent's transcript, as the agent loop would append it.
        guard case .completed(let message) = outcome else { Issue.record("expected a result"); return }
        await session.conversationMessagingRuntimeService.appendMessagesToConversation([message], conversationID: parent.id)
        let original = try #require(await session.runtimeDependencies.computerUse.replays.entry(parent: parent.id, lifecycleID: "call-cu-1"))

        // A fresh index, as after a restart, rebuilt from durable state only.
        let installation = await session.runtimeDependencies.computerUse
        let restarted = ComputerUseReplayIndex()
        restarted.setDiscovery(ComputerUseReplayDiscovery.discovery(
            persistence: await session.runtimeDependencies.persistenceDomain,
            installation: installation
        ))
        let entry = try #require(await restarted.entry(parent: parent.id, lifecycleID: "call-cu-1"))
        #expect(entry.replay == original.replay)
        #expect(Set(entry.blobIDs) == Set(original.blobIDs))
        #expect(!entry.auditMarked)
        let expiresAt = try #require(entry.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince(try #require(original.expiresAt))) < 1)
        let thumbnail = try #require(entry.replay.thumbnails.first)
        #expect(try entry.access.load(thumbnail.blobID).isEmpty == false)
    }

    @Test("An audit mark placed while the run is live holds its images at release")
    func auditMarkedWhileLive() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        await target.setScreenshot(try ComputerUseFixtures.pngScreenshot())
        let sessionBox = Box<HarnessRuntimeSession>()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder(),
            publish: { conversationID, intent in
                // Play the user: mark the run for audit as soon as it starts.
                guard intent.kind == .computerUseActivity, intent.computerUse?.status == .started,
                      let lifecycleID = intent.computerUse?.lifecycleID, let session = await sessionBox.value else { return }
                _ = await session.computerUseControl.setAuditMark(true, conversationID: conversationID, lifecycleID: lifecycleID)
            }
        )
        sessionBox.value = session
        _ = try await invoke(session, parent: parent)
        let summary = try #require(await session.computerUseControl.replays(conversationID: parent.id).first)
        #expect(summary.auditMarked)
        #expect(summary.expiresAt == nil)
        let entry = try #require(await session.runtimeDependencies.computerUse.replays.entry(parent: parent.id, lifecycleID: "call-cu-1"))
        let harness = await session.runtimeDependencies.persistenceDomain.harnessSessionPersistence
        for blobID in entry.blobIDs {
            #expect(try harness.statBlob(blobId: blobID).expiresAt == nil)
        }
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

    @Test("The grant dialog is told the parent conversation and the task's goal")
    func grantDialogContext() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let seen = Box<ComputerUseGrantRequest>()
        let (session, parent) = try await makeSession(
            model: makeModel(),
            target: target,
            approve: { request in
                seen.value = request
                return nil
            },
            script: [],
            reply: "ok",
            recorder: ChildRecorder()
        )
        _ = try await invoke(session, parent: parent)
        let request = try #require(seen.value)
        #expect(request.conversationID == parent.id)
        #expect(request.purpose == "Make the title bold in TextEdit.")
        #expect(request.target.id == FakeDisplayTarget.vmManifest.id)
        #expect(request.review.grantable.map(\.grant) == [.app(bundleID: "com.apple.TextEdit", tier: .full)])
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
