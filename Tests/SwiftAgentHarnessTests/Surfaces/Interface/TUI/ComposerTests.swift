import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("InputComposerComponent")
struct InputComposerTests {
    @Test("Inserts characters and emits cursor marker when focused")
    func editing() {
        let composer = InputComposerComponent()
        composer.handleInput("h")
        composer.handleInput("i")
        let lines = composer.render(width: 40)
        #expect(composer.text == "hi")
        #expect(lines.joined().contains(CursorMarker.sentinel))
    }

    @Test("Bracketed paste records provenance")
    func bracketedPaste() {
        let composer = InputComposerComponent()
        let paste = BracketedPaste.start + String(repeating: "line\n", count: 12) + BracketedPaste.end
        composer.handleInput(paste)
        let submission = composer.makeSubmission()
        #expect(submission.provenance.wasPasted)
        #expect(submission.provenance.pasteLineCount > BracketedPaste.largePasteLineThreshold)
    }

    @Test("Produces inbound envelope")
    func submission() {
        let composer = InputComposerComponent()
        composer.handleInput("hello")
        let submission = composer.makeSubmission(originSurface: "tui")
        #expect(submission.text == "hello")
        #expect(submission.provenance.originSurface == "tui")
    }
}

@Suite("AutocompletePopupComponent")
struct AutocompleteTests {
    @Test("Slash command suggestions filter by prefix")
    func slashSuggestions() {
        let registry = SlashCommandRegistry.builtins(compactEnabled: true)
        let suggestions = AutocompletePopupComponent.slashSuggestions(registry: registry, prefix: "hel")
        #expect(suggestions.contains(where: { $0.label == "/help" }))
    }
}

@Suite("TUIControlInputBridge")
struct TUIControlInputBridgeTests {
    @Test("Classifies slash commands from composer submission")
    func classifyCommand() {
        let bridge = TUIControlInputBridge()
        let submission = ComposerSubmission(text: "/help")
        let result = bridge.classify(submission)
        if case .command = result {
            #expect(Bool(true))
        } else {
            Issue.record("Expected command classification")
        }
    }
}

@Suite("BracketedPaste")
struct BracketedPasteTests {
    @Test("Detects large paste")
    func largePaste() {
        let inner = (0..<15).map { "line \($0)" }.joined(separator: "\n")
        let wrapped = BracketedPaste.start + inner + BracketedPaste.end
        let result = BracketedPaste.unwrap(wrapped)
        #expect(result?.isLargePaste == true)
        #expect(BracketedPaste.marker(for: result!) == "[Pasted 15 lines]")
    }
}
