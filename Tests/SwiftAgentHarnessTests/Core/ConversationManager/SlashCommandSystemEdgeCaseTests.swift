// Slash command TDD / edge-case catalog (pure types + HarnessRuntimeSession integration):
//
// PARSER
// - `/` only or effectively empty name → no parse
// - `/skill:…` case-insensitive prefix; skill name lowercased; args after first whitespace
// - `/ skill` (no colon) is generic `builtin`, not `skill` namespace
//
// DISPATCHER
// - `SlashCommandRuntimeConfiguration.enabled == false` → always passthrough
// - `allowUnknownPassthrough == false` + unknown name → `.unknown` (not implicit passthrough)
// - `resolve("/COMPACT")` and `resolve("Compact")` via normalizeKey
//
// REGISTRY
// - `isHidden` commands only appear in autocomplete when `includeHidden == true`
// - `allClassifiedCommandNames(extraHiddenDebugNames:)` unions extras
// - Merged `skill:` rows use tier `.queued` and `source .skill`
//
// CHAT MANAGER
// - Global `slashCommands.enabled == false` → pre-send slash handling returns `nil` (message path would hand off to the model)
// - `compactEnabled == false` → `/compact` passthrough (dispatcher yields nil; no compact run)
// - `skillSlashEnabled == false` → `/skill:…` is not skill-handled (nil; normal message path)
// - Unknown names → dispatcher `.unknown` / passthrough; no spurious local slash success without a match
// - Queue: two items while busy, FIFO drain, depth matches expectations
// - After drain, conversation is idle and queue empty

import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SlashCommandParser edge cases")
struct SlashCommandParserEdgeCaseTests {

    @Test("parse returns nil for bare slash or empty name segment")
    func bareOrInvalidSlash() {
        let p = SlashCommandParser()
        #expect(p.parse("/") == nil)
        #expect(p.parse("   ") == nil)
        #expect(p.parse(" / ") == nil)
    }

    @Test("parseInput lowercases /skill: skill name for lookup")
    func skillNameLowercased() {
        let p = SlashCommandParser()
        guard case let .skill(name, args) = p.parseInput("/SKILL:My-Tool-Name do work") else {
            Issue.record("expected skill")
            return
        }
        #expect(name == "my-tool-name")
        #expect(args == "do work")
    }

    @Test("/skill with space and no colon is builtin, not skill namespace")
    func skillWithSpaceIsBuiltin() {
        let p = SlashCommandParser()
        guard case let .builtin(b) = p.parseInput("/skill web-research") else {
            Issue.record("expected builtin")
            return
        }
        #expect(b.name == "skill")
        #expect(b.args == "web-research")
    }
}

@Suite("SlashCommandRegistry and dispatcher edge cases")
struct SlashCommandRegistryAndDispatcherEdgeCaseTests {

    @Test("resolve normalizes case and leading slash on command name and aliases")
    func resolveNormalizes() {
        let c = SlashCommand(
            base: SlashCommandBase(name: "compact", aliases: ["/C"], description: "d", bypassTier: .queued),
            kind: .local
        )
        let r = SlashCommandRegistry(commands: [c])
        #expect(r.resolve("COMPACT")?.base.name == "compact")
        #expect(r.resolve("/c")?.base.name == "compact")
    }

    @Test("autocomplete omits isHidden unless includeHidden")
    func hiddenFlags() {
        let shown = SlashCommand(
            base: SlashCommandBase(name: "a", description: "d1", isHidden: false, bypassTier: .queued),
            kind: .local
        )
        let hidden = SlashCommand(
            base: SlashCommandBase(name: "b", description: "d2", isHidden: true, bypassTier: .always),
            kind: .local
        )
        let r = SlashCommandRegistry(commands: [shown, hidden])
        #expect(r.autocompleteEntries().count == 1)
        #expect(r.autocompleteEntries(includeHidden: true).map(\.name).sorted() == ["/a", "/b"].sorted())
    }

    @Test("allClassifiedCommandNames includes extra debug names")
    func extraClassified() {
        let c = SlashCommand(
            base: SlashCommandBase(name: "c", description: "d", bypassTier: .connecting),
            kind: .local
        )
        let r = SlashCommandRegistry(commands: [c])
        let u = r.allClassifiedCommandNames(extraHiddenDebugNames: ["/X"])
        #expect(u.contains("c"))
        #expect(u.contains("x"))
    }

