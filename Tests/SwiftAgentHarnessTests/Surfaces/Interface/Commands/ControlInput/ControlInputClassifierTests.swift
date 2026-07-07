import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ControlInputClassifier")
struct ControlInputClassifierTests {
    private func registry() -> SlashCommandRegistry {
        CoreCommandCatalog.registry(compactEnabled: true)
    }

    @Test("Whole-message command skips model turn classification")
    func wholeMessageCommand() {
        let classifier = ControlInputClassifier(registry: registry())
        let result = classifier.classify(input: "/compact")
        guard case let .command(command, parsed) = result else {
            Issue.record("Expected command classification")
            return
        }
        #expect(command.base.name == "compact")
        #expect(parsed.name == "compact")
    }

    @Test("Directive-only message persists session settings")
    func directiveOnly() {
        let classifier = ControlInputClassifier(registry: registry())
        let result = classifier.classify(input: "/think high")
        guard case let .directiveOnly(directives) = result else {
            Issue.record("Expected directive-only classification")
            return
        }
        #expect(directives.count == 1)
        #expect(directives[0].scope == .sessionSetting)
        #expect(directives[0].thinkingConfig == .level(.high, budgetTokens: nil))
    }

    @Test("Inline directive strips before model and scopes to one turn")
    func inlineHint() {
        let classifier = ControlInputClassifier(registry: registry())
        let result = classifier.classify(input: "/think high summarize the logs")
        guard case let .inlineHint(directives, prose) = result else {
            Issue.record("Expected inline-hint classification")
            return
        }
        #expect(directives.count == 1)
        #expect(directives[0].scope == .inlineHint)
        #expect(prose == "summarize the logs")
    }

    @Test("Inline shortcut runs then continues prose")
    func inlineShortcut() {
        let classifier = ControlInputClassifier(registry: registry())
        let result = classifier.classify(input: "/status what's the weather")
        guard case let .inlineShortcut(shortcuts, prose) = result else {
            Issue.record("Expected inline-shortcut classification")
            return
        }
        #expect(shortcuts.count == 1)
        #expect(shortcuts[0].kind == .status)
        #expect(prose == "what's the weather")
    }

    @Test("Unauthorized privileged input falls through to plain text")
    func unauthorizedFallThrough() {
        let classifier = ControlInputClassifier(registry: registry())
        let auth = ControlInputAuthorization(isOwner: false, trustClass: .trusted, allowlistAllows: false)
        let result = classifier.classify(input: "/model gpt-4o", authorization: auth)
        guard case let .plainText(text) = result else {
            Issue.record("Expected plain-text fall-through")
            return
        }
        #expect(text == "/model gpt-4o")
    }

    @Test("Plain text without leading slash is unchanged")
    func plainText() {
        let classifier = ControlInputClassifier(registry: registry())
        let result = classifier.classify(input: "hello there")
        guard case let .plainText(text) = result else {
            Issue.record("Expected plain text")
            return
        }
        #expect(text == "hello there")
    }
}
