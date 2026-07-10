import Foundation

/// Harness-enforced safety hints for pre-compaction flush (always appended after custom or default body).
enum PreCompactionFlushSafetyHints: Sendable {
    static let targetHint = """
### Target (curated promotion only)

Do NOT write daily staging files (`YYYY-MM-DD.md` or any date-named note). Pre-compaction flush promotes directly to curated typed topic files only (`user` / `feedback` / `project` / `reference` with YAML frontmatter).
"""

    static let appendOnlyHint = """
### Append-only

Existing manifest topic files listed above are append-only: read them first, then append new sections at the end. Never replace or truncate existing curated content.

`MEMORY.md` is append-only for a single index line per new topic. Never use write_file on `MEMORY.md` or on existing manifest topic files; use edit_file to append one `- [Title](file.md) — hook` index line or new topic sections at the end.
"""

    static let readOnlyHint = """
### Read-only scope

File tools are scoped to the memory directory. Use bare filenames only (typed topic `.md` files and `MEMORY.md`). Do not attempt to read project or source files referenced in the transcript — they are not accessible.

Turn 1 — issue all Read calls in parallel for every file you might update; turn 2 — issue all Write/Edit calls in parallel. Do not interleave reads and writes across multiple turns.
"""

    static func enforcedBlock() -> String {
        """
## Non-negotiable flush constraints

\(targetHint)
\(appendOnlyHint)
\(readOnlyHint)
"""
    }
}