    @Test("dispatch returns passthrough when runtime enabled is false")
    func disabledRuntime() {
        let reg = SlashCommandRegistry.builtins(compactEnabled: true)
        let d = SlashCommandDispatcher(registry: reg)
        #expect(
            d.dispatch(
                input: "/compact",
                runtimeConfig: SlashCommandRuntimeConfiguration(enabled: false, allowUnknownPassthrough: true, compactEnabled: true, skillSlashEnabled: true)
            ) == .passthrough
        )
    }

    @Test("dispatchBuiltin yields unknown when allowUnknownPassthrough is false and name missing")
    func unknownWithStrictConfig() {
        let reg = SlashCommandRegistry(commands: [])
        let d = SlashCommandDispatcher(registry: reg)
        let parsed = ParsedSlashCommand(name: "missing", args: "")
        let res = d.dispatchBuiltin(
            parsed: parsed,
            runtimeConfig: SlashCommandRuntimeConfiguration(enabled: true, allowUnknownPassthrough: false, compactEnabled: true, skillSlashEnabled: true),
            isOwner: true
        )
        guard case let .unknown(p) = res else {
            Issue.record("expected unknown")
            return
        }
        #expect(p.name == "missing")
    }

    @Test("dispatchBuiltin is disabled (not unknown) for known command with isEnabled false and strict pass-through off")
    func disabledCommand() {
        let c = SlashCommand(
            base: SlashCommandBase(name: "x", description: "d", bypassTier: .queued, isEnabled: false),
            kind: .local
        )
        let d = SlashCommandDispatcher(registry: SlashCommandRegistry(commands: [c]))
        let res = d.dispatchBuiltin(
            parsed: ParsedSlashCommand(name: "x", args: ""),
            runtimeConfig: SlashCommandRuntimeConfiguration(enabled: true, allowUnknownPassthrough: false, compactEnabled: true, skillSlashEnabled: true),
            isOwner: true
        )
        guard case .disabled = res else {
            Issue.record("expected disabled")
            return
        }
    }

    @Test("merged skill rows are queued and marked skill source")
    func mergedSkillMetadata() {
        let s = [AvailableSkillInfo(name: "Zeta-Skill", description: "Z")]
        let r = SlashCommandRegistry.merged(compactEnabled: true, skills: s, excludedSkillAutocompleteNames: [])
        let sk = r.commands.first { $0.base.name.hasPrefix("skill:") }
        #expect(sk?.base.bypassTier == .queued)
        #expect(sk?.base.source == .skill)
    }
}

private enum SlashEdgeCaseChatSupport {
    static func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    static func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "edge-slash:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func transform(
        contextCompaction: ContextCompactionConfiguration = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            manualSlashEnabled: true
        ),
        slash: SlashCommandConfiguration
    ) -> ConversationTransformConfiguration {
        ConversationTransformConfiguration(
            chat: .allEnabled,
            plan: .allEnabled,
            agent: .allEnabled,
            transformTimeoutSeconds: 1800,
            contextCompaction: contextCompaction,
            slashCommands: slash
        )
    }
}

@Suite("HarnessRuntimeSession slash edge integration", .serialized)
struct HarnessRuntimeSessionSlashEdgeCaseIntegrationTests {

    @Test("When slashCommands.enabled is false, runSlashCommandIfNeeded returns nil for /compact")
    func globalSlashOffDoesNotRunCompact() async throws {
        let container = try SlashEdgeCaseChatSupport.makeContainer()
        let t = SlashEdgeCaseChatSupport.transform(
            slash: SlashCommandConfiguration(
                enabled: false,
                allowUnknownPassthrough: true,
                compactEnabled: true,
                skillSlashEnabled: true
            )
        )
        let m = HarnessRuntimeSession(container: container, conversationTransformConfiguration: t)
        let model = SlashEdgeCaseChatSupport.makeModel()
        try await m.createConversation(with: model, userSystemPrompt: "s")
        let cid = try #require(await m.currentConversationID)
        let r = try await m.testing_runSlashCommandIfNeeded("/compact", conversationID: cid)
        #expect(r == nil)
    }

