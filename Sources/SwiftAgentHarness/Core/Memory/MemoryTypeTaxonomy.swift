import Foundation

enum MemoryTypeTaxonomy {
    static let whatNotToSavePrompt = """
Do NOT save:
- Code patterns, conventions, architecture, file paths, or project structure — these can be derived by reading the current project state.
- Git history, recent changes, or who-changed-what — `git log` / `git blame` are authoritative.
- Debugging solutions or fix recipes — the fix is in the code; the commit message has the context.
- Anything already documented in AGENTS.md or CLAUDE.md files.
- Ephemeral task details: in-progress work, temporary state, current conversation context.

These exclusions apply even when the user explicitly asks to save. If they ask you to save a PR list or activity summary, ask what was *surprising* or *non-obvious* about it — that is the part worth keeping.
"""

    static let driftGuardPrompt = """
## Before recommending from memory

A memory that names a specific function, file, or flag is a claim that it existed *when the memory was written*. It may have been renamed, removed, or never merged. Before recommending it:

- If the memory names a file path: check the file exists.
- If the memory names a function or flag: grep for it.
- If the user is about to act on your recommendation (not just asking about history), verify first.

"The memory says X exists" is not the same as "X exists now."

A memory that summarizes repo state (activity logs, architecture snapshots) is frozen in time. If the user asks about *recent* or *current* state, prefer `git log` or reading the code over recalling the snapshot.

If the user says to *ignore* or *not use* memory: proceed as if MEMORY.md were empty. Do not apply remembered facts, cite, compare against, or mention memory content.
"""

    static let sensitiveDataPrompt = """
Do not save protected attributes, government identifiers, credentials, health information, home addresses, or account passwords unless the user explicitly asks you to remember that specific item.
"""

    static let teamSensitiveDataPrompt = """
You MUST avoid saving sensitive data within shared team memories. For example, never save API keys or user credentials.
"""

    static let indexUsagePrompt = """
`MEMORY.md` is an index, not a memory. Each entry should be one line under ~150 characters: `- [Title](file.md) — one-line hook`. It has no frontmatter. Never write memory content directly into `MEMORY.md`.
"""

    static let twoStepWriteRulePrompt = """
Saving durable memory is two steps:
1. Write or append the full memory body to a typed topic `.md` file (YAML frontmatter with name, description, and type required).
2. Append exactly one one-line index hook to `MEMORY.md` linking to that topic file.
"""

    static let preCompactionFlushConstraintsPrompt = """
## Pre-compaction flush (curated promotion only)

Do NOT write daily staging files (`YYYY-MM-DD.md` or any date-named note). Pre-compaction flush promotes directly to curated typed topic files only.

Existing manifest topic files listed above are append-only: read them first, then append new sections at the end. Never replace or truncate existing curated content.

`MEMORY.md` is append-only for a single index line per new topic. Never use write_file on `MEMORY.md`; use edit_file to append one `- [Title](file.md) — hook` line at the end.

Turn 1 — issue all Read calls in parallel for every file you might update; turn 2 — issue all Write/Edit calls in parallel. Do not interleave reads and writes across multiple turns.
"""

    /// Capture-cheap staging: prefer today's daily note; reserve typed topics for curated durable entries.
    static let dailyCapturePrompt = """
## Capture vs curate

Prefer appending durable-but-not-yet-curated notes to today's daily staging file `YYYY-MM-DD.md` (e.g. today's date). Daily notes have no YAML frontmatter — append plain markdown sections.

Reserve typed topic files (`user` / `feedback` / `project` / `reference` with frontmatter) plus a one-line `MEMORY.md` index entry for curated durable memories you are ready to promote now. Do not write memory content into `MEMORY.md` itself.
"""

    static let persistenceDistinctionPrompt = """
Memory is for information that will be useful in *future* conversations. Do not save approach decisions to memory when a plan exists; do not save in-progress task lists to memory.
"""
}

enum MemoryIndexTruncator {
    static let maxLines = 200
    static let maxBytes = 25_000

    struct TruncationResult: Equatable {
        let text: String
        let capFired: String?
    }

    static func truncate(_ content: String) -> TruncationResult {
        var text = content
        var capFired: String?
        let lines = text.components(separatedBy: .newlines)
        if lines.count > maxLines {
            text = lines.prefix(maxLines).joined(separator: "\n")
            capFired = "line cap (\(maxLines))"
        }
        var data = Data(text.utf8)
        if data.count > maxBytes {
            let prefix = data.prefix(maxBytes)
            if let lastNewline = prefix.lastIndex(of: 0x0A) {
                data = Data(prefix[..<lastNewline])
            } else {
                data = prefix
            }
            text = String(decoding: data, as: UTF8.self)
            capFired = capFired ?? "byte cap (\(maxBytes))"
        }
        if let capFired {
            text += "\n\n[MEMORY.md truncated: \(capFired). Keep index entries to one line each.]"
        }
        return TruncationResult(text: text, capFired: capFired)
    }
}

struct MemoryTopicFrontmatter: Sendable, Equatable {
    let name: String
    let description: String
    let type: MemoryTopicType
}

enum MemoryTopicFrontmatterParser {
    static func parse(from content: String) -> MemoryTopicFrontmatter? {
        guard content.hasPrefix("---") else { return nil }
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else { return nil }
        let yaml = parts[1]
        var name = ""
        var description = ""
        var typeRaw = ""
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("description:") {
                description = trimmed.dropFirst(12).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("type:") {
                typeRaw = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let type = MemoryTopicType(rawValue: typeRaw), !name.isEmpty else { return nil }
        return MemoryTopicFrontmatter(name: name, description: description, type: type)
    }
}

enum MemoryManifestScanner {
    static func scanDirectory(_ memoryDirectory: URL, fileManager: FileManager = .default) -> [MemoryManifestEntry] {
        guard let files = try? fileManager.contentsOfDirectory(at: memoryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files
            .filter {
                $0.pathExtension == "md"
                    && $0.lastPathComponent != "MEMORY.md"
                    && $0.lastPathComponent != "DREAMS.md"
                    && !AgentMemoryStore.isDailyFilename($0.lastPathComponent)
            }
            .compactMap { url -> MemoryManifestEntry? in
                guard let content = try? String(contentsOf: url, encoding: .utf8),
                      let fm = MemoryTopicFrontmatterParser.parse(from: content) else { return nil }
                let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                return MemoryManifestEntry(
                    filename: url.lastPathComponent,
                    memoryType: fm.type,
                    name: fm.name,
                    description: fm.description,
                    updatedAt: updated
                )
            }
            .sorted { $0.filename < $1.filename }
    }

    static func formatManifestLine(_ entry: MemoryManifestEntry) -> String {
        let ts = entry.updatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        return "[\(entry.memoryType.rawValue)] \(entry.filename) (\(ts)): \(entry.description)"
    }
}
