import Foundation
import Logging

enum MemorySubAgentSpawnWiring {
    static func install(
        deps: ConversationRuntimeDependencies,
        persistenceDomain: ConversationPersistenceDomain,
        subAgentSpawnService: SubAgentSpawnService,
        agentRuntime: AgentRuntimeSessionService
    ) {
        guard let defaultEngine = deps.contextEngine as? DefaultContextEngine,
              let memoryService = defaultEngine.memoryService else {
            return
        }
        let config = deps.configurationSet.memory
        let ranked = deps.rankedRegistryEntriesProvider
        let port = MemorySubAgentSpawnAdapter.makePort(
            spawnSubAgent: { parentID, request, model in
                try await subAgentSpawnService.spawnSubAgentViaPool(
                    parentConversationID: parentID,
                    request: request,
                    modelOverride: model,
                    bypassDelegateAllowList: true
                )
            },
            sendMessageAndRun: { childID, prompt in
                try await HarnessEmbeddedMutation.sendMessageAndDrain(
                    conversationID: childID,
                    prompt: prompt,
                    fallback: {
                        let response = try await agentRuntime.serviceRuntimeSendMessageAndStreamResponse(
                            prompt,
                            images: [],
                            conversationID: childID,
                            configuration: AgentRuntimeTurnConfiguration(enableTools: true)
                        )
                        async let partialDrain: Void = {
                            for await _ in response.partialContent {}
                        }()
                        async let stateDrain: Void = {
                            for await _ in response.orchestrationState {}
                        }()
                        _ = await (partialDrain, stateDrain)
                    }
                )
            },
            cancelChildRun: { childID in
                // Prefer the spawn-service cancel: it falls back to lifecycle streaming run IDs
                // when `conversation.currentRunID` is not yet stamped (timeout mid-setup).
                await subAgentSpawnService.cancelChildRunForSubAgent(childConversationID: childID)
            },
            finishChildRunLifecycle: { childID in
                // Drain-task cancellation alone never reaches afterTurn / generationTask. Mirror
                // LocalAgents: always terminal-close so the run-lane is released on timeout.
                await subAgentSpawnService.finishSubAgentLifecycleForEndedChildRun(
                    childConversationID: childID,
                    terminalReason: ConversationRunTerminalReason(
                        category: .externalCancellation,
                        detail: "memory_subagent_timeout"
                    )
                )
            },
            lastAssistantText: { childID in
                guard let conversation = await persistenceDomain.modelConversation(id: childID) else {
                    return nil
                }
                return conversation.messages.last(where: { $0.role == .assistant })?.content
            },
            manifestLines: { conversationID in
                guard let defaultEngine = deps.contextEngine as? DefaultContextEngine,
                      let memoryService = defaultEngine.memoryService else {
                    return []
                }
                return await memoryService.extractionManifestLines(conversationID: conversationID)
            },
            parentModel: { conversationID in
                await persistenceDomain.modelConversation(id: conversationID)?.model
            },
            rankedRegistryEntries: { ref in
                guard let ranked else { return [] }
                return await ranked(ref)
            },
            resolveFlushPlan: { conversationID, manifestLines, middleTranscript in
                await memoryService.resolveFlushPlan(
                    conversationID: conversationID,
                    manifestLines: manifestLines,
                    middleTranscript: middleTranscript
                )
            },
            config: config,
            logger: deps.logger
        )
        Task {
            await memoryService.bindSpawnPort(port)
        }
    }
}
