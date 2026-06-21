import Foundation
import Testing
@testable import SwiftAgentHarness

/// Pure-function tests for the `/compact` slash parser:
///   - `/compact`            → empty reason
///   - `/compact <reason>`   → trimmed reason
///   - `/compactxyz`         → not a slash command (no false positive)
///   - leading/trailing whitespace tolerated
@Suite("HarnessRuntimeSession parseCompactSlashCommand")
struct HarnessRuntimeSessionCompactSlashParserTests {

    @Test("Bare /compact returns empty reason string")
    func bareCommand() {
        let reason = SlashCommandDispatchService.parseCompactSlashCommand("/compact")
        #expect(reason == "")
    }

    @Test("/compact with trailing whitespace still returns empty reason")
    func bareCommandWithTrailingWhitespace() {
        let reason = SlashCommandDispatchService.parseCompactSlashCommand("  /compact   \n")
        #expect(reason == "")
    }

    @Test("/compact <reason> returns trimmed reason")
    func reasonExtracted() {
        let reason = SlashCommandDispatchService.parseCompactSlashCommand("/compact switching tasks")
        #expect(reason == "switching tasks")
    }

    @Test("/compact <reason> with extra interior whitespace preserves interior spaces")
    func reasonWithInteriorSpaces() {
        let reason = SlashCommandDispatchService.parseCompactSlashCommand("/compact   talking about a   new topic   ")
        #expect(reason == "talking about a   new topic")
    }

    @Test("/compactxyz is not a slash command")
    func noFalsePositiveOnPrefixCollision() {
        let reason = SlashCommandDispatchService.parseCompactSlashCommand("/compactxyz")
        #expect(reason == nil)
    }

    @Test("/compact-suffix style is not a slash command")
    func noFalsePositiveOnDashSuffix() {
        let reason = SlashCommandDispatchService.parseCompactSlashCommand("/compact-now")
        #expect(reason == nil)
    }

    @Test("Plain text does not parse as a slash command")
    func plainTextDoesNotParse() {
        #expect(SlashCommandDispatchService.parseCompactSlashCommand("Please compact this") == nil)
        #expect(SlashCommandDispatchService.parseCompactSlashCommand("compact") == nil)
        #expect(SlashCommandDispatchService.parseCompactSlashCommand("") == nil)
    }

    @Test("Slash command with empty reason after marker returns empty reason")
    func emptyReasonAfterMarker() {
        // "/compact " (with a single trailing space) does not match the "has prefix && length >"
        // guard, so the parser falls through to the `/compact` exact branch only when trimming.
        // After trimming, it is exactly "/compact", returning "".
        let reason = SlashCommandDispatchService.parseCompactSlashCommand("/compact ")
        #expect(reason == "")
    }
}
