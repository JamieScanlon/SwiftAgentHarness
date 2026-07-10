import Foundation

enum MemoryProviderPreCompressNotes: Sendable {
    static func collect(providers: [any MemoryProviding], messages: [String]) async -> String {
        var parts: [String] = []
        for provider in providers {
            let note = await provider.onPreCompress(messages: messages)
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            parts.append(trimmed)
        }
        return parts.joined(separator: "\n\n")
    }

    static func summarizerHandoffBlock(notes: String?) -> String {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        return """
        # Memory provider pre-compaction extraction

        The following was extracted by active memory provider(s) before this compaction. Treat as authoritative background; preserve durable facts in your summary.

        <memory-pre-compress>
        \(trimmed)
        </memory-pre-compress>

        """
    }
}
