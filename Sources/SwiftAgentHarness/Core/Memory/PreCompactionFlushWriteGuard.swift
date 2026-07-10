import Foundation

/// Thrown by filesystem tools when an active pre-compaction flush write guard rejects a mutation.
struct PreCompactionFlushWriteToolError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Runtime write policy for the pre-compaction flush sub-agent (curated topics only; append-only).
enum PreCompactionFlushWriteGuard: Sendable {
    struct Policy: Sendable, Equatable {
        let manifestTopicFilenames: Set<String>
    }

    enum Violation: Error, Sendable, Equatable {
        case dailyStagingForbidden
        case contaminationPathForbidden
        case memoryIndexWriteFileForbidden
        case memoryIndexEditNotAppendOnly
        case memoryIndexEditInvalidSuffix
        case existingTopicWriteFileForbidden
        case existingTopicEditNotAppendOnly
        case newTopicInvalidFrontmatter

        var userMessage: String {
            switch self {
            case .dailyStagingForbidden:
                return "Pre-compaction flush cannot write daily staging files (YYYY-MM-DD.md)."
            case .contaminationPathForbidden:
                return "Pre-compaction flush cannot write to reserved memory artifacts."
            case .memoryIndexWriteFileForbidden:
                return "Pre-compaction flush cannot replace MEMORY.md; append one index line via edit_file."
            case .memoryIndexEditNotAppendOnly:
                return "MEMORY.md edits during flush must be append-only."
            case .memoryIndexEditInvalidSuffix:
                return "MEMORY.md append must be a single one-line index hook."
            case .existingTopicWriteFileForbidden:
                return "Existing curated topic files are append-only during flush; use edit_file."
            case .existingTopicEditNotAppendOnly:
                return "Edits to existing curated topic files must append content only."
            case .newTopicInvalidFrontmatter:
                return "New topic files require valid YAML frontmatter (name, description, type)."
            }
        }
    }

    static func validateWriteFile(
        basename: String,
        content: String,
        policy: Policy
    ) -> Result<Void, Violation> {
        if AgentMemoryStore.isDailyFilename(basename) {
            return .failure(.dailyStagingForbidden)
        }
        if basename == "MEMORY.md" {
            return .failure(.memoryIndexWriteFileForbidden)
        }
        if isContaminationBasename(basename) {
            return .failure(.contaminationPathForbidden)
        }
        if policy.manifestTopicFilenames.contains(basename) {
            return .failure(.existingTopicWriteFileForbidden)
        }
        guard MemoryTopicFrontmatterParser.parse(from: content) != nil else {
            return .failure(.newTopicInvalidFrontmatter)
        }
        return .success(())
    }

    static func validateEditFile(
        basename: String,
        priorContent: String,
        newContent: String,
        policy: Policy
    ) -> Result<Void, Violation> {
        if AgentMemoryStore.isDailyFilename(basename) {
            return .failure(.dailyStagingForbidden)
        }
        if basename == "MEMORY.md" {
            return validateMemoryIndexEdit(priorContent: priorContent, newContent: newContent)
        }
        if isContaminationBasename(basename) {
            return .failure(.contaminationPathForbidden)
        }
        if policy.manifestTopicFilenames.contains(basename) {
            guard isAppendOnly(priorContent: priorContent, newContent: newContent) else {
                return .failure(.existingTopicEditNotAppendOnly)
            }
            return .success(())
        }
        guard MemoryTopicFrontmatterParser.parse(from: newContent) != nil else {
            return .failure(.newTopicInvalidFrontmatter)
        }
        guard isAppendOnly(priorContent: priorContent, newContent: newContent) else {
            return .failure(.existingTopicEditNotAppendOnly)
        }
        return .success(())
    }

    static func curatedTopicBasenames(fromAbsolutePaths paths: Set<String>, memoryDirectory: URL) -> [String] {
        paths.compactMap { absolutePath in
            let basename = URL(fileURLWithPath: absolutePath).lastPathComponent
            guard isReportableCuratedTopicBasename(basename) else { return nil }
            let fileURL = memoryDirectory.appendingPathComponent(basename)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                  MemoryTopicFrontmatterParser.parse(from: content) != nil else {
                return nil
            }
            return basename
        }
        .sorted()
    }

    static func isReportableCuratedTopicBasename(_ basename: String) -> Bool {
        guard !basename.isEmpty, basename != "MEMORY.md" else { return false }
        guard !AgentMemoryStore.isDailyFilename(basename) else { return false }
        guard !isContaminationBasename(basename) else { return false }
        return basename.hasSuffix(".md")
    }

    private static func isContaminationBasename(_ basename: String) -> Bool {
        DreamingContaminationGuard.isExcluded(filename: basename)
    }

    private static func validateMemoryIndexEdit(
        priorContent: String,
        newContent: String
    ) -> Result<Void, Violation> {
        guard isAppendOnly(priorContent: priorContent, newContent: newContent) else {
            return .failure(.memoryIndexEditNotAppendOnly)
        }
        let suffix = appendSuffix(priorContent: priorContent, newContent: newContent)
        guard !suffix.isEmpty else { return .success(()) }
        guard (try? AgentMemoryStore.validatedTruncatedIndexContent(newContent)) != nil else {
            return .failure(.memoryIndexEditInvalidSuffix)
        }
        let lines = suffix
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, isIndexHookLine(lines[0]) else {
            return .failure(.memoryIndexEditInvalidSuffix)
        }
        return .success(())
    }

    static func isAppendOnly(priorContent: String, newContent: String) -> Bool {
        if newContent == priorContent { return true }
        return newContent.hasPrefix(priorContent)
    }

    private static func appendSuffix(priorContent: String, newContent: String) -> String {
        if newContent.hasPrefix(priorContent) {
            return String(newContent.dropFirst(priorContent.count))
        }
        let prior = priorContent.trimmingCharacters(in: .newlines)
        let new = newContent.trimmingCharacters(in: .newlines)
        guard new.count > prior.count, new.hasPrefix(prior) else { return "" }
        return String(new.dropFirst(prior.count))
    }

    private static func isIndexHookLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("- ["), trimmed.contains("]("), trimmed.contains(".md") else { return false }
        return trimmed.count <= 200
    }
}
