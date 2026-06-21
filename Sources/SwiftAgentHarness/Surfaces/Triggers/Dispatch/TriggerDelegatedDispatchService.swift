import Foundation
import Logging
import SwiftAgentKit

protocol TriggerDelegatedSpawning: Sendable {
    func spawnDelegatedSubAgent(
        parentConversationID: UUID,
        request: SubAgentSpawnRequest,
        modelOverride: Model?
    ) async throws -> UUID

    func sendMessageAndRun(childConversationID: UUID, prompt: String) async throws

    func lastAssistantText(childConversationID: UUID) async -> String?
}

struct TriggerDelegatedDispatchService: Sendable {
    private let spawn: TriggerDelegatedSpawning
    private let runRegistry: TriggerDelegatedRunRegistry
    private let logger: Logger?

    init(
        spawn: TriggerDelegatedSpawning,
        runRegistry: TriggerDelegatedRunRegistry,
        logger: Logger? = nil
    ) {
        self.spawn = spawn
        self.runRegistry = runRegistry
        self.logger = logger
    }

    func dispatch(
        trigger: HarnessTrigger,
        hostConversationID: UUID,
        sessionKey: String,
        built: TriggerPromptBuildResult
    ) async throws -> UUID {
        let profile = TriggerDelegateProfileCodec.decodeFromMetadata(trigger.sourceMetadata["delegateProfileJSON"])
            ?? TriggerDelegateProfile()
        var messageText = built.userMessageBody
        if let reminder = built.systemReminder {
            messageText = reminder + "\n\n" + messageText
        }
        let taskDescription = profile.taskDescription ?? "trigger:\(trigger.source.rawValue):\(trigger.id)"
        var spawnRequest = SubAgentSpawnRequest(
            context: profile.context,
            taskDescription: taskDescription,
            prompt: messageText,
            subagentType: profile.subagentType,
            agentID: profile.agentID,
            modelRef: profile.modelRef,
            runInBackground: profile.runInBackground,
            userSystemPrompt: profile.userSystemPrompt ?? TriggerDelegatePrompts.defaultSystemPrompt(),
            topic: "trigger-delegate",
            interactionMode: "trigger-delegate"
        )
        if let agentID = profile.agentID {
            spawnRequest.agentRef = agentID
        }
        let childID = try await spawn.spawnDelegatedSubAgent(
            parentConversationID: hostConversationID,
            request: spawnRequest,
            modelOverride: nil
        )
        await runRegistry.register(
            TriggerDelegatedRunRecord(
                trigger: trigger,
                parentConversationID: hostConversationID,
                childConversationID: childID,
                sessionKey: sessionKey
            )
        )
        if profile.runInBackground {
            Task {
                do {
                    try await spawn.sendMessageAndRun(childConversationID: childID, prompt: messageText)
                } catch {
                    logger?.debug("[TriggerDelegatedDispatch] background run failed: \(error)")
                }
            }
        } else {
            try await spawn.sendMessageAndRun(childConversationID: childID, prompt: messageText)
        }
        logger?.debug("[TriggerDelegatedDispatch] spawned child=\(childID) host=\(hostConversationID) trigger=\(trigger.id)")
        return childID
    }
}

enum TriggerDelegatePrompts {
    static func defaultSystemPrompt() -> String {
        """
        You are a delegated trigger worker. Complete the assigned task using only your allowed tools.
        Respond with a concise report covering what was done and key findings.
        Do not spawn sub-agents, register triggers, or send outbound messages yourself.
        Reply with exactly NO_REPLY if no user-visible response is needed.
        """
    }
}
