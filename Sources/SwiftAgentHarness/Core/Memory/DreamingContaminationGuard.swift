import Foundation

/// Denylist for dreaming candidates so diary / index / machine-state artifacts never promote.
enum DreamingContaminationGuard: Sendable {
    private static let reservedBasenames: Set<String> = [
        "memory.md",
        "dreams.md",
        "recalls.jsonl",
        "promotions.jsonl",
        "last-deep.json",
    ]

    /// Returns true when `filename` must not be staged or promoted by dreaming.
    static func isExcluded(filename: String) -> Bool {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/").map(String.init)
        if parts.contains(where: { $0 == ".dreams" }) {
            return true
        }

        let basename = (parts.last ?? normalized).lowercased()
        return reservedBasenames.contains(basename)
    }
}
