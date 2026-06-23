//
//  Server-local plan under ~/.swiftAgentHarness/conversations/<id>/plan.md
//

import Foundation

/// Reads and manages the per-conversation `plan.md.
public enum AgentPlanStore {
    public static let planFilename = "plan.md"

    /// Absolute path string for system prompts (server home).
    public static func planPathString(for conversationID: UUID) -> String {
        planURL(for: conversationID).path
    }

    public static func planURL(for conversationID: UUID) -> URL {
        FileManager.default.sahHomeDirectory
            .appendingPathComponent(".swiftAgentHarness", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
            .appendingPathComponent(planFilename, isDirectory: false)
    }

    public static func conversationDirectoryURL(for conversationID: UUID) -> URL {
        planURL(for: conversationID).deletingLastPathComponent()
    }

    /// Deletes `~/.swiftAgentHarness/conversations/<id>/` and all contents. No-op if missing.
    @discardableResult
    public static func removeConversationDirectory(for conversationID: UUID) -> Bool {
        let url = conversationDirectoryURL(for: conversationID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return true
        }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Creates `~/.swiftAgentHarness/conversations/<id>/` for a new plan/agent conversation. Does not create `plan.md` until tools write it.
    public static func ensureConversationDirectory(for conversationID: UUID) throws {
        let dir = conversationDirectoryURL(for: conversationID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// `true` when the agent build loop should inject the ephemeral “continue” user line (see ``AgentPlanParser``).
    /// Missing or unreadable file ⇒ **false**.
    public static func shouldEmitEphemeralAgentBuildContinuation(for conversationID: UUID) -> Bool {
        evaluateEphemeralAgentBuildContinuation(for: conversationID).shouldEmit
    }

    /// Same rules as ``shouldEmitEphemeralAgentBuildContinuation(for:)``, with a short reason when continuation is off.
    public static func evaluateEphemeralAgentBuildContinuation(for conversationID: UUID) -> EphemeralAgentBuildContinuationDecision {
        let url = planURL(for: conversationID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return EphemeralAgentBuildContinuationDecision(
                shouldEmit: false,
                reasonIfNotEmit: "plan.md not found for this conversation"
            )
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return EphemeralAgentBuildContinuationDecision(
                shouldEmit: false,
                reasonIfNotEmit: "plan.md exists but could not be read as UTF-8 text"
            )
        }
        return AgentPlanParser.evaluateEphemeralAgentBuildContinuation(in: text)
    }

    /// Raw `plan.md` contents when the file exists and is readable; otherwise `nil`.
    public static func readPlanText(for conversationID: UUID) -> String? {
        let url = planURL(for: conversationID)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }
}

/// Result of evaluating whether the harness should inject an ephemeral “continue” user line for agent build.
public struct EphemeralAgentBuildContinuationDecision: Sendable, Equatable {
    public let shouldEmit: Bool
    /// Set when ``shouldEmit`` is `false` (for logging and diagnostics).
    public let reasonIfNotEmit: String?

    public init(shouldEmit: Bool, reasonIfNotEmit: String?) {
        self.shouldEmit = shouldEmit
        self.reasonIfNotEmit = reasonIfNotEmit
    }
}

/// Parses markdown task lines for continuation heuristics: `- [ ]`, `* [ ]`, bare `[ ]`, and `[/]`, `[x]`, `[~]`.
public enum AgentPlanParser {
    private static let taskLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*]\s+)?\[([^\]]+)\]"#,
        options: [.anchorsMatchLines]
    )

    /// Ephemeral build continuation when there is active work: at least one task not done (`[/]`) and not blocked (`[x]`),
    /// and **no** blocked line. `[~]` (in progress) and `[ ]` (not started) count as needing continuation.
    /// Any `[x]` anywhere in the plan stops the agent build loop until the user resolves it.
    public static func shouldEmitEphemeralAgentBuildContinuation(in markdown: String) -> Bool {
        evaluateEphemeralAgentBuildContinuation(in: markdown).shouldEmit
    }

    /// Rules: need at least one checkbox task line; no `[x]` anywhere; at least one non-done, non-blocked task.
    public static func evaluateEphemeralAgentBuildContinuation(in markdown: String) -> EphemeralAgentBuildContinuationDecision {
        let ns = markdown as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = taskLineRegex.matches(in: markdown, options: [], range: range)
        guard !matches.isEmpty else {
            return EphemeralAgentBuildContinuationDecision(
                shouldEmit: false,
                reasonIfNotEmit: "plan has no checkbox task lines matching harness rules (e.g. `- [ ]`, `[ ]`, `[~]`)"
            )
        }

        var hasBlocked = false
        var hasOpen = false
        for m in matches where m.numberOfRanges >= 2 {
            let inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if inner == "/" {
                continue
            }
            if inner.lowercased() == "x" {
                hasBlocked = true
                continue
            }
            hasOpen = true
        }
        if hasBlocked {
            return EphemeralAgentBuildContinuationDecision(
                shouldEmit: false,
                reasonIfNotEmit: "plan contains at least one blocked [x] task line (clear or re-mark before auto-continue)"
            )
        }
        if !hasOpen {
            return EphemeralAgentBuildContinuationDecision(
                shouldEmit: false,
                reasonIfNotEmit: "no open or in-progress tasks (all lines are complete [/] only)"
            )
        }
        return EphemeralAgentBuildContinuationDecision(shouldEmit: true, reasonIfNotEmit: nil)
    }

    /// `true` when any checkbox task line uses the blocked marker `[x]` (same rules as ``evaluateEphemeralAgentBuildContinuation``).
    public static func hasBlockedTaskLine(in markdown: String) -> Bool {
        let ns = markdown as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = taskLineRegex.matches(in: markdown, options: [], range: range)
        for m in matches where m.numberOfRanges >= 2 {
            let inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if inner.lowercased() == "x" {
                return true
            }
        }
        return false
    }

    /// One-line summary of checkbox task lines for harness continuations.
    public static func planProgressSummaryLine(in markdown: String) -> String {
        let ns = markdown as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = taskLineRegex.matches(in: markdown, options: [], range: range)
        guard !matches.isEmpty else {
            return "Plan tasks: none detected in plan.md."
        }
        var open = 0
        var inProgress = 0
        var done = 0
        var blocked = 0
        for m in matches where m.numberOfRanges >= 2 {
            let inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
            if inner == "/" {
                done += 1
            } else if inner == "x" {
                blocked += 1
            } else if inner == "~" {
                inProgress += 1
            } else {
                open += 1
            }
        }
        return "Plan task lines — open: \(open), in progress: \(inProgress), complete: \(done), blocked: \(blocked)."
    }

    /// UTF-8-safe prefix of `markdown` for injection into user continuations.
    public static func truncatedPlanExcerpt(from markdown: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else {
            return ""
        }
        if markdown.count <= maxCharacters {
            return markdown
        }
        let end = markdown.index(markdown.startIndex, offsetBy: maxCharacters)
        return String(markdown[..<end]) + "\n\n…(plan excerpt truncated for context limit)"
    }

    /// `true` when `plan.md` has at least one task line and every task line is complete (`[/]`), with no blocked (`[x]`) lines.
    public static func isPlanFullyComplete(in markdown: String) -> Bool {
        let ns = markdown as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = taskLineRegex.matches(in: markdown, options: [], range: range)
        guard !matches.isEmpty else {
            return false
        }
        for m in matches where m.numberOfRanges >= 2 {
            let inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if inner.lowercased() == "x" {
                return false
            }
            if inner != "/" {
                return false
            }
        }
        return true
    }
}
