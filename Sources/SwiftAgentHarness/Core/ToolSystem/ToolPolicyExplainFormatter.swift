import Foundation

enum ToolPolicyExplainFormatter {
    static func formatList(report: ToolPolicyExplainReport) -> String {
        let effective = report.rows.filter { $0.status == .effective }.map(\.toolName)
        if effective.isEmpty {
            return "No effective tools for mode profile `\(report.context.profileID)` (\(report.registeredToolCount) registered)."
        }
        return "Effective tools (\(effective.count)/\(report.registeredToolCount)):\n"
            + effective.map { "  \($0)" }.joined(separator: "\n")
    }

    static func format(report: ToolPolicyExplainReport, coherenceReport: ToolPolicyCoherenceReport? = nil) -> String {
        var lines: [String] = []
        lines.append("Tool policy explain")
        lines.append("  mode profile: \(report.context.profileID)")
        lines.append("  interaction mode: \(report.context.interactionMode.rawValue)")
        lines.append("  enableTools: \(report.context.enableTools)")
        lines.append("  enableAgents: \(report.context.enableAgents)")
        lines.append("  allowEscalatedTools: \(report.context.allowEscalatedTools)")
        if let trust = report.context.inputTrustClass {
            lines.append("  input trust: \(trust.rawValue)")
        }
        lines.append("")
        lines.append(
            "Summary: \(report.effectiveCount) effective, "
                + "\(report.approvalGatedCount) approval-gated, "
                + "\(report.blockedCount) blocked "
                + "(\(report.registeredToolCount) registered)"
        )
        lines.append("")

        let effective = report.rows.filter { $0.status == .effective }
        if !effective.isEmpty {
            lines.append("Effective (\(effective.count)):")
            for row in effective {
                lines.append("  \(row.toolName) [\(row.source.rawValue)]")
            }
            lines.append("")
        }

        let gated = report.rows.filter { $0.status == .approvalGated }
        if !gated.isEmpty {
            lines.append("Approval-gated (\(gated.count)):")
            for row in gated {
                lines.append(formatBlockedRow(row, context: report.context, indent: "  "))
            }
            lines.append("")
        }

        let blocked = report.rows.filter { $0.status == .blocked }
        if !blocked.isEmpty {
            lines.append("Blocked (\(blocked.count)):")
            for row in blocked {
                lines.append(formatBlockedRow(row, context: report.context, indent: "  "))
            }
            lines.append("")
        }

        if report.rows.count == 1, let row = report.rows.first {
            lines.append("Scope trace for `\(row.toolName)`:")
            lines.append(formatScopeTrace(row.scopeTrace, context: report.context, indent: "  "))
            if let appendix = row.gatingAppendix {
                lines.append("  Gating preview: \(appendix.reasonDescription)")
            }
            lines.append("")
        }

        lines.append(formatCoherenceSection(coherenceReport ?? ToolPolicyCoherenceReport(profileID: report.context.profileID, issues: [])))

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatCoherenceSection(_ report: ToolPolicyCoherenceReport) -> String {
        var lines: [String] = ["Policy coherence:"]
        if report.isClean {
            lines.append("  No coherence issues detected.")
            return lines.joined(separator: "\n")
        }

        func appendGroup(title: String, issues: [ToolPolicyCoherenceIssue]) {
            guard !issues.isEmpty else { return }
            lines.append("  \(title) (\(issues.count)):")
            for issue in issues {
                lines.append("    [\(issue.scope.displayLabel)] \(issue.ruleToken)")
                lines.append("      \(issue.detail)")
                lines.append("      fix-it: \(issue.fixItConfigKey(profileID: report.profileID))")
                if issue.kind == .shadowedAllow, !issue.shadowedBy.isEmpty {
                    lines.append("      shadowed by: \(issue.shadowedBy.joined(separator: ", "))")
                }
            }
        }

        appendGroup(title: "Unknown entries", issues: report.unknownEntries)
        appendGroup(title: "Shadowed allows", issues: report.shadowedAllows)
        appendGroup(title: "Empty groups", issues: report.emptyGroups)
        return lines.joined(separator: "\n")
    }

    private static func formatBlockedRow(
        _ row: ToolPolicyToolExplainRow,
        context: ToolPolicyExplainContext,
        indent: String
    ) -> String {
        var parts: [String] = ["\(indent)\(row.toolName) [\(row.source.rawValue)]"]
        if let scope = row.primaryScope {
            parts.append("\(indent)  scope: \(scope.displayLabel) (\(scope.rawValue))")
        }
        if let detail = row.primaryDetail {
            parts.append("\(indent)  reason: \(detail)")
        }
        if let matched = row.scopeTrace.compactMap({ item -> String? in
            if case .fail(_, _, let rule?) = item.verdict {
                return rule
            }
            return nil
        }).first {
            parts.append("\(indent)  matched: \(matched)")
        }
        if let fixIt = row.fixItConfigKey ?? row.primaryScope?.fixItConfigKey(profileID: context.profileID) {
            parts.append("\(indent)  fix-it: \(fixIt)")
        }
        if let blockReason = row.gatewayBlockReason {
            parts.append("\(indent)  blockReason: \(blockReason.rawValue)")
        }
        return parts.joined(separator: "\n")
    }

    private static func formatScopeTrace(
        _ trace: [(scope: ToolPolicyAvailabilityScope, verdict: ToolPolicyScopeVerdict)],
        context: ToolPolicyExplainContext,
        indent: String
    ) -> String {
        trace.map { item in
            let mark: String = switch item.verdict {
            case .pass: "pass"
            case .fail: "FAIL"
            case .gate: "GATE"
            }
            var line = "\(indent)\(mark) \(item.scope.displayLabel)"
            if let detail = ToolPolicyScopeVerdictFormatting.detailText(for: item.verdict) {
                line += " — \(detail)"
            }
            if case .fail = item.verdict {
                line += " (fix-it: \(item.scope.fixItConfigKey(profileID: context.profileID)))"
            }
            return line
        }.joined(separator: "\n")
    }
}
