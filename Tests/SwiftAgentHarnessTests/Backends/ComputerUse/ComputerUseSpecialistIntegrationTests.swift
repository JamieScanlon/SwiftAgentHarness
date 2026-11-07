import EasyJSON
import Foundation
import Logging
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

    /// Helper-model calls (`vision-describe`, `grounder`) answer with `reply` and record the model they were built for.
    private final class HelperLLMFactory: ModelLLMFactoring, Sendable {
        private struct HelperLLM: LLMProtocol {
            let reply: String
            var currentState: LLMRuntimeState { .idle(.ready) }
            var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
            func getModelName() -> String { "helper" }
            func getCapabilities() -> [LLMCapability] { [.completion, .vision] }
            func send(_: [Message], config _: LLMRequestConfig) async throws -> LLMResponse {
                LLMResponse(content: reply, toolCalls: [])
            }
            func stream(_: [Message], config _: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: reply, toolCalls: [])))
                    continuation.finish()
                }
            }
            func generateImage(_: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
                throw LLMError.unsupportedCapability(.imageGeneration)
            }
        }

        let reply: String
        private let names = Mutex<[String]>([])

        init(reply: String) {
            self.reply = reply
        }

        var modelNames: [String] { names.withLock { $0 } }

        func makeBaseLLM(
            model: Model,
            providerBindings: [ProviderBinding]?,
            conversationID: UUID?,
            ownerAccountID: UUID?,
            systemPrompt: SystemPrompt,
            logger: Logger?,
            attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?
        ) -> any LLMProtocol {
            names.withLock { $0.append(model.modelName) }
            return HelperLLM(reply: reply)
        }
    }

    private func registryEntry(_ name: String, capabilities: Set<LLMCapability>) -> ModelRegistryEntry {
        ModelRegistryEntry(
            id: UUID(),
            displayName: name,
            capabilities: capabilities,
            providers: [ProviderBinding(
                providerId: "openai",
                modelProtocol: .openAIAPI,
                endpointModelId: name,
                serverURL: URL(string: "https://api.openai.com")!
            )]
        )
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
        contracts: [ContractProfile] = [],
        specialist: ComputerUseSpecialistProfile = ComputerUseSpecialistProfile(),
        idleChild: Bool = false,
        otherModels: [ModelRegistryEntry] = [],
        llmFactory: (any ModelLLMFactoring)? = nil,
        requiresZeroRetention: Bool = false,
        approvals: (any ExecApprovalDelivering)? = nil,
        parentModeProfiles: ModeProfileConfiguration? = nil,
        parentModeProfileID: String? = nil,
        finishes: Bool = true,
        reviewer: ComputerUseGrantReviewer = ComputerUseGrantReviewer()
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
        let entries = [entry] + otherModels
        let session = HarnessRuntimeSession(
            container: container,
            llmFactory: llmFactory ?? StandardModelLLMFactory(accounting: AlwaysAllowBudgetAccounting()),
            registryEntryProvider: { id in entries.first { $0.id == id } },
            rankedRegistryEntriesProvider: { reference in
                switch reference {
                case .id(let id): return entries.filter { $0.id == id }
                case .slug(let slug): return entries.filter { $0.displayName == slug }
                case .query(let query): return entries.filter { query.mustIncludeCapabilities.isSubset(of: $0.capabilities) }
                }
            },
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container),
            modeRegistry: parentModeProfiles.map { ModeRegistryTestSupport.makePort(modeProfileConfiguration: $0) }
        )
        let configuration = ComputerUseConfiguration(
            registry: try DisplayTargetRegistry(targets: [target], reviewer: reviewer),
            defaults: ComputerUseSpecialistDefaults(
                target: target.manifest.id,
                budgets: ComputerUseBudgetPolicy(defaultSteps: 40, ceilingSteps: 200, maxDuration: .seconds(1_800))
            ),
            approveGrants: approve,
            approvals: approvals,
            activityObserver: activityObserver,
            specialist: specialist,
            requiresZeroRetention: requiresZeroRetention
        )
        if let publish {
            session.installComputerUse(configuration, publish: publish)
        } else {
            session.installComputerUse(configuration)
        }
        if let parentModeProfileID {
            try await session.createConversation(
                with: model, userSystemPrompt: "parent", interactionMode: .agent, modeProfileID: parentModeProfileID
            )
        } else {
            try await session.createConversation(with: model, userSystemPrompt: "parent")
        }
        let parent = try #require(await session.currentConversation())

        let box = Box<HarnessRuntimeSession>()
        box.value = session
        await session.subAgentSpawnService.installLocalAgentChildRunPort { childID, prompt in
            await recorder.record(childID: childID, prompt: prompt)
            if idleChild {
                DelegateLiveness.current?.observe(waitingOnApproval: { false })
                try? await Task.sleep(for: .seconds(10))
                return
            }
            guard let session = box.value,
                  let computerSession = await session.runtimeDependencies.computerUse.sessions.session(for: childID) else {
                throw NSError(domain: "ComputerUseSpecialistIntegrationTests", code: 1)
            }
            let tools = ComputerUseToolProvider(session: computerSession)
            var steps = script
            // The specialist ends by committing its reply, unless the script finishes on its own terms.
            if finishes, !script.contains(where: { $0.name == ComputerUseToolProvider.finishToolName }) {
                steps.append((ComputerUseToolProvider.finishToolName, ["result": .string(reply)]))
            }
            for step in steps {
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
        #expect(result["result"] == nil, "the specialist's own text travels in the enveloped report")
        let report = try #require(result["report"] as? String)
        #expect(report.contains("EXTERNAL_UNTRUSTED_CONTENT"))
        #expect(report.contains("Computer-use specialist report"))
        #expect(report.contains("Bolded and saved."))
        let verification = try #require(result["verification"] as? [[String: Any]])
        #expect(verification.map { $0["met"] as? Bool } == [true, true])
        #expect(verification.allSatisfy { $0["evidence"] == nil })
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

    @Test("A parent in a mode that requires confirming Interact gets a card for each click its specialist makes")
    func parentModeConfirmsInteract() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let approvals = RecordingComputerUseApprovals(.approved)
        let strict = ModeProfileConfiguration(
            profiles: [ModeProfileConfiguration.RawProfile(
                id: "careful-agent",
                extends: "agent",
                subAgents: .object(["computerUse": .object(["confirmInteract": .boolean(true)])])
            )],
            diagnostics: []
        )
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder(),
            approvals: approvals, parentModeProfiles: strict, parentModeProfileID: "careful-agent"
        )
        let (_, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "done")
        #expect(await approvals.requests.count == 1, "one card, for the click; observing and verifying need none")
        #expect(await target.actCalls.count == 1)
    }

    /// Delegates nested under `root`, each in the mode named, outermost first. The last one delegates.
    private func nest(_ session: HarnessRuntimeSession, under root: ModelConversation, modes: [String]) async throws -> ModelConversation {
        var parent = root
        for mode in modes {
            try await session.createConversation(with: root.model, userSystemPrompt: "delegate", interactionMode: .agent, modeProfileID: mode)
            var child = try #require(await session.currentConversation())
            child.parentConversationID = parent.id
            child.metadata = .object(["subAgentRootConversationID": .string(root.id.uuidString)])
            await session.persistenceDomain.replaceConversationInRegistry(child, transcript: .authoritativeTip)
            parent = try #require(await session.persistenceDomain.modelConversation(id: child.id))
        }
        return parent
    }

    private static let strictAndDenying = ModeProfileConfiguration(
        profiles: [
            ModeProfileConfiguration.RawProfile(
                id: "careful-agent",
                extends: "agent",
                subAgents: .object(["computerUse": .object(["confirmInteract": .boolean(true)])])
            ),
            ModeProfileConfiguration.RawProfile(
                id: "no-computer-agent",
                extends: "agent",
                tools: .object(["deny": .array([.string(ComputerUseDelegateToolProvider.toolName)])])
            ),
        ],
        diagnostics: []
    )

    @Test("A strict mode anywhere above a nested delegate applies, not just at the root or the delegating conversation")
    func middleAncestorModeApplies() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let approvals = RecordingComputerUseApprovals(.approved)
        let (session, root) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder(),
            approvals: approvals, parentModeProfiles: Self.strictAndDenying
        )
        let delegating = try await nest(session, under: root, modes: ["careful-agent", "agent"])
        let (_, result) = try await invoke(session, parent: delegating)
        #expect(result["status"] as? String == "done")
        #expect(await approvals.requests.count == 1, "the middle delegate's mode confirms the click")
    }

    @Test("A mode above a nested delegate that denies computer use blocks it before any lease")
    func ancestorDenialBlocks() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let (session, root) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: recorder,
            parentModeProfiles: Self.strictAndDenying
        )
        let delegating = try await nest(session, under: root, modes: ["no-computer-agent", "agent"])
        let (_, result) = try await invoke(session, parent: delegating)
        #expect(result["status"] as? String == "blocked")
        #expect((result["reason"] as? String)?.contains("denies computer use") == true, "\(result)")
        #expect(await recorder.childIDs.isEmpty)
        #expect(await target.releases.isEmpty, "nothing was leased")
    }

    @Test("A download the specialist keeps becomes an attachment of the delegating conversation; the rest are deleted")
    func keptDownloadBecomesAttachment() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [DisplayDownload] = []
        for name in ["invoice.pdf", "tracker.bin"] {
            let path = folder.appendingPathComponent(name).path
            try Data("%PDF-1.7 \(name)".utf8).write(to: URL(fileURLWithPath: path))
            files.append(DisplayDownload(name: name, path: path, completed: true, disposable: true))
        }
        await target.setDownloads(files)
        let finish: (String, [String: JSON]) = (
            ComputerUseToolProvider.finishToolName,
            ["result": .string("Saved invoice.pdf and tracker.bin."), "keep_files": .array([.string("invoice.pdf")])]
        )
        let script: Script = Self.fullScript + [finish]
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: script, reply: "Saved invoice.pdf and tracker.bin.", recorder: ChildRecorder()
        )
        let (_, result) = try await invoke(session, parent: parent)
        let downloads = try #require(result["downloads"] as? [[String: Any]])
        #expect(downloads.map { $0["name"] as? String } == ["invoice.pdf", "tracker.bin"])
        #expect(downloads.map { $0["kept"] as? Bool } == [true, false], "naming a file in the report doesn't keep it")
        let attachment = try #require(downloads.first?["attachment"] as? String)
        let catalog = await session.persistenceDomain.modelConversation(id: parent.id)?.attachmentsCatalog ?? []
        #expect(catalog.contains { $0.blobId == attachment && $0.name == "invoice.pdf" && $0.addedBy == .agent })
        #expect(!FileManager.default.fileExists(atPath: files[0].path), "moved into the blob store")
        #expect(!FileManager.default.fileExists(atPath: files[1].path))
    }

    @Test("A parent in an ordinary mode leaves Interact on an unshared target unconfirmed")
    func ordinaryModeLeavesInteract() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let approvals = RecordingComputerUseApprovals(.approved)
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder(),
            approvals: approvals
        )
        _ = try await invoke(session, parent: parent)
        #expect(await approvals.requests.isEmpty)
    }

    @Test("The registry's reviewer gates each action: its override lets an in-grant click on a shared screen through without a card")
    func registryReviewerSkipsInteractCard() async throws {
        let skipping = ComputerUseGrantReviewer(overrides: ComputerUseOperatorOverrides(skipInteractConfirmationWithoutIntentCheck: true))
        for (reviewer, cards) in [(ComputerUseGrantReviewer(), 1), (skipping, 0)] {
            let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest, now: { Date() })
            let approvals = RecordingComputerUseApprovals(.approved)
            let (session, parent) = try await makeSession(
                model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder(),
                approvals: approvals, reviewer: reviewer
            )
            _ = try await invoke(session, parent: parent)
            #expect(await approvals.requests.count == cards)
            #expect(await target.actCalls.count == 1)
        }
    }

    @Test("With the registry's override set, a consequential action on a shared screen still asks once")
    func registryReviewerStillConfirmsConsequential() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest, now: { Date() })
        let approvals = RecordingComputerUseApprovals(.approved)
        let script: Script = [
            Self.observe,
            (ComputerUseToolProvider.clickToolName, ["observation": .string("o_1"), "ref": .string("e8")]),
        ]
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: script, reply: "Deleted.", recorder: ChildRecorder(), approvals: approvals,
            reviewer: ComputerUseGrantReviewer(overrides: ComputerUseOperatorOverrides(skipInteractConfirmationWithoutIntentCheck: true))
        )
        _ = try await invoke(session, parent: parent)
        #expect(await approvals.requests.count == 1)
        #expect(await target.actCalls.count == 1)
    }

    @Test("An app the registry's reviewer unblocks is acted on within its grant, not refused as blocked")
    func registryReviewerUnblocksApp() async throws {
        let manager = AppIdentity(bundleID: "com.1password.1password")
        let call = delegateCall(["apps": .string("\(manager.bundleID):full")])
        let unblocking = ComputerUseGrantReviewer(overrides: ComputerUseOperatorOverrides(allowBlockedBundleIDs: [manager.bundleID]))
        #expect(ComputerUseGrantReviewer().ruling(for: manager).blockedReason != nil, "blocked by default")

        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        await target.setObserved(app: manager)
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: recorder,
            reviewer: unblocking
        )
        _ = try await invoke(session, parent: parent, call: call)
        #expect(await target.actCalls.count == 1)
        #expect(await !recorder.toolResults.contains { $0.content.contains("blocked") })
    }

    @Test("A report that doesn't match the return schema gets one resubmission, then is left out with the reason")
    func schemaResubmission() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: recorder
        )
        let schema = #"{"type":"object","required":["saved"],"properties":{"saved":{"type":"boolean"}}}"#
        let (_, result) = try await invoke(session, parent: parent, call: delegateCall(["return_schema": .string(schema)]))
        let prompts = await recorder.prompts
        #expect(prompts.count == 2)
        #expect(prompts.last?.contains("computer_finish call was rejected") == true, "\(prompts.last ?? "")")
        #expect(result["report"] == nil || !(result["report"] as? String ?? "").contains("\"result\""))
        #expect((result["reason"] as? String)?.contains("didn't match the return schema") == true)
    }

    @Test("A specialist that stops without calling computer_finish leaves no result, and the reason says so")
    func noFinish() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: Self.fullScript, reply: "Bolded and saved.", recorder: ChildRecorder(), finishes: false
        )
        let (_, result) = try await invoke(session, parent: parent)
        #expect(!(result["report"] as? String ?? "").contains("Bolded and saved."), "a final message is not a submission")
        #expect((result["reason"] as? String)?.contains("without calling computer_finish") == true, "\(result)")
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
        #expect(await seen.published.allSatisfy { $0.1.computerUse?.liveView == true }, "the fake VM serves a live view")
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
        #expect(max(thumbnail.width ?? 0, thumbnail.height ?? 0) <= ComputerUseSessionConfiguration.defaultReplayThumbnailEdgePx)
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
        #expect(child.modeProfileID == "subagent-computer-use")
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
        #expect(SubAgentSpawnService.nativeDialect(model: openAI, profile: profile("computer"), imageLimit: limit, layout: layout)
            == ComputerUseNativeDialect(toolset: .openAIComputer))
        #expect(SubAgentSpawnService.nativeDialect(model: claude, profile: profile("computer"), imageLimit: limit, layout: layout) == nil)
        let gemini = Model(
            id: UUID(), protocol: .gemini, modelName: "gemini", serverURL: URL(string: "https://example.com")!,
            capabilities: [.completion, .tools, .vision], modelProtocol: .gemini
        )
        #expect(SubAgentSpawnService.nativeDialect(
            model: gemini, profile: profile("computer_use"), imageLimit: limit, layout: layout, manifest: FakeDisplayTarget.hostManifest
        ) == ComputerUseNativeDialect(toolset: .geminiComputerUse, environment: .desktop))
        #expect(SubAgentSpawnService.nativeDialect(model: openAI, profile: profile("computer_use"), imageLimit: limit, layout: layout) == nil)
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

        #expect(await recorder.toolResults.contains { $0.content.contains("The quarterly report") })
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

    @Test("An audit mark placed while the run is live holds its images for the audit retention at release")
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
        let entry = try #require(await session.runtimeDependencies.computerUse.replays.entry(parent: parent.id, lifecycleID: "call-cu-1"))
        let auditExpiry = ComputerUseRetention().expiry(releasedAt: entry.releasedAt, auditMarked: true)
        #expect(summary.expiresAt.map { abs($0.timeIntervalSince(auditExpiry)) < 1 } == true, "30 days, not indefinite")
        let harness = await session.runtimeDependencies.persistenceDomain.harnessSessionPersistence
        for blobID in entry.blobIDs {
            let expiry = try harness.statBlob(blobId: blobID).expiresAt
            #expect(expiry.map { abs($0.timeIntervalSince(auditExpiry)) < 1 } == true)
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
        let (_, result) = try await invoke(session, parent: parent, call: delegateCall(["steps": .integer(1)]))
        #expect(result["status"] as? String == "budget-exhausted")
        #expect(await target.releases == [.budgetExhausted])
    }

    @Test("A specialist that produces nothing for its idle timeout comes back failed with reason idle-timeout")
    func idleTimeout() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let started = Date()
        let (session, parent) = try await makeSession(
            model: makeModel(), target: target, script: [], reply: "ok", recorder: ChildRecorder(),
            specialist: ComputerUseSpecialistProfile(idleTimeoutSeconds: 0.2), idleChild: true
        )
        let (_, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "failed")
        #expect(result["reason"] as? String == "idle-timeout")
        #expect(await target.releases == [.idleTimeout])
        #expect(Date().timeIntervalSince(started) < 5)
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

    @Test("Under zero retention, a model whose vendor stores the conversation is refused before leasing")
    func zeroRetention() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let model = Model(
            id: UUID(), protocol: .openAIAPI, modelName: "gpt-cu", serverURL: URL(string: "https://api.openai.com/v1")!,
            capabilities: [.completion, .tools, .vision], modelProtocol: .openAIAPI
        )
        let generate = ContractProfile(
            contract: .generate, surface: .anthropicMessages, interaction: [.unary], input: [.text, .image],
            output: [.text, .toolCalls], guarantee: .freeText,
            features: ["tools": FeatureSupport(), ComputerUseModelSupport.featureKey: FeatureSupport(version: "computer")]
        )
        let (session, parent) = try await makeSession(
            model: model, target: target, script: [], reply: "ok", recorder: ChildRecorder(), contracts: [generate], requiresZeroRetention: true
        )
        let (_, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "blocked")
        #expect((result["reason"] as? String)?.contains("vendor-stored") == true, "\(result)")
        #expect(await target.releases.isEmpty)
        #expect(await target.actCalls.isEmpty)
        #expect(SubAgentSpawnService.retainsAtVendor(model: model, profile: generate))
        #expect(!SubAgentSpawnService.retainsAtVendor(model: makeModel(), profile: generate), "an Anthropic model can't use OpenAI's stored API")
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

    @Test("A specialist that can't see images works from the tree and asks a registered vision model about the screen")
    func textOnlySpecialist() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let helpers = HelperLLMFactory(reply: "The title is bold and the document is saved.")
        let (session, parent) = try await makeSession(
            model: makeModel(capabilities: [.completion, .tools]),
            target: target,
            script: [
                Self.observe,
                (ComputerUseToolProvider.describeToolName, ["question": .string("Is the title bold?")]),
                Self.verify("title is bold"),
                Self.verify("2"),
            ],
            reply: "Done.",
            recorder: recorder,
            otherModels: [registryEntry("vision-helper", capabilities: [.completion, .vision])],
            llmFactory: helpers
        )
        let (_, result) = try await invoke(session, parent: parent)
        #expect(result["status"] as? String == "done")
        let results = await recorder.toolResults
        let observed = try #require(results.first)
        #expect(!observed.parts.contains { if case .image = $0 { true } else { false } })
        #expect(observed.content.contains("not shown to you"))
        #expect(results[1].content.contains("The title is bold"))
        #expect(helpers.modelNames == ["vision-helper"])
    }

    @Test("A grounder named in the profile backs computer_locate; one that doesn't resolve blocks the run before leasing")
    func grounderBinding() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let recorder = ChildRecorder()
        let helpers = HelperLLMFactory(reply: "(22, 18)")
        let (session, parent) = try await makeSession(
            model: makeModel(),
            target: target,
            script: [(ComputerUseToolProvider.locateToolName, ["description": .string("the Bold button")])],
            reply: "Found it.",
            recorder: recorder,
            specialist: ComputerUseSpecialistProfile(grounderModelRef: "grounder"),
            otherModels: [registryEntry("grounder", capabilities: [.completion, .vision])],
            llmFactory: helpers
        )
        _ = try await invoke(session, parent: parent)
        let located = try #require(await recorder.toolResults.first)
        #expect(located.success)
        #expect(located.content.contains("x=22, y=18"))
        #expect(located.content.contains("e2 (AXButton)"))
        #expect(helpers.modelNames == ["grounder"])

        let missingTarget = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        let (missing, missingParent) = try await makeSession(
            model: makeModel(),
            target: missingTarget,
            script: [],
            reply: "ok",
            recorder: ChildRecorder(),
            specialist: ComputerUseSpecialistProfile(grounderModelRef: "grounder"),
            otherModels: [registryEntry("grounder", capabilities: [.completion])]
        )
        let (_, blocked) = try await invoke(missing, parent: missingParent)
        #expect(blocked["status"] as? String == "blocked")
        #expect((blocked["reason"] as? String)?.contains("the grounder model 'grounder' cannot see images") == true)
        #expect(await missingTarget.releases.isEmpty)
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
