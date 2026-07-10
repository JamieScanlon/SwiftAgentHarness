import Foundation

extension SlashCommandDispatchService {
    func runSlashDreamingCommand(conversationID: UUID, args: String) async throws -> ChatStreamResponse {
        let sub = args
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .first?
            .lowercased()

        let control = DreamingControlStore()
        let memoryConfig = MemoryConfigurationLoader.loadFromPromptConfigBundle()

        switch sub {
        case nil, "", "status":
            let memoryDirectory = await currentMemoryDirectory(conversationID: conversationID)
            let summary = control.statusSummary(
                cronExpr: memoryConfig.dreamingCron,
                memoryDirectory: memoryDirectory
            )
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: summary
            )
        case "on":
            try control.setEnabled(true)
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Dreaming enabled. Nightly cron (\(memoryConfig.dreamingCron)) will run consolidation sweeps."
            )
        case "off":
            try control.setEnabled(false)
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Dreaming disabled. Cron fires will no-op until re-enabled with /dreaming on."
            )
        default:
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Usage: /dreaming status|on|off"
            )
        }
    }

    private func currentMemoryDirectory(conversationID: UUID) async -> URL? {
        guard let memoryService = (deps.contextEngine as? DefaultContextEngine)?.memoryService,
              let conv = await deps.persistenceDomain.modelConversation(id: conversationID),
              let cwd = conv.harnessPersistenceCwd
        else {
            return nil
        }
        return try? memoryService.makeSessionContext(conversationID: conversationID, cwd: cwd).memoryDirectory
    }
}
