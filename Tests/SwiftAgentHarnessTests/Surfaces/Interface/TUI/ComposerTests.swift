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
        let submission = ComposerSubmission(
            text: "/help",
            provenance: ComposerProvenance(
                originSurface: InteractiveSurfaceID.tui,
                inputTrustRaw: MessageInputTrust.directUserEntry.rawValue
            )
        )
        let result = bridge.classify(submission)
        if case .command = result {
            #expect(Bool(true))
        } else {
            Issue.record("Expected command classification")
        }
    }

    @Test("TUI surface with omitted trust classifies privileged slash commands")
    func classifyTUIOmittedTrustCommand() {
        let bridge = TUIControlInputBridge()
        let submission = ComposerSubmission(
            text: "/help",
            provenance: ComposerProvenance(originSurface: InteractiveSurfaceID.tui)
        )
        let result = bridge.classify(submission)
        if case .command = result {
            #expect(Bool(true))
        } else {
            Issue.record("Expected command classification for TUI surface with omitted trust")
        }
    }

    @Test("Untrusted composer submission falls through privileged slash commands")
    func classifyUntrustedCommandFallThrough() {
        let bridge = TUIControlInputBridge()
        let submission = ComposerSubmission(
            text: "/help",
            provenance: ComposerProvenance(
                originSurface: InteractiveSurfaceID.rest,
                inputTrustRaw: MessageInputTrust.automation.rawValue
            )
        )
        let result = bridge.classify(submission)
        guard case let .plainText(text) = result else {
            Issue.record("Expected plain-text fall-through")
            return
        }
        #expect(text == "/help")
    }

    @Test("Builds runtime turn configuration with TUI provenance")
    func runtimeTurnConfiguration() {
        let bridge = TUIControlInputBridge()
        let submission = ComposerSubmission(
            text: "hello",
            provenance: ComposerProvenance(originSurface: InteractiveSurfaceID.tui)
        )
        let configuration = bridge.runtimeTurnConfiguration(from: submission)
        #expect(configuration.originSurface == InteractiveSurfaceID.tui)
        #expect(configuration.ephemeralSystemReminder?.contains("Output contract:") == true)
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

@Suite("BracketedPasteAccumulator")
struct BracketedPasteAccumulatorTests {
    @Test("Single-chunk paste passes through whole")
    func singleChunk() {
        var acc = BracketedPasteAccumulator()
        let inner = "hello paste"
        let wrapped = BracketedPaste.start + inner + BracketedPaste.end
        let chunks = acc.feed(wrapped)
        #expect(chunks == [wrapped])
        #expect(BracketedPaste.unwrap(chunks[0])?.text == inner)
    }

    @Test("Paste content split across reads reassembles")
    func splitContent() {
        var acc = BracketedPasteAccumulator()
        let inner = String(repeating: "x", count: 300)
        let wrapped = BracketedPaste.start + inner + BracketedPaste.end
        let mid = wrapped.index(wrapped.startIndex, offsetBy: 128)
        let first = String(wrapped[..<mid])
        let second = String(wrapped[mid...])
        #expect(acc.feed(first).isEmpty)
        let chunks = acc.feed(second)
        #expect(chunks.count == 1)
        #expect(BracketedPaste.unwrap(chunks[0])?.text == inner)
    }

    @Test("Start marker split across reads reassembles")
    func splitStartMarker() {
        var acc = BracketedPasteAccumulator()
        let inner = "pasted"
        let wrapped = BracketedPaste.start + inner + BracketedPaste.end
        let splitAt = BracketedPaste.start.index(BracketedPaste.start.startIndex, offsetBy: 3)
        let head = String(BracketedPaste.start[..<splitAt])
        let tail = String(BracketedPaste.start[splitAt...]) + inner + BracketedPaste.end
        #expect(acc.feed(head).isEmpty)
        let chunks = acc.feed(tail)
        #expect(chunks.count == 1)
        #expect(BracketedPaste.unwrap(chunks[0])?.text == inner)
    }

    @Test("End marker split across reads reassembles")
    func splitEndMarker() {
        var acc = BracketedPasteAccumulator()
        let inner = "pasted"
        let endPrefix = String(BracketedPaste.end.prefix(4))
        let endSuffix = String(BracketedPaste.end.dropFirst(4))
        let head = BracketedPaste.start + inner + endPrefix
        #expect(acc.feed(head).isEmpty)
        let chunks = acc.feed(endSuffix)
        #expect(chunks.count == 1)
        #expect(BracketedPaste.unwrap(chunks[0])?.text == inner)
    }

    @Test("Normal typed input passes through unchanged")
    func passthrough() {
        var acc = BracketedPasteAccumulator()
        #expect(acc.feed("h") == ["h"])
        #expect(acc.feed("\r") == ["\r"])
        #expect(acc.feed("\u{1B}[A") == ["\u{1B}[A"])
    }

    @Test("Text before and after paste emits separate chunks")
    func surroundingText() {
        var acc = BracketedPasteAccumulator()
        let inner = "paste"
        let wrapped = BracketedPaste.start + inner + BracketedPaste.end
        let chunks = acc.feed("before" + wrapped + "after")
        #expect(chunks == ["before", wrapped, "after"])
    }

    @Test("Large paste chunked at 256 bytes reassembles with correct metadata")
    func largePasteChunked() {
        var acc = BracketedPasteAccumulator()
        let inner = String(repeating: "line\n", count: 12)
        let wrapped = BracketedPaste.start + inner + BracketedPaste.end
        var chunks: [String] = []
        var index = wrapped.startIndex
        while index < wrapped.endIndex {
            let end = wrapped.index(index, offsetBy: 256, limitedBy: wrapped.endIndex) ?? wrapped.endIndex
            chunks.append(contentsOf: acc.feed(String(wrapped[index..<end])))
            index = end
        }
        #expect(chunks.count == 1)
        let result = BracketedPaste.unwrap(chunks[0])
        #expect(result?.text == inner)
        #expect(result?.isLargePaste == true)
        #expect(result?.lineCount == 13)
    }

    @Test("Fragmented paste routed through composer records provenance")
    func composerIntegration() {
        var acc = BracketedPasteAccumulator()
        let inner = String(repeating: "paste-content-", count: 20)
        let wrapped = BracketedPaste.start + inner + BracketedPaste.end
        let splitAt = wrapped.index(wrapped.startIndex, offsetBy: wrapped.count / 2)
        _ = acc.feed(String(wrapped[..<splitAt]))
        let chunks = acc.feed(String(wrapped[splitAt...]))
        let composer = InputComposerComponent()
        for chunk in chunks {
            composer.handleInput(chunk)
        }
        #expect(composer.text == inner)
        #expect(composer.makeSubmission().provenance.wasPasted)
    }
}
