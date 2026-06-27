import Foundation

/// Ephemeral preview update emitted to the surface sink.
public enum PreviewUpdate: Sendable, Equatable {
    case text(String)
    case progress(String)
    case toolProgress(String)
}

/// Terminal state for a scratch preview message.
public enum PreviewResolution: Sendable, Equatable {
    case replacedByFinal
    case cancelled(partialText: String?)
    case removed
}

/// Manages in-place preview streaming (partial / block / progress modes).
public struct PreviewStreamer: Sendable {
    private let mode: PreviewMode
    private let chunkerConfig: ChunkerConfig
    private var accumulatedText: String = ""
    private var chunker: BlockChunker?
    private var lastPreviewText: String?

    public init(mode: PreviewMode, chunkerConfig: ChunkerConfig? = nil) {
        self.mode = mode
        self.chunkerConfig = chunkerConfig ?? ChunkerConfig(minChars: 1, maxChars: 500, textChunkLimit: 500)
        if mode == .block {
            self.chunker = BlockChunker(config: self.chunkerConfig)
        }
    }

    public var isActive: Bool { mode != .off }

    /// Handles an assistant text delta; returns preview updates to emit.
    public mutating func ingestText(_ text: String) -> [PreviewUpdate] {
        guard mode != .off, !text.isEmpty else { return [] }

        switch mode {
        case .off:
            return []
        case .partial:
            accumulatedText += text
            lastPreviewText = accumulatedText
            return [.text(accumulatedText)]
        case .block:
            accumulatedText += text
            guard var chunker else { return [.text(accumulatedText)] }
            let chunks = chunker.ingest(text)
            if chunks.isEmpty {
                lastPreviewText = accumulatedText
                return [.text(accumulatedText)]
            }
            return chunks.map { .text($0) }
        case .progress:
            accumulatedText += text
            lastPreviewText = accumulatedText
            return [.text(accumulatedText)]
        }
    }

    /// Emits a tool-progress line ("Searching the web", etc.).
    public mutating func ingestToolProgress(_ line: String) -> [PreviewUpdate] {
        guard mode != .off else { return [] }
        switch mode {
        case .progress:
            return [.progress(line)]
        case .partial, .block:
            return [.toolProgress(line)]
        case .off:
            return []
        }
    }

    /// Flushes remaining preview text at end-of-turn before final reply supersedes it.
    public mutating func flush() -> [PreviewUpdate] {
        guard mode != .off else { return [] }
        if mode == .block, var chunker {
            let chunks = chunker.flush()
            self.chunker = chunker
            return chunks.map { .text($0) }
        }
        if !accumulatedText.isEmpty {
            return [.text(accumulatedText)]
        }
        return []
    }

    public mutating func resolveForFinal() -> PreviewResolution {
        .replacedByFinal
    }

    public mutating func resolveForCancellation() -> PreviewResolution {
        if accumulatedText.isEmpty {
            return .removed
        }
        return .cancelled(partialText: accumulatedText)
    }

    public mutating func reset() {
        accumulatedText = ""
        lastPreviewText = nil
        if mode == .block {
            chunker = BlockChunker(config: chunkerConfig)
        }
    }
}
