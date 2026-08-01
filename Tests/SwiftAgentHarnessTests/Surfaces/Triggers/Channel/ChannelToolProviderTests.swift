import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelToolProvider")
struct ChannelToolProviderTests {
    private struct Fixture {
        var provider: ChannelToolProvider
        var registry: ChannelListenerRegistry
        var state: ChannelRuntimeStateStore
    }

    private func makeFixture(
        channels: [String: ChannelListenerConfig] = ["slack": ChannelListenerConfig(enabled: true, transport: .mock)]
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chan-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("channels.json")
        try JSONEncoder().encode(ChannelsFile(channels: channels)).write(to: configURL)

        let state = ChannelRuntimeStateStore(
            fileURL: directory.appendingPathComponent("channel_runtime_state.json")
        )
        let store = ScheduledTaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let registry = ChannelListenerRegistry(
            dataDirectory: directory,
            ingress: Self.makeIngress(),
            dedupe: ChannelTestDedupe(),
            logger: Logger(label: "test"),
            enabled: false,
            channelsFile: ChannelsFile(channels: channels),
            configURL: configURL,
            runtimeState: state
        )
        let dataService = ScheduledTaskToolDataService(
            scheduler: TriggerSchedulerService(
                store: store,
                deliver: { _ in TriggerActivationResult(decision: .admitted, sessionID: nil) },
                lockURL: directory.appendingPathComponent("scheduler.lock"),
                logger: Logger(label: "test")
            ),
            registration: TriggerRegistrationTestSupport.service(store: store),
            catalogPort: ScheduleToolCatalogPort(getConversation: { _ in nil }),
            channelRegistry: registry
        )
        return Fixture(
            provider: ChannelToolProvider(dataService: dataService),
            registry: registry,
            state: state
        )
    }

