import Foundation

/// Resolves post-compaction instruction sections from the nearest project instruction file.
public protocol CompactionReinjectionInstructionProviding: Sendable {
    func postCompactionInstructionContext(
        cwd: String,
        canonicalGitRoot: String?,
        config: ContextCompactionConfiguration
    ) async -> String?
}

public struct DefaultCompactionReinjectionInstructionProvider: CompactionReinjectionInstructionProviding {
    public init() {}

    public func postCompactionInstructionContext(
        cwd: String,
        canonicalGitRoot: String?,
        config: ContextCompactionConfiguration
    ) async -> String? {
        postCompactionInstructionContext(cwd: cwd, canonicalGitRoot: canonicalGitRoot, config: config, now: Date())
    }

    func postCompactionInstructionContext(
        cwd: String,
        canonicalGitRoot: String?,
        config: ContextCompactionConfiguration,
        now: Date
    ) -> String? {
        _ = canonicalGitRoot
        guard config.reinjectionInstructionSectionsEnabled else { return nil }

        let sectionNames = config.reinjectionInstructionSectionNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sectionNames.isEmpty else { return nil }

        guard let path = ProjectInstructionDiscovery.nearestPrimaryInstructionFile(cwd: cwd) else { return nil }

        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let scan = ProjectInstructionContentScanner.scan(raw)
        guard scan.isClean else { return nil }

        var foundNames: [String] = []
        var sections = ProjectInstructionSectionExtractor.extractSections(
            from: raw,
            sectionNames: sectionNames,
            foundNames: &foundNames
        )

        let isDefaultSections = ProjectInstructionSectionExtractor.matchesDefaultSectionSet(sectionNames)
        if sections.isEmpty, isDefaultSections {
            foundNames = []
            sections = ProjectInstructionSectionExtractor.extractSections(
                from: raw,
                sectionNames: ProjectInstructionSectionExtractor.legacyPostCompactionSectionNames,
                foundNames: &foundNames
            )
        }

        guard !sections.isEmpty else { return nil }

        let displayNames = foundNames.isEmpty ? sectionNames : foundNames
        let dateStamp = utcDateStamp(now)
        let combined = sections.joined(separator: "\n\n").replacingOccurrences(of: "YYYY-MM-DD", with: dateStamp)
        let maxChars = max(0, config.reinjectionInstructionSectionMaxCharacters)
        let safeContent: String
        if maxChars > 0, combined.count > maxChars {
            safeContent = String(combined.prefix(maxChars)) + "\n...[truncated]..."
        } else {
            safeContent = combined
        }

        let prose = isDefaultSections
            ? "Session was just compacted. The conversation summary above is a hint, NOT a substitute for your startup sequence. Run your Session Startup sequence — read the required files before responding to the user."
            : "Session was just compacted. The conversation summary above is a hint, NOT a substitute for your full startup sequence. Re-read the sections injected below (\(displayNames.joined(separator: ", "))) and follow your configured startup procedure before responding to the user."

        let sectionLabel = isDefaultSections
            ? "Critical rules from AGENTS.md:"
            : "Injected sections from AGENTS.md (\(displayNames.joined(separator: ", "))):"

        return """
[Context reinjection — post-compaction instruction refresh]

\(prose)

\(sectionLabel)

\(safeContent)
"""
    }

    private func utcDateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
