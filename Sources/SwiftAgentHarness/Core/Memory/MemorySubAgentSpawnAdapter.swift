import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

enum MemorySubAgentSpawnAdapter {
    /// Gateway-enforced closed world for active-memory recall (also mirrored on `memory-active-recall` mode profile).
    static let activeMemoryToolsAllow: [String] = [
        MemorySearchToolProvider.searchToolName,
        MemorySearchToolProvider.getToolName,
    ]

    static func makePort(
        spawnSubAgent: @escaping @Sendable (UUID, SubAgentSpawnRequest, Model?) async throws -> UUID,
        sendMessageAndRun: @escaping @Sendable (UUID, String) async throws -> Void,
        cancelChildRun: @escaping @Sendable (UUID) async -> Void,
        /// Releases the sub-agent run-lane when the child never reaches a natural afterTurn
        /// (timeout / cancelled mid-drain). Idempotent with `afterTurn` → finish when both fire.
        finishChildRunLifecycle: @escaping @Sendable (UUID) async -> Void,
        lastAssistantText: @escaping @Sendable (UUID) async -> String?,
        manifestLines: @escaping @Sendable (UUID) async -> [String],
        parentModel: @escaping @Sendable (UUID) async -> Model?,
        rankedRegistryEntries: @escaping @Sendable (ModelReference) async -> [ModelRegistryEntry],
        resolveFlushPlan: @escaping @Sendable (UUID, [String], String) async -> MemoryFlushPlan?,
        config: MemoryConfiguration,
        logger: Logger?
    ) -> MemorySubAgentSpawnPort {
        MemorySubAgentSpawnPort(
            spawnBlockingRecall: { parentConversationID, userQuery, lane, timeoutMs, maxSummaryChars, excludedSelectionKeys in
                guard let parent = await parentModel(parentConversationID) else {
                    logger?.debug("[ActiveMemory] parent conversation missing; skipping recall")
                    return nil
                }
                guard let model = await ActiveMemoryModelResolver.resolve(
                    parentModel: parent,
                    config: config,
                    ranked: rankedRegistryEntries,
                    logger: logger
                ) else {
                    return nil
                }
                let sanitizedQuery = userQuery.map { MemoryContextFencer.stripInjectedRecallArtifacts($0) }
                let (systemPrompt, userPromptText) = ActiveMemoryPreReplyPrompts.prompts(
                    for: lane,
                    query: sanitizedQuery,
                    maxSummaryChars: maxSummaryChars,
                    promptStyle: config.activeMemoryPromptStyle,
                    excludedSelectionKeys: excludedSelectionKeys
                )
                let spawnRequest = SubAgentSpawnRequest(
                    context: .isolated,
                    taskDescription: "memory-active-recall",
                    prompt: userPromptText,
                    runInBackground: false,
                    userSystemPrompt: systemPrompt,
                    topic: "memory-active-recall",
                    interactionMode: "memory-active-recall",
                    toolsAllow: Self.activeMemoryToolsAllow
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
                    logger?.debug("[ActiveMemory] timed out or cancelled mid-drain; closing out child")
                    await closeOutTimedOutChild(
                        childID: childID,
                        cancelChildRun: cancelChildRun,
                        finishChildRunLifecycle: finishChildRunLifecycle
                    )
                    return nil
                }
                guard let raw = await lastAssistantText(childID) else {
                    return nil
                }
                guard let note = ActiveMemoryRecallOutput.noteOrNil(raw) else {
                    return nil
                }
                let capped = ActiveMemoryRecallOutput.truncatedNote(note, maxChars: maxSummaryChars)
                return MemoryContextFencer.fence(capped)
            },
            spawnBackgroundExtraction: { request in
                let manifest = await manifestLines(request.session.conversationID)
                let transcript = MemoryExtractionPrompts.recentTranscriptSlice(
                    messages: request.recentMessages,
                    limit: config.extractionRecentMessageCount
                )
                guard !transcript.isEmpty else { return }
                let anchorMessageID = request.recentMessages.last(where: { $0.role == .user })?.id
                    ?? request.recentMessages.last?.id
                guard let anchorMessageID else { return }
                let extractionDirective = MemoryExtractionPrompts.systemPrompt(
                    manifestLines: manifest,
                    teamMemoryEnabled: config.teamMemoryEnabled
                )
                let fencedTranscript = MemoryExtractionInputFencer.fence(transcript)
                let forkUserPrompt = """
                <fork-boilerplate>
                \(extractionDirective)
                </fork-boilerplate>

                \(fencedTranscript)
                """
                let spawnRequest = SubAgentSpawnRequest(
                    context: .fork,
                    userMessageID: anchorMessageID,
                    taskDescription: "memory-extraction",
                    prompt: forkUserPrompt,
                    runInBackground: true,
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
                        try await sendMessageAndRun(childID, forkUserPrompt)
                    } catch {
                        logger?.debug("[MemoryExtractor] background run failed: \(error)")
                        await closeOutTimedOutChild(
                            childID: childID,
                            cancelChildRun: cancelChildRun,
                            finishChildRunLifecycle: finishChildRunLifecycle
                        )
                    }
                }
            },
            spawnBlockingPreCompactionFlush: { parentConversationID, middleMessages, timeoutMs in
                guard config.preCompactionFlushEnabled else { return false }
                let manifest = await manifestLines(parentConversationID)
                let transcript = MemoryExtractionPrompts.recentTranscriptSlice(
                    messages: middleMessages,
                    limit: middleMessages.count
                )
                guard !transcript.isEmpty else { return false }
                guard let plan = await resolveFlushPlan(parentConversationID, manifest, transcript) else { return false }
                let anchorMessageID = middleMessages.last(where: { $0.role == .user })?.id
                    ?? middleMessages.last?.id
                guard let anchorMessageID else { return false }
                let forkUserPrompt = """
                <fork-boilerplate>
                \(plan.systemPrompt)
                </fork-boilerplate>

                \(plan.userPrompt)
                """
                let spawnRequest = SubAgentSpawnRequest(
                    context: .fork,
                    userMessageID: anchorMessageID,
                    taskDescription: "memory-pre-compaction-flush",
                    prompt: forkUserPrompt,
                    runInBackground: false,
                    topic: "memory-pre-compaction-flush",
                    metadata: .object([
                        "preCompactionFlushMaxIterations": .double(Double(config.preCompactionFlushMaxIterations)),
                    ]),
                    interactionMode: "memory-pre-compaction-flush"
                )
                let childID: UUID
                do {
                    childID = try await spawnSubAgent(parentConversationID, spawnRequest, nil)
                } catch {
                    logger?.debug("[PreCompactionMemoryFlush] spawn failed: \(error)")
                    return false
                }
                let completed = await runWithTimeout(timeoutMs: timeoutMs) {
                    try await sendMessageAndRun(childID, forkUserPrompt)
                }
                if completed == false {
                    logger?.debug("[PreCompactionMemoryFlush] timed out or cancelled mid-drain; closing out child")
                    await closeOutTimedOutChild(
                        childID: childID,
                        cancelChildRun: cancelChildRun,
                        finishChildRunLifecycle: finishChildRunLifecycle
                    )
                    return false
                }
                return true
            }
        )
    }

    /// Drain-task cancellation alone does not stop the unstructured `generationTask` or fire
    /// `afterTurnContextEngineLifecycle`. Cancel the child run, then always finish the lifecycle
    /// so the run-lane is released even when cancel is a no-op (missing `currentRunID`).
    private static func closeOutTimedOutChild(
        childID: UUID,
        cancelChildRun: @escaping @Sendable (UUID) async -> Void,
        finishChildRunLifecycle: @escaping @Sendable (UUID) async -> Void
    ) async {
        await cancelChildRun(childID)
        await finishChildRunLifecycle(childID)
    }

    /// Fixture helper for tests that need a tools-capable local model (not used on the spawn path).
    static func fixtureToolsCapableLocalModel(
        name: String = "active-memory-fixture",
        serverURL: URL = MemoryConfiguration.default.activeMemoryOllamaServerURL
    ) -> Model {
        Model(
            id: ModelPoolMemoryLLMRecallSelector.modelID(model: name, serverURL: serverURL),
            protocol: .ollama,
            modelName: name,
            serverURL: serverURL,
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
