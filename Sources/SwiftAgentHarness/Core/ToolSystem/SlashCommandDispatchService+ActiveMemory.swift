import EasyJSON
import Foundation

extension SlashCommandDispatchService {
    func runSlashActiveMemoryCommand(conversationID: UUID, args: String) async throws -> ChatStreamResponse {
        let tokens = args
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        let isGlobal = tokens.contains("--global")
        let sub = tokens.first(where: { $0 != "--global" })

        let control = ActiveMemoryControlStore()
        let memoryConfig = MemoryConfiguration.default

        switch sub {
        case nil, "", "status":
            let sessionEnabled = await currentSessionActiveMemoryEnabled(conversationID: conversationID)
            let summary = control.statusSummary(
                config: memoryConfig,
                sessionEnabled: isGlobal ? nil : sessionEnabled
            )
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: summary
            )
        case "on":
            if isGlobal {
                try control.setEnabled(true)
                return try await deliverSyntheticSlashAssistantResponse(
                    conversationID: conversationID,
                    content: "Active memory enabled globally. Sessions still need session-on and config-on."
                )
            }
            try await setSessionActiveMemoryEnabled(true, conversationID: conversationID)
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Active memory enabled for this session."
            )
        case "off":
            if isGlobal {
                try control.setEnabled(false)
                return try await deliverSyntheticSlashAssistantResponse(
                    conversationID: conversationID,
                    content: "Active memory disabled globally. Use /active-memory on --global to re-enable."
                )
            }
            try await setSessionActiveMemoryEnabled(false, conversationID: conversationID)
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Active memory disabled for this session. Use /active-memory on to re-enable."
            )
        default:
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Usage: /active-memory status|on|off [--global]"
            )
        }
    }

    private func currentSessionActiveMemoryEnabled(conversationID: UUID) async -> Bool {
        guard let conv = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            return true
        }
        return ActiveMemorySessionFlags.isSessionEnabled(metadata: conv.metadata)
    }

    private func setSessionActiveMemoryEnabled(_ enabled: Bool, conversationID: UUID) async throws {
        guard let conv = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let metadata = ActiveMemorySessionFlags.withSessionEnabled(enabled, metadata: conv.metadata)
        _ = try await deps.persistenceDomain.updateConversationMetadata(
            conversationID: conversationID,
            topic: conv.topic,
            description: conv.description,
            metadata: metadata,
            allowHarnessMetadataKeys: true
        )
    }
}
