import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

private func assertSendable<T: Sendable>(_: T.Type) {}

@Suite("Mode registry harness builtins")
struct ModeRegistryTests {
    @Test("ModeProfileConfiguration is compiler-verified Sendable")
    func modeProfileConfigurationIsCompilerVerifiedSendable() {
        assertSendable(ModeProfileConfiguration.self)
        assertSendable(ModeProfileConfiguration.RawProfile.self)
    }

    @Test("Built-in profiles resolve with expected compaction and orchestrator flags")
    func builtinsResolve() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let chat = try await registry.resolve(modeId: "chat")
        #expect(chat.assemblyKind == .chat)
        #expect(chat.allowsProactiveCompactionTriggers == false)

        let plan = try await registry.resolve(modeId: "plan")
        #expect(plan.allowsProactiveCompactionTriggers)

        let agent = try await registry.resolve(modeId: "agent")
        #expect(agent.appliesAgentBuildOrchestratorHarness)
        #expect(await registry.registeredModeIDs().sorted() == [
            "agent",
            "chat",
            "memory-active-recall",
            "memory-extraction",
            "memory-pre-compaction-flush",
            "plan",
            "subagent-explore",
            "subagent-general",
            "subagent-minimal",
            "subagent-plan",
            "trigger-delegate",
            "trigger-host",
        ])
    }

    @Test("Memory extraction profile uses chat assembly without build harness")
    func memoryExtractionUsesChatAssembly() async throws {
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: .empty
        )
        let extraction = try await registry.resolve(modeId: "memory-extraction")
        #expect(extraction.interactionMode == .chat)
        #expect(extraction.assemblyKind == .chat)
        #expect(extraction.appliesAgentBuildOrchestratorHarness == false)
        #expect(extraction.context.includeSkills == false)
        #expect(extraction.context.includeToolGuidance == false)

        let conversation = ModelConversation(
            id: UUID(),
            model: Model(
                protocol: .openAIAPI,
                modelName: "memory-extraction-test",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            systemPrompt: "extract memories",
            interactionMode: extraction.interactionMode,
            modeProfileID: "memory-extraction",
            lineageKind: .subAgent
        )
        let switches = ContextSystemPromptModeSwitches.build(
            conversation: conversation,
            strictAgentHarnessPrompts: true,
            resolvedProfile: extraction
        )
        #expect(switches.assemblyContext.includeAgentSkills == false)
        #expect(switches.assemblyContext.includeToolGuidance == false)
        #expect(switches.assemblyContext.workflowBlock.isEmpty)
    }

    @Test("All machine sub-agent mode profiles resolve from built-ins without external config")
    func machineSubAgentProfilesResolve() async throws {
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: .empty
        )
        #expect(await registry.missingMachineSubAgentProfileIDs().isEmpty)
        for profileID in ConversationLineageInference.machineSubAgentModeProfileIDs {
            _ = try await registry.resolve(modeId: profileID)
        }
    }

    @Test("Memory write scoped profile predicate covers extraction and flush lanes")
    func memoryWriteScopedProfilePredicate() {
        #expect(ConversationLineageInference.isMemoryWriteScopedProfile("memory-extraction"))
        #expect(ConversationLineageInference.isMemoryWriteScopedProfile("memory-pre-compaction-flush"))
        #expect(!ConversationLineageInference.isMemoryWriteScopedProfile("memory-active-recall"))
        #expect(!ConversationLineageInference.isMemoryWriteScopedProfile("agent"))
    }

    @Test("Machine spawn mode profiles forbid sub-agent delegation")
    func machineProfilesRestrictSubAgents() async throws {
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: .empty
        )
        for profileID in ConversationLineageInference.machineSubAgentModeProfileIDs {
            let profile = try await registry.resolve(modeId: profileID)
            #expect(profile.subAgents.allow == [], "expected \(profileID) to deny sub-agent spawn")
        }
        let minimal = try await registry.resolve(modeId: "subagent-minimal")
        #expect(minimal.tools.allow == [])
        let extraction = try await registry.resolve(modeId: "memory-extraction")
        #expect(extraction.tools.allow?.sorted() == ["edit_file", "read_attachment", "read_file", "write_file"].sorted())
        #expect(!(extraction.tools.allow ?? []).contains("spawn_sub_agent"))
    }

    @Test("Re-registering the same id throws")
    func duplicateRegistrationThrows() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let chat = try await registry.resolve(modeId: "chat")
        await #expect(throws: ModeRegistryError.self) {
            try await registry.register(chat)
        }
    }

    @Test("Re-registering with replacing flag overwrites profile")
    func duplicateRegistrationReplacingOverwrites() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        var chat = try await registry.resolve(modeId: "chat")
        chat.label = "Chat Base"
        try await registry.register(chat, replacing: true)

        chat.label = "Chat Replaced"
        try await registry.register(chat, replacing: true)

        let resolved = try await registry.resolve(modeId: "chat")
        #expect(resolved.label == "Chat Replaced")
    }

    @Test("Unknown mode id throws")
    func unknownModeThrows() async {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        await #expect(throws: ModeRegistryError.self) {
            try await registry.resolve(modeId: "custom_unknown")
        }
    }

    @Test("Unknown mode id reports fallback without mutating id")
    func unknownModeReportsFallback() async {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let result = await registry.resolveReportingFallback(modeId: "custom_unknown", logger: nil)
        #expect(result.didFallback)
        #expect(result.profile.id == InteractionMode.chat.rawValue)
    }

    @Test("mutation hook fires when catalog mutates")
    func mutationHookFiresOnMutation() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let counter = Counter()
        await registry.setOnDidMutate { counter.value += 1 }
        try await registry.register(
            ResolvedModeProfile(
                id: "observer-mode",
                interactionMode: .plan,
                assemblyKind: .planCollaboration,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: false,
                builtInSeedVersion: 0,
                semanticLayerTags: []
            )
        )
        #expect(counter.value == 1)
    }

    @Test("Config profiles deterministically override built-ins")
    func configProfilesOverrideBuiltins() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: InteractionMode.chat.rawValue,
                    interactionMode: .chat,
                    assemblyKind: .chat,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: false,
                    semanticLayerTags: []
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let chat = try await registry.resolve(modeId: InteractionMode.chat.rawValue)
        #expect(chat.allowsProactiveCompactionTriggers == true)
    }

    @Test("Config profiles can override transition hook ids")
    func configProfilesOverrideTransitionHooks() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "custom-chat-hooks",
                    extends: InteractionMode.chat.rawValue,
                    hooks: .object([
                        "onExit": .array([.string("custom_exit")]),
                        "onEnter": .array([.string("custom_enter_a"), .string("custom_enter_b")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "custom-chat-hooks")
        #expect(profile.hooks.onExit == ["custom_exit"])
        #expect(profile.hooks.onEnter == ["custom_enter_a", "custom_enter_b"])
    }

    @Test("Invalid mode profile config rows are rejected with diagnostics")
    func invalidConfigRowsAreRejected() async throws {
        let config = ModeProfileConfiguration(
            profiles: [],
            diagnostics: ["modeProfiles[x] invalid interactionMode"]
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let diagnostics = await registry.configurationDiagnostics()
        #expect(diagnostics.contains("modeProfiles[x] invalid interactionMode"))
        #expect(await registry.registeredModeIDs().sorted() == [
            "agent",
            "chat",
            "memory-active-recall",
            "memory-extraction",
            "memory-pre-compaction-flush",
            "plan",
            "subagent-explore",
            "subagent-general",
            "subagent-minimal",
            "subagent-plan",
            "trigger-delegate",
        ])
    }

    @Test("Mode profile configuration loads from project directory JSON files")
    func modeProfileConfigurationLoadsFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-profile-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("custom-mode.json")
        let raw = """
        {
          "id": "custom-mode",
          "interactionMode": "plan",
          "assemblyKind": "planCollaboration",
          "label": "Custom Mode",
          "tools": { "allow": ["create_plan"] }
        }
        """
        try raw.write(to: file, atomically: true, encoding: .utf8)

        let loaded = ModeProfileConfiguration.loadFromDirectory(dir)
        #expect(loaded.diagnostics.isEmpty)
        #expect(loaded.profiles.count == 1)
        #expect(loaded.profiles.first?.id == "custom-mode")
        #expect(loaded.profiles.first?.label == "Custom Mode")
    }

    @Test("Mode profile configuration retains runtime termination object from JSON")
    func modeProfileConfigurationParsesRuntimeTerminationFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-profile-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("runtime-mode.json")
        let raw = """
        {
          "id": "runtime-mode",
          "interactionMode": "agent",
          "assemblyKind": "agentBuild",
          "runtime": {
            "termination": {
              "policy": "terminal-tool",
              "recovery": {
                "strategy": "forced-tool-choice",
                "maxAttempts": 3
              }
            }
          }
        }
        """
        try raw.write(to: file, atomically: true, encoding: .utf8)

        let loaded = ModeProfileConfiguration.loadFromDirectory(dir)
        let runtime = try #require(loaded.profiles.first?.runtime?.objectFields)
        let termination = try #require(runtime["termination"]?.objectFields)
        #expect(termination.optionalString(for: "policy") == "terminal-tool")
        #expect(termination["recovery"]?.objectFields != nil)
    }

    @Test("Mode registry reloads project config and notifies observers")
    func modeRegistryReloadsProjectConfig() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-profile-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("reload-mode.json")
        let initial = """
        {
          "id": "reload-mode",
          "extends": "plan",
          "label": "Reload Mode A"
        }
        """
        try initial.write(to: file, atomically: true, encoding: .utf8)
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            projectConfigDirectory: dir,
            projectConfigSource: .operatorDirectory
        )
        #expect(try await registry.resolve(modeId: "reload-mode").label == "Reload Mode A")

        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        await registry.setOnDidMutate { counter.value += 1 }

        let updated = """
        {
          "id": "reload-mode",
          "extends": "plan",
          "label": "Reload Mode B"
        }
        """
        try updated.write(to: file, atomically: true, encoding: .utf8)
        #expect(await registry.reloadProjectConfig())
        #expect(counter.value == 1)
        #expect(try await registry.resolve(modeId: "reload-mode").label == "Reload Mode B")
    }

    @Test("Operator project overlay cannot escalate tools allow list")
    func operatorProjectOverlayCannotEscalateTools() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-profile-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let baseline = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let baselineAgent = try await baseline.resolve(modeId: InteractionMode.agent.rawValue)

        let file = dir.appendingPathComponent("escalation.json")
        let raw = """
        {
          "id": "project-agent",
          "extends": "agent",
          "label": "Project Agent",
          "tools": { "allow": ["*"], "deny": [] },
          "runtime": { "maxIterations": 999 },
          "subAgents": { "allow": ["*"] }
        }
        """
        try raw.write(to: file, atomically: true, encoding: .utf8)

        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            projectConfigDirectory: dir,
            projectConfigSource: .operatorDirectory
        )
        let profile = try await registry.resolve(modeId: "project-agent")
        #expect(profile.tools.allow == baselineAgent.tools.allow)
        #expect(profile.runtime.maxIterations == baselineAgent.runtime.maxIterations)
        #expect(profile.subAgents.allow == baselineAgent.subAgents.allow)
        #expect(profile.label == "Project Agent")

        let diagnostics = await registry.configurationDiagnostics()
        #expect(diagnostics.contains("modeProfiles[project-agent] project overlay stripped security slice 'tools'"))
        #expect(diagnostics.contains("modeProfiles[project-agent] project overlay stripped security slice 'runtime'"))
        #expect(diagnostics.contains("modeProfiles[project-agent] project overlay stripped security slice 'subAgents'"))
    }

    @Test("Operator project overlay reload remains sanitized")
    func operatorProjectOverlayReloadRemainsSanitized() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-profile-reload-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let baseline = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let baselineAgent = try await baseline.resolve(modeId: InteractionMode.agent.rawValue)

        let file = dir.appendingPathComponent("escalation-reload.json")
        try """
        {
          "id": "reload-project-agent",
          "extends": "agent",
          "tools": { "allow": ["*"] }
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            projectConfigDirectory: dir,
            projectConfigSource: .operatorDirectory
        )
        #expect(try await registry.resolve(modeId: "reload-project-agent").tools.allow == baselineAgent.tools.allow)

        try """
        {
          "id": "reload-project-agent",
          "extends": "agent",
          "tools": { "allow": ["bash", "write_file"] },
          "runtime": { "maxIterations": 500 }
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        #expect(await registry.reloadProjectConfig())
        #expect(try await registry.resolve(modeId: "reload-project-agent").tools.allow == baselineAgent.tools.allow)
        #expect(try await registry.resolve(modeId: "reload-project-agent").runtime.maxIterations == baselineAgent.runtime.maxIterations)
    }
}