    private static func makeIngress() -> ChannelIngressAdapter {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: ChannelTestDedupe()),
            rateLimit: TriggerRateLimitGate(),
            costCeiling: TriggerCostCeilingGate(),
            auditLog: TriggerAuditLog(logger: Logger(label: "test"))
        )
        return ChannelIngressAdapter(
            dispatch: TriggerDispatchService(
                activationPolicy: policy,
                sessionRouter: TriggerSessionRouter(
                    sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })
                ),
                promptBuilder: TriggerPromptBuilder(),
                runtime: DMScopeNoopRuntime()
            )
        )
    }

    private func call(_ fixture: Fixture, _ arguments: JSON) async throws -> ToolResult {
        try await fixture.provider.executeTool(
            ToolCall(name: ToolControlPlaneClassification.TriggerTools.channel, arguments: arguments, id: "t")
        )
    }

    private func slash(_ args: String) -> JSON {
        .object(["commandName": .string("channel"), "args": .string(args)])
    }

    // MARK: - Schema

    /// The schema is the enforcement. A mutation action advertised here would be a button that
    /// always returns denied — `allowsRegistration(_:kind: .channel)` refuses model-driven creators.
    @Test("only read actions are advertised")
    func schemaIsReadOnly() async throws {
        let fixture = try makeFixture()
        let tools = await fixture.provider.availableTools()
        let definition = try #require(tools.first)
        #expect(definition.name == ToolControlPlaneClassification.TriggerTools.channel)
        let action = try #require(definition.parameters.first { $0.name == "action" })
        #expect(action.description.contains("list"))
        #expect(action.description.contains("get"))
        #expect(action.description.contains("pause") == false)
        #expect(action.description.contains("disable") == false)
    }

    // MARK: - Reads

    @Test("list reports a configured channel")
    func listReportsChannel() async throws {
        let fixture = try makeFixture()
        let result = try await call(fixture, .object(["action": .string("list")]))
        #expect(result.success)
        #expect(result.content.contains("slack"))
        #expect(result.content.contains("transport=mock"))
        #expect(result.content.contains("config=enabled"))
    }

    /// The question the tool exists to answer. A channel the user switched off must appear, not read
    /// as "not configured".
    @Test("a config-disabled channel is reported, not treated as absent")
    func disabledChannelReported() async throws {
        let fixture = try makeFixture(channels: ["slack": ChannelListenerConfig(enabled: false, transport: .mock)])
        let result = try await call(fixture, .object(["action": .string("get"), "channel": .string("slack")]))
        #expect(result.success)
        #expect(result.content.contains("config=disabled"))
        #expect(result.content.contains("listener=none"))
    }

    @Test("a runtime pause is visible")
    func pauseVisible() async throws {
        let fixture = try makeFixture()
        try fixture.state.setDisabled(channel: .slack, disabled: true, changedBy: .owner(accountID: nil))
        let result = try await call(fixture, .object(["action": .string("get"), "channel": .string("slack")]))
        #expect(result.content.contains("runtime=paused"))
    }

    @Test("an empty deployment says so rather than returning nothing")
    func emptyDeployment() async throws {
        let fixture = try makeFixture(channels: [:])
        let result = try await call(fixture, .object(["action": .string("list")]))
        #expect(result.success)
        #expect(result.content.contains("no channel listeners configured"))
    }

    @Test("an unknown channel id is rejected")
    func unknownChannel() async throws {
        let fixture = try makeFixture()
        let result = try await call(fixture, .object(["action": .string("get"), "channel": .string("myspace")]))
        #expect(result.success == false)
        #expect(result.error?.contains("unknown_channel") == true)
    }

    @Test("get without a channel is rejected")
    func getRequiresChannel() async throws {
        let fixture = try makeFixture()
        let result = try await call(fixture, .object(["action": .string("get")]))
        #expect(result.success == false)
        #expect(result.error?.contains("name_required") == true)
    }

    @Test("a channel absent from config is not configured")
    func absentChannelNotConfigured() async throws {
        let fixture = try makeFixture()
        let result = try await call(fixture, .object(["action": .string("get"), "channel": .string("telegram")]))
        #expect(result.success == false)
        #expect(result.error?.contains("not_configured") == true)
    }

    // MARK: - The redaction claim

    /// This is what earns `channel` its place in `statusOnlyResults` rather than the external-content
    /// envelope, and until now it was asserted only in a comment.
    ///
    /// A fatal *message* is `String(describing:)` of a transport error and routinely carries the URL,
    /// sometimes the rejected token. The tool must surface the code and never the message.
    @Test("a fatal error surfaces its code and never its message")
    func fatalMessageNeverLeaks() async throws {
        let fixture = try makeFixture()
        let listener = try #require(await fixture.registry.listener(for: .slack))
        listener.setFatal(
            ChannelFatalError(
                code: "connect_failed",
                message: "https://hooks.example.com/services/T000/B000/xoxb-SUPER-SECRET",
                retryable: true
            )
        )
        let result = try await call(fixture, .object(["action": .string("get"), "channel": .string("slack")]))
        #expect(result.content.contains("connect_failed"))
        #expect(result.content.contains("xoxb-SUPER-SECRET") == false, "the fatal message must not reach the model")
        #expect(result.content.contains("hooks.example.com") == false)
    }

    // MARK: - Owner-only refusals

    /// Named explicitly rather than falling into "unknown action": the difference between "that verb
    /// does not exist" and "that verb exists and you may not have it" decides whether the model
    /// retries with synonyms or tells the user.
    @Test("mutation verbs are refused with a pointer to the operator CLI")
    func mutationRefused() async throws {
        let fixture = try makeFixture()
        for action in ["pause", "resume"] {
            let mapped = try #require(TriggerToolArgumentBridge.channelArguments(from: slash("\(action) slack")))
            let result = try await call(fixture, mapped)
            #expect(result.success == false)
            let error = result.error ?? ""
            #expect(error.contains("owner_only"))
            #expect(error.contains("trigger channel"), "the refusal should name the command that works")
            #expect(error.contains("--data-directory"), "which requires an explicit data directory")
        }
    }

    /// `reload` has no owner client at all, so it must not be reported as owner-gated — that would
    /// point the user at a command nobody can run.
    @Test("reload is an unknown action, not an owner-only refusal")
    func reloadIsUnknown() async throws {
        let fixture = try makeFixture()
        let result = try await call(fixture, .object(["action": .string("reload"), "channel": .string("slack")]))
        #expect(result.success == false)
        #expect(result.error?.contains("unknown action") == true)
        #expect(result.error?.contains("owner_only") == false)
    }

    // MARK: - Slash dispatch

    @Test("a slash line reaches the same handler as a model call")
    func slashDispatchWorks() async throws {
        let fixture = try makeFixture()
        let mapped = try #require(TriggerToolArgumentBridge.channelArguments(from: slash("status slack")))
        let result = try await call(fixture, mapped)
        #expect(result.success)
        #expect(result.content.contains("slack"))
    }

    @Test("an unparseable slash line returns usage")
    func slashUsage() async throws {
        let fixture = try makeFixture()
        let result = try await call(fixture, slash("frobnicate"))
        #expect(result.success == false)
        #expect(result.error?.contains("usage:") == true)
    }
}
