import Foundation
import Logging
import SwiftAgentKit

actor BackgroundMemoryExtractor {
    private let logger: Logger?
    private let config: MemoryConfiguration
    private var inFlight = false
    private var stashedTurn: MemoryTurnEndedRequest?
    private var eligibleTurnCounter = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var shuttingDown = false

    init(config: MemoryConfiguration, logger: Logger? = nil) {
        self.config = config
        self.logger = logger
    }

    func scheduleIfNeeded(request: MemoryTurnEndedRequest, runExtraction: @Sendable @escaping (MemoryTurnEndedRequest) async -> Void) async {
        guard config.extractionEnabled else { return }
        guard request.isMainREPLThread else { return }
        if request.mainAgentWroteMemory {
            logger?.debug("[MemoryExtractor] skipped: main agent wrote memory this turn")
            return
        }
        if inFlight {
            stashedTurn = request
            return
        }
        eligibleTurnCounter += 1
        if eligibleTurnCounter % config.extractionThrottleTurns != 0 { return }
        await run(request: request, runExtraction: runExtraction)
    }

    func drain(timeoutMs: Int) async {
        shuttingDown = true
        stashedTurn = nil
        guard inFlight else { return }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
            Task.detached { [self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
                await self.resumeAllDrainWaiters()
            }
        }
    }

    private func resumeAllDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func run(request: MemoryTurnEndedRequest, runExtraction: @Sendable @escaping (MemoryTurnEndedRequest) async -> Void) async {
        inFlight = true
        var replayStashed: MemoryTurnEndedRequest?
        defer {
            inFlight = false
            resumeAllDrainWaiters()
            if let stashed = replayStashed {
                Task { await self.runStashedBypassingThrottle(stashed, runExtraction: runExtraction) }
            }
        }
        await runExtraction(request)
        if !shuttingDown, let stashed = stashedTurn {
            stashedTurn = nil
            replayStashed = stashed
        }
    }

    private func runStashedBypassingThrottle(
        _ request: MemoryTurnEndedRequest,
        runExtraction: @Sendable @escaping (MemoryTurnEndedRequest) async -> Void
    ) async {
        guard config.extractionEnabled else { return }
        guard request.isMainREPLThread else { return }
        if request.mainAgentWroteMemory { return }
        await run(request: request, runExtraction: runExtraction)
    }
}

enum MemoryExtractionPrompts {
    static func systemPrompt(manifestLines: [String], teamMemoryEnabled: Bool = false) -> String {
        var prompt = """
You extract durable cross-session memories from recent conversation messages.
Turn 1 — issue all Read calls in parallel for every file you might update; turn 2 — issue all Write/Edit calls in parallel. Do not interleave reads and writes across multiple turns.

Existing memory manifest:
\(manifestLines.joined(separator: "\n"))

File tools are scoped to the memory directory. Use bare filenames only (e.g. `MEMORY.md`, `notes.md`). Do not attempt to read project or source files referenced in the transcript — they are not accessible.
When no memory files exist yet (blank manifest above), create them using write_file rather than reading first.

\(MemoryTypeTaxonomy.whatNotToSavePrompt)
\(MemoryTypeTaxonomy.indexUsagePrompt)
"""
        if teamMemoryEnabled {
            prompt += "\n" + MemoryTypeTaxonomy.teamSensitiveDataPrompt
        }
        return prompt
    }

    static func recentTranscriptSlice(messages: [Message], limit: Int) -> String {
        let slice = messages.suffix(max(1, limit))
        return slice.map { message in
            let role = message.role.rawValue
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(role)] \(content)"
        }
        .joined(separator: "\n\n")
    }
}

enum MemoryPreCompactionFlushPrompts {
    static func systemPrompt(manifestLines: [String], teamMemoryEnabled: Bool = false) -> String {
        var prompt = MemoryExtractionPrompts.systemPrompt(
            manifestLines: manifestLines,
            teamMemoryEnabled: teamMemoryEnabled
        )
        prompt += """

URGENT: Context compaction is about to summarize away conversation history.
Save anything durable from the messages below to memory files NOW before it is lost.
"""
        return prompt
    }

    static func userPrompt(middleTranscript: String) -> String {
        """
The following conversation messages will be summarized away. Persist any durable cross-session facts to memory files now:

\(middleTranscript)
"""
    }
}
