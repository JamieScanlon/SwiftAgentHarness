import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SlashCommandDispatchService")
struct SlashCommandDispatchServiceTests {
    @Test("parseCompactSlashCommand recognizes /compact and optional reason")
    func parseCompactSlashCommand() {
        #expect(SlashCommandDispatchService.parseCompactSlashCommand("/compact") == "")
        #expect(SlashCommandDispatchService.parseCompactSlashCommand("/compact focus docs") == "focus docs")
        #expect(SlashCommandDispatchService.parseCompactSlashCommand("/compactxyz") == nil)
    }
}
