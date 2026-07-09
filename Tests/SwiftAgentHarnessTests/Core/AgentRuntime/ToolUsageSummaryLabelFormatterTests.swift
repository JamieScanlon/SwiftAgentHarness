import Testing
@testable import SwiftAgentHarness

@Suite("Tool usage summary label formatter")
struct ToolUsageSummaryLabelFormatterTests {
    @Test("empty input returns empty label")
    func emptyInput() {
        #expect(ToolUsageSummaryLabelFormatter.templateLabel(toolNames: []) == "")
        #expect(ToolUsageSummaryLabelFormatter.templateLabel(toolNames: ["", "  "]) == "")
    }

    @Test("single tool uses Ran prefix and count")
    func singleTool() {
        #expect(ToolUsageSummaryLabelFormatter.templateLabel(toolNames: ["read_file"]) == "Ran read_file ×1")
    }

    @Test("repeated tool aggregates count")
    func repeatedTool() {
        #expect(
            ToolUsageSummaryLabelFormatter.templateLabel(toolNames: ["read_file", "read_file", "read_file"])
            == "Ran read_file ×3"
        )
    }

    @Test("multiple tools preserve first-seen order")
    func multipleToolsFirstSeenOrder() {
        #expect(
            ToolUsageSummaryLabelFormatter.templateLabel(toolNames: ["bash", "read_file", "bash"])
            == "Ran bash ×2, read_file ×1"
        )
    }

    @Test("truncates to display budget by dropping trailing segments")
    func truncatesByDroppingTrailingSegments() {
        let label = ToolUsageSummaryLabelFormatter.templateLabel(
            toolNames: ["alpha_tool", "beta_tool", "gamma_tool", "delta_tool"]
        )
        #expect(label.count <= 30)
        #expect(label.hasPrefix("Ran "))
        #expect(label.contains("alpha_tool ×1"))
        #expect(!label.contains("delta_tool"))
    }

    @Test("truncates long single segment with ellipsis")
    func truncatesLongSingleSegment() {
        let label = ToolUsageSummaryLabelFormatter.templateLabel(
            toolNames: ["very_long_tool_name_that_exceeds_budget"]
        )
        #expect(label.count <= 30)
        #expect(label.hasSuffix("…"))
        #expect(label.hasPrefix("Ran "))
    }
}
