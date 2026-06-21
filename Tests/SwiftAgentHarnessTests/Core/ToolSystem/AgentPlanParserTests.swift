import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("AgentPlanParser")
struct AgentPlanParserTests {

    @Test("Empty or no task lines does not emit")
    func emptyDoesNotEmit() {
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "") == false)
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "Just notes\n\nNo task lines.") == false)
    }

    @Test("Open [ ] with some [/] still emits")
    func openWithSomeDoneEmits() {
        let md = """
        - [ ] First
        - [/] Done
        """
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: md) == true)
    }

    @Test("[x] blocks ephemeral continuation")
    func blockedDoesNotEmit() {
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "- [x] Fix this") == false)
    }

    @Test("[x] mixed with [ ] still does not emit")
    func anyBlockedStopsEmit() {
        let md = """
        - [ ] Todo
        - [x] Blocked
        """
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: md) == false)
    }

    @Test("All [/] does not emit")
    func allSlashDoesNotEmit() {
        let md = """
        - [/] A
        - [/] B
        """
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: md) == false)
    }

    @Test("[~] in-progress still emits")
    func inProgressEmits() {
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "[~] id:abc - doing") == true)
    }

    @Test("Plan task line with id: prefix still emits when open")
    func planFormatWithIdEmits() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let line = "[ ] id:\(id.uuidString) - todo"
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: line) == true)
    }

    @Test("Asterisk bullets parse like dashes")
    func asteriskBullets() {
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "* [ ] todo") == true)
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "* [/] done") == false)
    }

    @Test("Bare bracket task lines (no - or * prefix) are recognized")
    func bareBracketTasks() {
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "[ ] todo") == true)
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "[x] blocked") == false)
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "[/] done only") == false)
    }

    @Test("Sample plan with [x] and [/] does not emit (blocked markers present)")
    func samplePlanWithBlockedDoesNotEmit() {
        let md = """
        # Discord Communication Bot - Project Plan

        ## Phase 1: Setup and Configuration
        [x] Verify environment variables are correct
        [x] Install dependencies (completed ✓)
        [/] Start bot server with tunneling (server running on port 3000, localtunnel set up)
        [/] Capture ngrok public URL (got https://icy-teams-walk.loca.lt via localtunnel)

        ## Phase 2: Discord Registration
        [ ] Register slash commands with Discord
        [ ] Add bot to Discord server via invite link
        [ ] Verify bot appears in Discord
        """
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: md) == false)
    }

    @Test("Only [ ] and [/] without [x] still emits when [ ] remains")
    func openItemsWithoutBlockerEmits() {
        let md = """
        - [/] Done step
        - [ ] Still todo
        """
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: md) == true)
    }

    @Test("[X] uppercase blocks like [x]")
    func uppercaseXBlocks() {
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "- [X] Blocked") == false)
    }

    @Test("Only unchecked [ ] lines with no done or blocked still emits")
    func onlyOpenCheckboxesEmit() {
        let md = """
        - [ ] One
        - [ ] Two
        """
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: md) == true)
    }

    @Test("Indented and spaced task lines still parse")
    func indentedAndInnerWhitespace() {
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "  - [ ] Indented") == true)
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "- [ x ] spaces around x blocks") == false)
    }

    @Test("hasBlockedTaskLine mirrors [x] detection")
    func hasBlockedTaskLine() {
        #expect(AgentPlanParser.hasBlockedTaskLine(in: "") == false)
        #expect(AgentPlanParser.hasBlockedTaskLine(in: "- [ ] Open") == false)
        #expect(AgentPlanParser.hasBlockedTaskLine(in: "- [x] Blocked") == true)
        #expect(AgentPlanParser.hasBlockedTaskLine(in: "- [X] Blocked") == true)
        #expect(AgentPlanParser.hasBlockedTaskLine(in: "- [ ] A\n- [/] B") == false)
        #expect(AgentPlanParser.hasBlockedTaskLine(in: "Some text\n[x] bare blocked") == true)
    }

    @Test("Only [x] and [/] with no open task line does not emit")
    func blockedAndDoneOnlyDoesNotEmit() {
        let md = """
        - [/] Finished
        - [x] Waiting on user
        """
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: md) == false)
    }

    @Test("Nonstandard markers like [?] count as open and emit")
    func unknownMarkerCountsAsOpen() {
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "- [?] unclear") == true)
    }

    @Test("Markdown link line can be mistaken for a task (documents regex behavior)")
    func linkLineLooksLikeCheckbox() {
        #expect(AgentPlanParser.shouldEmitEphemeralAgentBuildContinuation(in: "[label](https://example.com)") == true)
    }

    @Test("planProgressSummaryLine counts task markers")
    func progressSummary() {
        let md = """
        - [ ] Open
        - [~] Doing
        - [/] Done
        - [x] Blocked
        """
        let s = AgentPlanParser.planProgressSummaryLine(in: md)
        #expect(s.contains("open: 1"))
        #expect(s.contains("in progress: 1"))
        #expect(s.contains("complete: 1"))
        #expect(s.contains("blocked: 1"))
    }

    @Test("truncatedPlanExcerpt short-circuits when under limit")
    func excerptShort() {
        let t = AgentPlanParser.truncatedPlanExcerpt(from: "hello", maxCharacters: 100)
        #expect(t == "hello")
    }

    @Test("truncatedPlanExcerpt adds truncation notice when over limit")
    func excerptTruncated() {
        let t = AgentPlanParser.truncatedPlanExcerpt(from: "abcdefghij", maxCharacters: 4)
        #expect(t.hasPrefix("abcd"))
        #expect(t.contains("truncated"))
    }

    @Test("isPlanFullyComplete true only when all task lines are [/] and at least one exists")
    func fullyComplete() {
        #expect(AgentPlanParser.isPlanFullyComplete(in: "") == false)
        #expect(AgentPlanParser.isPlanFullyComplete(in: "- [ ] Open") == false)
        #expect(AgentPlanParser.isPlanFullyComplete(in: "- [/] A\n- [x] B") == false)
        #expect(AgentPlanParser.isPlanFullyComplete(in: "- [/] A\n- [/] B") == true)
    }
}

@Suite("AgentPlanStore")
struct AgentPlanStoreTests {

    @Test("Missing plan file does not emit continuation")
    func missingFileDoesNotEmit() throws {
        let id = UUID()
        try AgentPlanStore.ensureConversationDirectory(for: id)
        #expect(AgentPlanStore.shouldEmitEphemeralAgentBuildContinuation(for: id) == false)
        #expect(AgentPlanStore.removeConversationDirectory(for: id))
    }

    @Test("removeConversationDirectory deletes ~/.swiftAgentHarness/conversations/<id>/")
    func deleteRemovesDirectory() throws {
        let id = UUID()
        try AgentPlanStore.ensureConversationDirectory(for: id)
        let dir = AgentPlanStore.conversationDirectoryURL(for: id)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(AgentPlanStore.removeConversationDirectory(for: id))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(AgentPlanStore.removeConversationDirectory(for: id))
    }
}
