import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Tool System — deferred loading and tool_search")
struct DeferredToolLoadingTests {
    private let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
    private let configuration = AgentRuntimeTurnConfiguration(
        managerConfiguration: HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)
    )

    private func conversation(loaded: Set<String> = []) -> ModelConversation {
        var conversation = ModelConversation(
            id: UUID(),
            model: Model(
                id: UUID(), protocol: .anthropic, modelName: "m", serverURL: URL(string: "https://example.com")!,
                capabilities: [.completion, .tools], modelProtocol: .anthropic
            ),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        if !loaded.isEmpty { conversation.metadata = DeferredToolLoading.mergingLoadedToolNames(loaded, into: nil) }
        return conversation
    }

    private func entry(_ name: String, description: String = "", deferred: Bool = false, hint: String? = nil) -> ToolRegistryEntry {
        var tags: [ToolPolicyTag] = []
        if deferred { tags.append(DeferredToolLoading.deferLoadingTag) }
        if let hint { tags.append(DeferredToolLoading.searchHintTag(hint)) }
        return ToolRegistryEntry(descriptor: RegisteredToolDescriptor(
            definition: ToolDefinition(name: name, description: description, parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable,
            policyTags: tags,
            normalizedSchema: ToolSchemaNormalizer().normalize(rawSchema: .object([:]), source: .local)
        ))
    }

    private func advertised(
        _ entries: [ToolRegistryEntry],
        conversation: ModelConversation,
        tools: ModeProfileToolsSlice = ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
    ) -> [String] {
        var profile = ResolvedModeProfile.builtIn(for: conversation.interactionMode)
        profile.tools = tools
        return gateway.effectiveEntriesForConversation(
            entries: entries,
            conversation: conversation,
            modePolicyContext: ModePolicyContext(conversation: conversation, resolvedProfile: profile),
            configuration: configuration,
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        ).map(\.name)
    }

    private var catalog: [ToolRegistryEntry] {
        [
            entry("read_file", description: "Read a file."),
            entry("delegate_computer_use", description: "Delegate a task on a screen.", deferred: true, hint: "desktop app GUI click"),
            entry(DeferredToolLoading.searchToolName, description: "Find tools."),
        ]
    }

    @Test("A deferred tool is held back and tool_search is offered until the tool is loaded")
    func heldBack() {
        #expect(advertised(catalog, conversation: conversation()) == ["read_file", "tool_search"])
        #expect(advertised(catalog, conversation: conversation(loaded: ["delegate_computer_use"])) == ["delegate_computer_use", "read_file"])
    }

    @Test("Without deferred candidates there is no tool_search")
    func noCandidates() {
        let entries = [entry("read_file"), entry(DeferredToolLoading.searchToolName)]
        #expect(advertised(entries, conversation: conversation()) == ["read_file"])
    }

    @Test("A deferred tool the mode blocks is no candidate, so search can't reveal it")
    func policyBlockedIsNoCandidate() {
        let names = advertised(
            catalog,
            conversation: conversation(),
            tools: ModeProfileToolsSlice(allow: ["*"], deny: ["delegate_*"], approvalPolicy: nil)
        )
        #expect(names == ["read_file"])
    }

    @Test("When the mode blocks tool_search, deferred tools are offered directly rather than lost")
    func searchBlockedFallsBack() {
        let names = advertised(
            catalog,
            conversation: conversation(),
            tools: ModeProfileToolsSlice(allow: ["read_file", "delegate_*"], deny: [], approvalPolicy: nil)
        )
        #expect(names == ["delegate_computer_use", "read_file"])
    }

    @Test("Search hints come from the search-hint tag; deferral from the defer-loading tag")
    func entryFields() {
        let delegate = entry("d", deferred: true, hint: "desktop app GUI")
        #expect(delegate.policyTags.contains(.deferLoading))
        #expect(delegate.searchHint == "desktop app GUI")
        #expect(entry("plain").searchHint == nil)
        #expect(!entry("plain").policyTags.contains(.deferLoading))
    }

    @Test("Ranking weighs name over hint over description, and drops non-matches")
    func ranking() {
        let candidates = [
            DeferredToolCandidate(name: "delegate_computer_use", description: "Run a task on a screen.", searchHint: "desktop app GUI click type"),
            DeferredToolCandidate(name: "mcp__calendar__create_event", description: "Create a calendar event in the desktop calendar app.", searchHint: nil),
            DeferredToolCandidate(name: "mcp__weather__forecast", description: "Weather forecast.", searchHint: nil),
        ]
        #expect(DeferredToolLoading.rank(candidates, query: "click a button in a desktop app", limit: 5).map(\.name)
            == ["delegate_computer_use", "mcp__calendar__create_event"])
        #expect(DeferredToolLoading.rank(candidates, query: "calendar", limit: 5).map(\.name) == ["mcp__calendar__create_event"])
        #expect(DeferredToolLoading.rank(candidates, query: "mcp__weather__forecast", limit: 5).map(\.name) == ["mcp__weather__forecast"])
        #expect(DeferredToolLoading.rank(candidates, query: "desktop", limit: 1).count == 1)
        #expect(DeferredToolLoading.rank(candidates, query: "spreadsheet", limit: 5).isEmpty)
    }

    @Test("Loaded names merge into conversation metadata and clients can't write them")
    func metadata() {
        let merged = DeferredToolLoading.mergingLoadedToolNames(["b", "a"], into: .object(["topic": .string("x")]))
        #expect(DeferredToolLoading.loadedToolNames(from: merged) == ["a", "b"])
        let again = DeferredToolLoading.mergingLoadedToolNames(["c"], into: merged)
        #expect(DeferredToolLoading.loadedToolNames(from: again) == ["a", "b", "c"])
        #expect(ConversationHarnessMetadataKeys.isClientWriteDenied(DeferredToolLoading.metadataKey))
    }

    @Test("tool_search loads what matches and reports it; an empty query or no match loads nothing")
    func provider() async throws {
        let catalog = DeferredToolCatalog()
        let conversationID = UUID()
        await catalog.setCandidates([
            DeferredToolCandidate(name: "delegate_computer_use", description: "Run a task on a screen. More detail.", searchHint: "desktop app"),
        ], for: conversationID)
        let loaded = LoadedNamesRecorder()
        let provider = ToolSearchToolProvider(resolveConversationID: { conversationID }, catalog: catalog) { id, names in
            #expect(id == conversationID)
            await loaded.record(names)
        }

        #expect(await provider.availableTools().map(\.name) == [DeferredToolLoading.searchToolName])
        let hit = try await provider.executeTool(ToolCall(name: DeferredToolLoading.searchToolName, arguments: .object(["query": .string("desktop app")]), id: "1"))
        #expect(hit.success)
        #expect(hit.content.contains("delegate_computer_use"))
        #expect(hit.content.contains("Run a task on a screen."))
        #expect(await loaded.names == [["delegate_computer_use"]])

        let miss = try await provider.executeTool(ToolCall(name: DeferredToolLoading.searchToolName, arguments: .object(["query": .string("weather")]), id: "2"))
        #expect(miss.content.contains("No tools match"))
        let empty = try await provider.executeTool(ToolCall(name: DeferredToolLoading.searchToolName, arguments: .object(["query": .string("  ")]), id: "3"))
        #expect(!empty.success)
        #expect(await loaded.names.count == 1)
    }
}

private actor LoadedNamesRecorder {
    private(set) var names: [[String]] = []
    func record(_ loaded: [String]) { names.append(loaded) }
}
