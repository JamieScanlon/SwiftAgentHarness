//
//  Parse and validate `plan.md` task lines (`[marker] id:<uuid> - description`).
//

import Foundation

/// Parsed `# Plan` / `## Goal` / `## Notes` / `## Tasks` document (canonical tool output).
public struct ParsedPlanDocument: Sendable, Equatable {
    public let overview: String
    public let goal: String
    public let notes: String
    public let tasks: [PlanTaskInput]

    public init(overview: String, goal: String, notes: String = "", tasks: [PlanTaskInput]) {
        self.overview = overview
        self.goal = goal
        self.notes = notes
        self.tasks = tasks
    }
}

public enum PlanMarkdownParser {
    /// Matches one task line: optional list marker, bracket status, `id:uuid`, ` - `, rest is description.
    public static let taskLineWithIDRegex = try! NSRegularExpression(
        pattern: #"^(\s*(?:[-*]\s+)?)\[([^\]]+)\]\s+id:([0-9A-Fa-f-]{36})\s*-\s*(.*)$"#,
        options: [.anchorsMatchLines]
    )

    /// Line-oriented parse of canonical plan files written by ``AgentPlanToolProvider/renderPlanMarkdown``.
    public static func parseDocument(_ markdown: String) -> ParsedPlanDocument {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        enum Section { case none, plan, goal, notes, tasks }
        var section: Section = .none
        var overviewLines: [String] = []
        var goalLines: [String] = []
        var notesLines: [String] = []
        var taskSectionLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# Plan" {
                section = .plan
                continue
            }
            if trimmed == "## Goal" {
                section = .goal
                continue
            }
            if trimmed == "## Notes" {
                section = .notes
                continue
            }
            if trimmed == "## Tasks" {
                section = .tasks
                continue
            }
            switch section {
            case .plan:
                overviewLines.append(line)
            case .goal:
                goalLines.append(line)
            case .notes:
                notesLines.append(line)
            case .tasks:
                taskSectionLines.append(line)
            case .none:
                break
            }
        }

        let overview = overviewLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = goalLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notesLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var tasks = parseTaskLines(in: taskSectionLines.joined(separator: "\n"))
        if tasks.isEmpty {
            tasks = parseTaskLines(in: markdown)
        }
        return ParsedPlanDocument(overview: overview, goal: goal, notes: notes, tasks: tasks)
    }

    /// Extracts task rows from arbitrary markdown (e.g. full file); order preserved.
    public static func parseTaskLines(in markdown: String) -> [PlanTaskInput] {
        let ns = markdown as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = taskLineWithIDRegex.matches(in: markdown, options: [], range: range)
        var out: [PlanTaskInput] = []
        out.reserveCapacity(matches.count)
        for m in matches where m.numberOfRanges >= 5 {
            let inner = ns.substring(with: m.range(at: 2))
            let idString = ns.substring(with: m.range(at: 3))
            let desc = ns.substring(with: m.range(at: 4))
            guard let id = UUID(uuidString: idString) else { continue }
            guard let status = planTaskStatus(fromBracketInner: inner) else { continue }
            out.append(PlanTaskInput(id: id, description: desc, status: status))
        }
        return out
    }

    static func planTaskStatus(fromBracketInner innerRaw: String) -> PlanTaskStatus? {
        let inner = innerRaw.trimmingCharacters(in: .whitespaces)
        switch inner {
        case "/":
            return .complete
        case "x", "X":
            return .blocked
        case "~":
            return .inProgress
        case "", " ":
            return .notStarted
        default:
            return nil
        }
    }
}
