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
        let config = MemoryConfigurationLoader.loadFromPromptConfigBundle(logger: deps.logger)
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
            },
            cancelChildRun: { childID in
                if let conversation = await persistenceDomain.modelConversation(id: childID),
                   let runID = conversation.currentRunID {
                    await agentRuntime.cancelSubAgentRun(conversationID: childID, runID: runID)
                }
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
                let entries = await memoryService.manifestEntries(conversationID: conversationID)
                return entries.map(MemoryManifestScanner.formatManifestLine)
            },
            config: config,
            logger: deps.logger
        )
        Task {
            await memoryService.bindSpawnPort(port)
        }
    }
}
