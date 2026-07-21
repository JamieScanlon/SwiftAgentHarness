import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PlanMarkdownParser")
struct PlanMarkdownParserTests {

    @Test("parseTaskLines extracts id, status, and description for all four statuses")
    func parsesAllStatuses() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let d = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let md = """
        [ ] id:\(a.uuidString) - not started
        [~] id:\(b.uuidString) - in progress
        [x] id:\(c.uuidString) - done
        [!] id:\(d.uuidString) - blocked
        """
        let tasks = PlanMarkdownParser.parseTaskLines(in: md)
        #expect(tasks.count == 4)
        #expect(tasks[0] == PlanTaskInput(id: a, description: "not started", status: .notStarted))
        #expect(tasks[1] == PlanTaskInput(id: b, description: "in progress", status: .inProgress))
        #expect(tasks[2] == PlanTaskInput(id: c, description: "done", status: .complete))
        #expect(tasks[3] == PlanTaskInput(id: d, description: "blocked", status: .blocked))
    }

    @Test("parseTaskLines accepts legacy [/] as complete")
    func parsesLegacySlashComplete() {
        let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let md = "[/] id:\(id.uuidString) - legacy done"
        let tasks = PlanMarkdownParser.parseTaskLines(in: md)
        #expect(tasks == [PlanTaskInput(id: id, description: "legacy done", status: .complete)])
    }

    @Test("migrateLegacyMarkersIfNeeded rewrites [/] and old [x]-blocked to new markers")
    func migrateLegacyVocabulary() {
        let done = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let blocked = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let md = """
        # Plan
        Ov

        ## Goal
        G

        ## Notes
        N

        ## Tasks
        [/] id:\(done.uuidString) - done
        [x] id:\(blocked.uuidString) - blocked
        """
        #expect(PlanMarkdownParser.usesLegacyCompleteMarker(md))
        let migrated = PlanMarkdownParser.migrateLegacyMarkersIfNeeded(md)
        #expect(!PlanMarkdownParser.usesLegacyCompleteMarker(migrated))
        let doc = PlanMarkdownParser.parseDocument(migrated)
        #expect(doc.tasks.count == 2)
        #expect(doc.tasks[0] == PlanTaskInput(id: done, description: "done", status: .complete))
        #expect(doc.tasks[1] == PlanTaskInput(id: blocked, description: "blocked", status: .blocked))
        #expect(migrated.contains("[x] id:\(done.uuidString)"))
        #expect(migrated.contains("[!] id:\(blocked.uuidString)"))
    }

    @Test("parseTaskLines handles list bullet prefix")
    func parsesBulletPrefix() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let md = "- [~] id:\(id.uuidString) - with bullet"
        let tasks = PlanMarkdownParser.parseTaskLines(in: md)
        #expect(tasks == [PlanTaskInput(id: id, description: "with bullet", status: .inProgress)])
    }

    @Test("parseTaskLines keeps description after first ' - ' (hyphens in description)")
    func descriptionWithHyphens() {
        let id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let md = "[ ] id:\(id.uuidString) - part one - part two - three"
        let tasks = PlanMarkdownParser.parseTaskLines(in: md)
        #expect(tasks.count == 1)
        #expect(tasks[0].description == "part one - part two - three")
    }

    @Test("parseTaskLines accepts uppercase UUID in file")
    func uppercaseUUID() {
        let canonical = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let md = "[x] id:\(canonical.uppercased()) - done"
        let tasks = PlanMarkdownParser.parseTaskLines(in: md)
        #expect(tasks.count == 1)
        #expect(tasks[0].id == UUID(uuidString: canonical.lowercased()))
        #expect(tasks[0].status == .complete)
    }

    @Test("parseDocument extracts overview and goal sections")
    func parseSections() {
        let t = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let md = """
        # Plan
        Line one
        Line two

        ## Goal
        Outcome here.

        ## Tasks
        [ ] id:\(t.uuidString) - only task
        """
        let doc = PlanMarkdownParser.parseDocument(md)
        #expect(doc.overview == "Line one\nLine two")
        #expect(doc.goal == "Outcome here.")
        #expect(doc.notes.isEmpty)
        #expect(doc.tasks.count == 1)
        #expect(doc.tasks[0].id == t)
    }

    @Test("parseDocument extracts ## Notes between Goal and Tasks")
    func parseNotesSection() {
        let t = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let md = """
        # Plan
        Ov

        ## Goal
        G

        ## Notes
        Path: /proj
        Docs: https://example.com

        ## Tasks
        [ ] id:\(t.uuidString) - task
        """
        let doc = PlanMarkdownParser.parseDocument(md)
        #expect(doc.overview == "Ov")
        #expect(doc.goal == "G")
        #expect(doc.notes.contains("/proj"))
        #expect(doc.notes.contains("https://example.com"))
        #expect(doc.tasks.count == 1)
    }

    @Test("renderPlanMarkdown then parseDocument round-trips tasks and sections")
    func roundTripRenderParse() {
        let u1 = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let u2 = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let tasks = [
            PlanTaskInput(id: u1, description: "First", status: .notStarted),
            PlanTaskInput(id: u2, description: "Second", status: .complete),
        ]
        let rendered = AgentPlanToolProvider.renderPlanMarkdown(
            overview: "My overview",
            goal: "My goal",
            notes: "My notes",
            tasks: tasks
        )
        let doc = PlanMarkdownParser.parseDocument(rendered)
        #expect(doc.overview == "My overview")
        #expect(doc.goal == "My goal")
        #expect(doc.notes == "My notes")
        #expect(doc.tasks == tasks)
    }

    @Test("parseTaskLines skips lines with unknown bracket marker")
    func skipsUnknownMarker() {
        let id = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let md = "[?] id:\(id.uuidString) - unclear"
        #expect(PlanMarkdownParser.parseTaskLines(in: md).isEmpty)
    }

    @Test("round-trip with default placeholder overview and goal")
    func roundTripPlaceholders() {
        let u = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let tasks = [PlanTaskInput(id: u, description: "T", status: .blocked)]
        let rendered = AgentPlanToolProvider.renderPlanMarkdown(overview: nil, goal: nil, notes: nil, tasks: tasks)
        let doc = PlanMarkdownParser.parseDocument(rendered)
        #expect(doc.overview == "_Describe the plan here._")
        #expect(doc.goal == "_Describe the desired outcome._")
        #expect(doc.notes == "_No notes yet._")
        #expect(doc.tasks == tasks)
    }
}
