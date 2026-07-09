import Foundation

enum ToolUsageSummaryLabelFormatter {
    private static let displayBudget = 30

    /// Builds a deterministic display label such as `Ran read_file ×3, bash ×1`.
    /// Returns empty string when there are no tool names.
    static func templateLabel(toolNames: [String]) -> String {
        let normalized = toolNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return "" }

        var counts: [String: Int] = [:]
        var firstSeenOrder: [String] = []
        for name in normalized {
            if counts[name] == nil {
                firstSeenOrder.append(name)
            }
            counts[name, default: 0] += 1
        }

        var segments: [String] = []
        for name in firstSeenOrder {
            let count = counts[name] ?? 1
            segments.append("\(name) ×\(count)")
        }

        var label = "Ran " + segments.joined(separator: ", ")
        guard label.count > displayBudget else { return label }

        while segments.count > 1, label.count > displayBudget {
            segments.removeLast()
            label = "Ran " + segments.joined(separator: ", ")
        }

        if label.count <= displayBudget {
            return label
        }

        guard let last = segments.first else { return "Ran …" }
        let prefix = "Ran "
        let suffix = "…"
        let available = max(0, displayBudget - prefix.count - suffix.count)
        let trimmedName = String(last.prefix(available))
        return "\(prefix)\(trimmedName)\(suffix)"
    }
}
