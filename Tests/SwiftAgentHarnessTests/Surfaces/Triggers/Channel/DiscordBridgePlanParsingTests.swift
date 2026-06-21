import Foundation
import Testing
@testable import SwiftAgentHarness

/// Real-world-shaped plan (Discord bridge) used to regression-test parsers.
/// Sanitized: no secrets; paths are illustrative.
@Suite("Discord bridge plan (real-world fixture)")
struct DiscordBridgePlanParsingTests {

    /// Mirrors a typical `plan.md`: overview with emoji bullets (not task lines), then canonical `## Tasks` with `id:` UUID lines.
    static let discordBridgePlanFixture: String = """
    # Plan
    ## Current State Assessment

    **What's Working:**
    - ✅ Discord app set up
    - ✅ Bot token configured and working
    - ✅ #sha-chat channel created with welcome message
    - ✅ server running on port 8080

    **What's NOT Working:**
    - ❌ Discord messages not triggering bot response handler

    **Files Available:**
    - `/example/discord-comm-bot/sha-bot.js` — Discord bot code
    - `/example/discord-comm-bot/api-bridge.js` — API bridge 

    ## Goal
    Set up real AI-powered Discord communication through a dedicated private channel.

    ## Notes
    _No notes yet._

    ## Tasks
    [x] id:A83EBC5B-0F01-4702-BD6F-948FB8BDBDA1 - Investigate why Discord bot isn't responding to messages in #sha-chat
    [/] id:A83EBC5B-0F01-4702-BD6F-948FB8BDBDA2 - Verify sha-bot.js is properly listening for message events in the correct channel
    [/] id:A83EBC5B-0F01-4702-BD6F-948FB8BDBDA3 - Check if bot has correct channel permissions and intents configured
    [/] id:A83EBC5B-0F01-4702-BD6F-948FB8BDBDA4 - Verify server API endpoint structure for receiving messages
    [/] id:A83EBC5B-0F01-4702-BD6F-948FB8BDBDA5 - Check API ARCHITECTURE documentation
    [/] id:A83EBC5B-0F01-4702-BD6F-948FB8BDBDA6 - Ensure API bridge code properly calls server and handles responses
    [/] id:A83EBC5B-0F01-4702-BD6F-948FB8BDBDA7 - Verify all required services are running (bot on port 3000, bridge on port 3001, server on port 8080) - DONE: bot now running on 3000
    [ ] id:A83EBC5B-0F01-4702-BD6F-948FB8BDBDA8 - Implement fix for message flow between Discord and sever
    [ ] id:A83EBC5B-0F01-4702-BD6F-948FB8BDBDA9 - Test complete end-to-end communication through Discord
    [ ] id:11111111-1111-1111-1111-111111111111 - Debug why Discord bot receives messages but doesn't respond - check if messageCreate handler is triggering for #sha-chat channel
    [/] id:22222222-2222-2222-2222-222222222222 - Examine current sha-bot.js implementation and identify message handling logic gaps
    [ ] id:33333333-3333-3333-3333-333333333333 - Check sha-bot.js for errors in message handling logic
    [ ] id:44444444-4444-4444-4444-444444444444 - Examine api-bridge.js to understand current message flow and identify issues with server integration
    [/] id:55555555-5555-5555-5555-555555555555 - Review sha-bot.js message handling and API bridge configuration
    [/] id:A1B2C3D4-E5F6-7890-ABCD-EF1234567890 - Fix api-bridge.js to use proper node-fetch v3 fetch import (named export)
    [ ] id:A2B3C4D5-E6F7-8901-BCDE-F23456789ABC - Design a function/tool for server to send Discord messages through the bot instead of direct API calls
    """

    @Test("PlanMarkdownParser.parseDocument extracts sections and all id: task rows")
    func parseDocumentRoundTrip() {
        let doc = PlanMarkdownParser.parseDocument(Self.discordBridgePlanFixture)
        #expect(doc.goal.contains("AI-powered Discord"))
        #expect(doc.notes.contains("No notes"))
        #expect(doc.overview.contains("Current State Assessment"))
        #expect(doc.overview.contains("✅"))

        #expect(doc.tasks.count == 16)

        let blocked = doc.tasks.filter { $0.status == .blocked }
        let complete = doc.tasks.filter { $0.status == .complete }
        let open = doc.tasks.filter { $0.status == .notStarted }
        let inProgress = doc.tasks.filter { $0.status == .inProgress }

        #expect(blocked.count == 1)
        #expect(complete.count == 9)
        #expect(open.count == 6)
        #expect(inProgress.count == 0)

        let first = UUID(uuidString: "A83EBC5B-0F01-4702-BD6F-948FB8BDBDA1")!
        #expect(blocked[0].id == first)
        #expect(blocked[0].description.hasPrefix("Investigate why Discord"))
    }

    @Test("AgentPlanParser continuation and blocked heuristics match fixture")
    func agentPlanParserHeuristics() {
        let md = Self.discordBridgePlanFixture
        #expect(AgentPlanParser.hasBlockedTaskLine(in: md) == true)
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: md) == false)
        #expect(AgentPlanParser.isPlanFullyComplete(in: md) == false)

        let summary = AgentPlanParser.planProgressSummaryLine(in: md)
        #expect(summary.contains("open: 6"))
        #expect(summary.contains("in progress: 0"))
        #expect(summary.contains("complete: 9"))
        #expect(summary.contains("blocked: 1"))
    }
}
