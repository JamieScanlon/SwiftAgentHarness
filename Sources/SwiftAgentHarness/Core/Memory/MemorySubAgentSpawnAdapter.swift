import Foundation
import Logging
import SwiftAgentKit

enum MemorySubAgentSpawnAdapter {
    static func makePort(
        spawnSubAgent: @escaping @Sendable (UUID, SubAgentSpawnRequest, Model?) async throws -> UUID,
        sendMessageAndRun: @escaping @Sendable (UUID, String) async throws -> Void,
        cancelChildRun: @escaping @Sendable (UUID) async -> Void,
        lastAssistantText: @escaping @Sendable (UUID) async -> String?,
        manifestLines: @escaping @Sendable (UUID) async -> [String],
        config: MemoryConfiguration,
        logger: Logger?
    ) -> MemorySubAgentSpawnPort {
        MemorySubAgentSpawnPort(
            spawnBlockingRecall: { parentConversationID, userQuery, lane, timeoutMs, maxSummaryChars in
                let model = activeMemoryModel(from: config)
                let (systemPrompt, userPromptText) = ActiveMemoryPreReplyPrompts.prompts(for: lane, query: userQuery)
                let spawnRequest = SubAgentSpawnRequest(
                    context: .isolated,
                    taskDescription: "memory-active-recall",
                    prompt: userPromptText,
                    runInBackground: false,
                    userSystemPrompt: systemPrompt,
                    topic: "memory-active-recall",
                    interactionMode: "memory-active-recall"
                )
                let childID: UUID
                do {
                    childID = try await spawnSubAgent(parentConversationID, spawnRequest, model)
                } catch {
                    logger?.debug("[ActiveMemory] spawn failed: \(error)")
                    return nil
                }
                let completed = await runWithTimeout(timeoutMs: timeoutMs) {
                    try await sendMessageAndRun(childID, userPromptText)
                }
                if completed == false {
                    logger?.debug("[ActiveMemory] timed out; cancelling child run")
                    await cancelChildRun(childID)
                    return nil
                }
                guard let raw = await lastAssistantText(childID) else {
                    return nil
                }
                guard let note = ActiveMemoryRecallOutput.noteOrNil(raw) else {
                    return nil
                }
                let capped = String(note.prefix(maxSummaryChars))
                return MemoryContextFencer.fence(capped)
            },
            spawnBackgroundExtraction: { request in
                let manifest = await manifestLines(request.session.conversationID)
                let systemPrompt = MemoryExtractionPrompts.systemPrompt(
                    manifestLines: manifest,
                    teamMemoryEnabled: config.teamMemoryEnabled
                )
                let transcript = MemoryExtractionPrompts.recentTranscriptSlice(
                    messages: request.recentMessages,
                    limit: config.extractionRecentMessageCount
                )
                guard !transcript.isEmpty else { return }
                let fencedTranscript = MemoryExtractionInputFencer.fence(transcript)
                let spawnRequest = SubAgentSpawnRequest(
                    context: .isolated,
                    taskDescription: "memory-extraction",
                    prompt: fencedTranscript,
                    runInBackground: true,
                    userSystemPrompt: systemPrompt,
                    topic: "memory-extraction",
                    interactionMode: "memory-extraction"
                )
                let childID: UUID
                do {
                    childID = try await spawnSubAgent(request.session.conversationID, spawnRequest, nil)
                } catch {
                    logger?.debug("[MemoryExtractor] spawn failed: \(error)")
                    return
                }
                Task {
                    do {
                        try await sendMessageAndRun(childID, fencedTranscript)
                    } catch {
                        logger?.debug("[MemoryExtractor] background run failed: \(error)")
                    }
                }
            },
            spawnBlockingPreCompactionFlush: { parentConversationID, middleMessages, timeoutMs in
                guard config.preCompactionFlushEnabled else { return false }
                let manifest = await manifestLines(parentConversationID)
                let systemPrompt = MemoryPreCompactionFlushPrompts.systemPrompt(
                    manifestLines: manifest,
                    teamMemoryEnabled: config.teamMemoryEnabled
                )
                let transcript = MemoryExtractionPrompts.recentTranscriptSlice(
                    messages: middleMessages,
                    limit: middleMessages.count
                )
                guard !transcript.isEmpty else { return false }
                let spawnRequest = SubAgentSpawnRequest(
                    context: .isolated,
                    taskDescription: "memory-pre-compaction-flush",
                    prompt: MemoryPreCompactionFlushPrompts.userPrompt(middleTranscript: transcript),
                    runInBackground: false,
                    userSystemPrompt: systemPrompt,
                    topic: "memory-pre-compaction-flush",
                    interactionMode: "memory-pre-compaction-flush"
                )
                let childID: UUID
                do {
                    childID = try await spawnSubAgent(parentConversationID, spawnRequest, nil)
                } catch {
                    logger?.debug("[PreCompactionMemoryFlush] spawn failed: \(error)")
                    return false
                }
                let prompt = MemoryPreCompactionFlushPrompts.userPrompt(middleTranscript: transcript)
                let completed = await runWithTimeout(timeoutMs: timeoutMs) {
                    try await sendMessageAndRun(childID, prompt)
                }
                if completed == false {
                    logger?.debug("[PreCompactionMemoryFlush] timed out; cancelling child run")
                    await cancelChildRun(childID)
                    return false
                }
                return true
            }
        )
    }

    static func activeMemoryModel(from config: MemoryConfiguration) -> Model {
        Model(
            id: ModelPoolMemoryLLMRecallSelector.modelID(
                model: config.activeMemoryModel,
                serverURL: config.activeMemoryOllamaServerURL
            ),
            protocol: .ollama,
            modelName: config.activeMemoryModel,
            serverURL: config.activeMemoryOllamaServerURL,
            capabilities: [.completion, .tools],
            modelProtocol: .ollama
        )
    }

    private static func runWithTimeout(
        timeoutMs: Int,
        operation: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await operation()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