    @Test("When compactEnabled is false, runSlashCommandIfNeeded returns nil for /compact")
    func compactFeatureOffDoesNotRunCompact() async throws {
        let container = try SlashEdgeCaseChatSupport.makeContainer()
        let t = SlashEdgeCaseChatSupport.transform(
            slash: SlashCommandConfiguration(
                enabled: true,
                allowUnknownPassthrough: true,
                compactEnabled: false,
                skillSlashEnabled: true
            )
        )
        let m = HarnessRuntimeSession(container: container, conversationTransformConfiguration: t)
        let model = SlashEdgeCaseChatSupport.makeModel()
        try await m.createConversation(with: model, userSystemPrompt: "s")
        let cid = try #require(await m.currentConversationID)
        let r = try await m.testing_runSlashCommandIfNeeded("/compact", conversationID: cid)
        #expect(r == nil)
    }

    @Test("When skillSlashEnabled is false, runSlashCommandIfNeeded returns nil for /skill:foo")
    func skillSlashOffDoesNotActivate() async throws {
        let container = try SlashEdgeCaseChatSupport.makeContainer()
        let t = SlashEdgeCaseChatSupport.transform(
            slash: SlashCommandConfiguration(
                enabled: true,
                allowUnknownPassthrough: true,
                compactEnabled: true,
                skillSlashEnabled: false
            )
        )
        let m = HarnessRuntimeSession(container: container, conversationTransformConfiguration: t)
        let model = SlashEdgeCaseChatSupport.makeModel()
        try await m.createConversation(with: model, userSystemPrompt: "s")
        let cid = try #require(await m.currentConversationID)
        let r = try await m.testing_runSlashCommandIfNeeded("/skill:anything", conversationID: cid)
        #expect(r == nil)
    }

    @Test("Two queued /compact run FIFO when drained; queue depth while busy is two")
    func fifoTwoQueuedCompacts() async throws {
        let container = try SlashEdgeCaseChatSupport.makeContainer()
        let m = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = SlashEdgeCaseChatSupport.makeModel()
        try await m.createConversation(with: model, userSystemPrompt: "s")
        let cid = try #require(await m.currentConversationID)

        await m.testing_setSlashDispatchConversationState(
            conversationID: cid,
            state: .generating,
            agenticPhase: .started
        )
        _ = try await m.sendMessageAndStreamResponse("/compact one", images: [], conversationID: cid)
        _ = try await m.sendMessageAndStreamResponse("/compact two", images: [], conversationID: cid)

        #expect(await m.testing_pendingSlashCommandCount(conversationID: cid) == 2)
        let mid = try await m.listCurrentMessages()
        #expect(mid.filter { $0.content.hasPrefix("Queued:") }.count == 2)

        await m.testing_setSlashDispatchConversationState(
            conversationID: cid,
            state: .idle,
            agenticPhase: .idle
        )
        await m.slashCommandDispatchService.drainPendingSlashCommandsIfNeeded(conversationID: cid)

        #expect(await m.testing_pendingSlashCommandCount(conversationID: cid) == 0)
        let end = try await m.listCurrentMessages()
        let compacted = end.filter { $0.role == .assistant && $0.content.contains("Conversation compacted:") }
        #expect(compacted.count == 2)
    }

    @Test("After queue drain, conversation remains idle")
    func stateIdleAfterDrain() async throws {
        let container = try SlashEdgeCaseChatSupport.makeContainer()
        let m = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = SlashEdgeCaseChatSupport.makeModel()
        try await m.createConversation(with: model, userSystemPrompt: "s")
        let cid = try #require(await m.currentConversationID)
        await m.testing_setSlashDispatchConversationState(
            conversationID: cid,
            state: .generating,
            agenticPhase: .started
        )
        _ = try await m.sendMessageAndStreamResponse("/compact x", images: [], conversationID: cid)

        await m.testing_setSlashDispatchConversationState(conversationID: cid, state: .idle, agenticPhase: .idle)
        await m.slashCommandDispatchService.drainPendingSlashCommandsIfNeeded(conversationID: cid)

        let convo = try #require(await m.listConversationInfo().first { $0.id == cid })
        #expect(convo.state == .idle)
        #expect(convo.agenticPhase == .idle)
    }
}
