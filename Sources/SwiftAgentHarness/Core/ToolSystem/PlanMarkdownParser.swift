//
//  Parse and validate `plan.md` task lines (`[marker] id:<uuid> - description`).
//

import EasyJSON
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

/// Per-status tallies for plan tasks (tool metadata + REST).
public struct PlanTaskCounts: Codable, Sendable, Equatable {
    public let notStarted: Int
    public let inProgress: Int
    public let complete: Int
    public let blocked: Int
    public let total: Int

    public init(notStarted: Int, inProgress: Int, complete: Int, blocked: Int) {
        self.notStarted = notStarted
        self.inProgress = inProgress
        self.complete = complete
        self.blocked = blocked
        self.total = notStarted + inProgress + complete + blocked
    }

    public static func from(tasks: [PlanTaskInput]) -> PlanTaskCounts {
        var notStarted = 0
        var inProgress = 0
        var complete = 0
        var blocked = 0
        for task in tasks {
            switch task.status {
            case .notStarted: notStarted += 1
            case .inProgress: inProgress += 1
            case .complete: complete += 1
            case .blocked: blocked += 1
            }
        }
        return PlanTaskCounts(
            notStarted: notStarted,
            inProgress: inProgress,
            complete: complete,
            blocked: blocked
        )
    }
}

/// Structured plan view shared by plan-tool `ToolResult.metadata` and `GET …/plan`.
public struct PlanWireSnapshot: Sendable, Equatable {
    public let exists: Bool
    public let overview: String
    public let goal: String
    public let notes: String
    public let tasks: [PlanTaskInput]
    public let counts: PlanTaskCounts
    public let inProgressTaskId: UUID?

    public init(
        exists: Bool,
        overview: String,
        goal: String,
        notes: String,
        tasks: [PlanTaskInput],
        counts: PlanTaskCounts,
        inProgressTaskId: UUID?
    ) {
        self.exists = exists
        self.overview = overview
        self.goal = goal
        self.notes = notes
        self.tasks = tasks
        self.counts = counts
        self.inProgressTaskId = inProgressTaskId
    }

    public static let missing = PlanWireSnapshot(
        exists: false,
        overview: "",
        goal: "",
        notes: "",
        tasks: [],
        counts: PlanTaskCounts(notStarted: 0, inProgress: 0, complete: 0, blocked: 0),
        inProgressTaskId: nil
    )

    public static func from(document: ParsedPlanDocument, exists: Bool = true) -> PlanWireSnapshot {
        let tasks = document.tasks
        return PlanWireSnapshot(
            exists: exists,
            overview: document.overview,
            goal: document.goal,
            notes: document.notes,
            tasks: tasks,
            counts: .from(tasks: tasks),
            inProgressTaskId: tasks.first(where: { $0.status == .inProgress })?.id
        )
    }

    public static func from(markdown: String, exists: Bool = true) -> PlanWireSnapshot {
        from(document: PlanMarkdownParser.parseDocument(markdown), exists: exists)
    }

    /// EasyJSON fragment: `exists`, `tasks`, `counts`, `inProgressTaskId`, and non-empty section bodies.
    public func metadataFragment() -> [String: JSON] {
        var fragment: [String: JSON] = [
            "exists": .boolean(exists),
            "tasks": .array(tasks.map(Self.taskJSON)),
            "counts": .object([
                "notStarted": .integer(counts.notStarted),
                "inProgress": .integer(counts.inProgress),
                "complete": .integer(counts.complete),
                "blocked": .integer(counts.blocked),
                "total": .integer(counts.total),
            ]),
        ]
        if !overview.isEmpty {
            fragment["overview"] = .string(overview)
        }
        if !goal.isEmpty {
            fragment["goal"] = .string(goal)
        }
        if !notes.isEmpty {
            fragment["notes"] = .string(notes)
        }
        if let inProgressTaskId {
            fragment["inProgressTaskId"] = .string(inProgressTaskId.uuidString)
        }
        return fragment
    }

    private static func taskJSON(_ task: PlanTaskInput) -> JSON {
        .object([
            "id": .string(task.id.uuidString),
            "description": .string(task.description),
            "status": .string(task.status.rawValue),
        ])
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
        case "x", "X":
            return .complete
        case "!":
            return .blocked
        case "/":
            // Legacy complete marker (pre-PL8); still accepted for one release.
            return .complete
        case "~":
            return .inProgress
        case "", " ":
            return .notStarted
        default:
            return nil
        }
    }

    /// Legacy mapping used only when migrating files that still contain `[/]` complete markers.
    static func planTaskStatusLegacy(fromBracketInner innerRaw: String) -> PlanTaskStatus? {
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

    /// `true` when any `id:` task line still uses the legacy complete marker `[/]`.
    public static func usesLegacyCompleteMarker(_ markdown: String) -> Bool {
        let ns = markdown as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = taskLineWithIDRegex.matches(in: markdown, options: [], range: range)
        for m in matches where m.numberOfRanges >= 5 {
            let inner = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if inner == "/" {
                return true
            }
        }
        return false
    }

    /// When markdown still uses `[/]` for complete, rewrite via legacy parse → canonical render
    /// (`[/]`→`[x]`, previous `[x]`→`[!]`). Returns unchanged markdown when already on the new vocabulary.
    public static func migrateLegacyMarkersIfNeeded(_ markdown: String) -> String {
        guard usesLegacyCompleteMarker(markdown) else {
            return markdown
        }
        let doc = parseDocumentUsingLegacyStatus(markdown)
        return AgentPlanToolProvider.renderPlanMarkdown(
            overview: doc.overview.isEmpty ? nil : doc.overview,
            goal: doc.goal.isEmpty ? nil : doc.goal,
            notes: doc.notes.isEmpty ? nil : doc.notes,
            tasks: doc.tasks
        )
    }

    private static func parseDocumentUsingLegacyStatus(_ markdown: String) -> ParsedPlanDocument {
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

        var tasks = parseTaskLinesLegacy(in: taskSectionLines.joined(separator: "\n"))
        if tasks.isEmpty {
            tasks = parseTaskLinesLegacy(in: markdown)
        }
        return ParsedPlanDocument(overview: overview, goal: goal, notes: notes, tasks: tasks)
    }

    private static func parseTaskLinesLegacy(in markdown: String) -> [PlanTaskInput] {
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
            guard let status = planTaskStatusLegacy(fromBracketInner: inner) else { continue }
            out.append(PlanTaskInput(id: id, description: desc, status: status))
        }
        return out
    }
}
