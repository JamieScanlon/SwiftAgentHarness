import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Slash command /skill: parser")
struct SlashCommandParserSkillTests {

    @Test("parseInput handles case-insensitive /skill: prefix")
    func skillPrefixCaseInsensitive() {
        let parser = SlashCommandParser()
        guard case let .skill(name, args) = parser.parseInput("/SKILL:web-research find papers") else {
            Issue.record("Expected skill parse")
            return
        }
        #expect(name == "web-research")
        #expect(args == "find papers")
    }

    @Test("Dispatcher leaves /skill: to host as passthrough")
    func dispatcherPassthroughForSkill() {
        let reg = SlashCommandRegistry.builtins(compactEnabled: true)
        let d = SlashCommandDispatcher(registry: reg)
        let r = d.dispatch(
            input: "/skill:foo",
            runtimeConfig: SlashCommandRuntimeConfiguration()
        )
        #expect(r == .passthrough)
    }

    @Test("Empty /skill: body does not parse as slash input")
    func emptySkillBody() {
        let parser = SlashCommandParser()
        #expect(parser.parseInput("/skill:") == nil)
        #expect(parser.parseInput("/skill:   ") == nil)
    }
}
