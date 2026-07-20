import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ProjectInstructionSectionExtractor")
struct ProjectInstructionSectionExtractorTests {
    @Test("Extracts H2 sections case-insensitively")
    func h2Extraction() {
        let content = """
        # Root
        ## Session Startup
        Read AGENTS.md first.
        ## Red Lines
        Never force push main.
        """
        var found: [String] = []
        let sections = ProjectInstructionSectionExtractor.extractSections(
            from: content,
            sectionNames: ["Session Startup", "Red Lines"],
            foundNames: &found
        )
        #expect(sections.count == 2)
        #expect(sections[0].contains("Read AGENTS.md first."))
        #expect(sections[1].contains("Never force push main."))
        #expect(found == ["Session Startup", "Red Lines"])
    }

    @Test("Extracts H3 subsection nested inside H2")
    func h3Nested() {
        let content = """
        ## Session Startup
        Top line.
        ### Sub step
        Nested detail.
        ## Red Lines
        Rule.
        """
        var found: [String] = []
        let sections = ProjectInstructionSectionExtractor.extractSections(
            from: content,
            sectionNames: ["Session Startup"],
            foundNames: &found
        )
        #expect(sections.count == 1)
        #expect(sections[0].contains("### Sub step"))
        #expect(sections[0].contains("Nested detail."))
        #expect(sections[0].contains("Rule.") == false)
    }

    @Test("Headings inside fenced code blocks are ignored")
    func codeBlockHeadingsIgnored() {
        let content = """
        ## Session Startup
        Before code.
        ```
        ## Red Lines
        fake heading
        ```
        After code.
        """
        var found: [String] = []
        let sections = ProjectInstructionSectionExtractor.extractSections(
            from: content,
            sectionNames: ["Session Startup"],
            foundNames: &found
        )
        #expect(sections.count == 1)
        #expect(sections[0].contains("fake heading"))
        #expect(sections[0].contains("After code."))
    }

    @Test("Legacy section names extract when requested explicitly")
    func legacyNamesDirect() {
        let content = """
        ## Every Session
        Legacy startup.
        ## Safety
        Legacy safety.
        """
        var found: [String] = []
        let sections = ProjectInstructionSectionExtractor.extractSections(
            from: content,
            sectionNames: ProjectInstructionSectionExtractor.legacyPostCompactionSectionNames,
            foundNames: &found
        )
        #expect(sections.count == 2)
        #expect(sections[0].contains("Legacy startup."))
    }

    @Test("Default section set matcher is order-independent")
    func defaultSetMatcher() {
        #expect(ProjectInstructionSectionExtractor.matchesDefaultSectionSet(["Session Startup", "Red Lines"]))
        #expect(ProjectInstructionSectionExtractor.matchesDefaultSectionSet(["red lines", "session startup"]))
        #expect(ProjectInstructionSectionExtractor.matchesDefaultSectionSet(["Custom"]) == false)
    }

    @Test("New default headings win when both legacy and default exist")
    func newNamesPrecedenceWhenBothPresent() {
        let content = """
        ## Every Session
        Old startup.
        ## Session Startup
        New startup.
        ## Safety
        Old safety.
        ## Red Lines
        New safety.
        """
        var found: [String] = []
        let sections = ProjectInstructionSectionExtractor.extractSections(
            from: content,
            sectionNames: ProjectInstructionSectionExtractor.defaultPostCompactionSectionNames,
            foundNames: &found
        )
        #expect(sections.count == 2)
        #expect(sections[0].contains("New startup."))
        #expect(sections[0].contains("Old startup.") == false)
        #expect(sections[1].contains("New safety."))
    }
}
