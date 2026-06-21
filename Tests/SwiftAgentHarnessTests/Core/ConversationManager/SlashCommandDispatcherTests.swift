import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Slash command parser and dispatcher")
struct SlashCommandDispatcherTests {

    @Test("Parser supports whitespace and colon argument styles")
    func parserSupportsMultipleArgStyles() {
        let parser = SlashCommandParser()

        let byWhitespace = parser.parse("/compact because context is large")
        #expect(byWhitespace?.name == "compact")
        #expect(byWhitespace?.args == "because context is large")

        let byColon = parser.parse("/compact:because context is large")
        #expect(byColon?.name == "compact")
        #expect(byColon?.args == "because context is large")
    }

    @Test("Alias resolves to the same command")
    func aliasResolution() {
        let command = SlashCommand(
            base: SlashCommandBase(
                name: "compact",
                aliases: ["shrink"],
                description: "Compact"
            ),
            kind: .local
        )
        let registry = SlashCommandRegistry(commands: [command])

        #expect(registry.resolve("compact")?.base.name == "compact")
        #expect(registry.resolve("shrink")?.base.name == "compact")
    }

    @Test("Unknown command passes through when configured")
    func unknownCommandPassthrough() {
        let registry = SlashCommandRegistry(commands: [])
        let dispatcher = SlashCommandDispatcher(registry: registry)

        let result = dispatcher.dispatch(
            input: "/does-not-exist",
            runtimeConfig: SlashCommandRuntimeConfiguration(
                enabled: true,
                allowUnknownPassthrough: true,
                compactEnabled: true
            )
        )
        #expect(result == .passthrough)
    }

    @Test("Disabled command is surfaced when passthrough is disabled")
    func disabledCommandHandling() {
        let command = SlashCommand(
            base: SlashCommandBase(
                name: "compact",
                description: "Compact",
                isEnabled: false
            ),
            kind: .local
        )
        let registry = SlashCommandRegistry(commands: [command])
        let dispatcher = SlashCommandDispatcher(registry: registry)

        let result = dispatcher.dispatch(
            input: "/compact",
            runtimeConfig: SlashCommandRuntimeConfiguration(
                enabled: true,
                allowUnknownPassthrough: false,
                compactEnabled: true
            )
        )
        guard case .disabled = result else {
            Issue.record("Expected disabled dispatch result")
            return
        }
    }

    @Test("Builtin compact command dispatches as local when enabled")
    func builtinCompactDispatchesLocal() {
        let registry = SlashCommandRegistry.builtins(compactEnabled: true)
        let dispatcher = SlashCommandDispatcher(registry: registry)

        let result = dispatcher.dispatch(
            input: "/compact",
            runtimeConfig: SlashCommandRuntimeConfiguration(
                enabled: true,
                allowUnknownPassthrough: true,
                compactEnabled: true
            )
        )
        guard case let .local(command, parsed) = result else {
            Issue.record("Expected local compact command")
            return
        }
        #expect(command.base.name == "compact")
        #expect(parsed.args == "")
    }

    @Test("Tool dispatch commands classify as toolDispatch")
    func toolDispatchClassification() {
        let command = SlashCommand(
            base: SlashCommandBase(
                name: "queue",
                description: "Queue command"
            ),
            kind: .toolDispatch(toolName: "list_conversations", argMode: .raw)
        )
        let dispatcher = SlashCommandDispatcher(registry: SlashCommandRegistry(commands: [command]))
        let result = dispatcher.dispatch(
            input: "/queue now",
            runtimeConfig: SlashCommandRuntimeConfiguration(
                enabled: true,
                allowUnknownPassthrough: false,
                compactEnabled: true,
                skillSlashEnabled: true
            )
        )
        guard case let .toolDispatch(resolved, parsed) = result else {
            Issue.record("Expected toolDispatch result")
            return
        }
        guard case let .toolDispatch(toolName, argMode) = resolved.kind else {
            Issue.record("Expected tool dispatch kind")
            return
        }
        #expect(toolName == "list_conversations")
        #expect(argMode == .raw)
        #expect(parsed.name == "queue")
        #expect(parsed.args == "now")
    }
}
