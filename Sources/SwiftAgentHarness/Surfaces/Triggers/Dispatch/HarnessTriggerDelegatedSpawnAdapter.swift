import Foundation
import SwiftAgentKit

struct HarnessTriggerDelegatedSpawnAdapter: TriggerDelegatedSpawning {
    private let spawn: @Sendable (UUID, SubAgentSpawnRequest, Model?) async throws -> UUID
    private let runChild: @Sendable (UUID, String) async throws -> Void
    private let fetchLastAssistantText: @Sendable (UUID) async -> String?

    init(
        spawnSubAgent: @escaping @Sendable (UUID, SubAgentSpawnRequest, Model?) async throws -> UUID,
        sendMessageAndRun: @escaping @Sendable (UUID, String) async throws -> Void,
        lastAssistantText: @escaping @Sendable (UUID) async -> String?
    ) {
        self.spawn = spawnSubAgent
        self.runChild = sendMessageAndRun
        self.fetchLastAssistantText = lastAssistantText
    }

    func spawnDelegatedSubAgent(
        parentConversationID: UUID,
        request: SubAgentSpawnRequest,
        modelOverride: Model?
    ) async throws -> UUID {
        try await spawn(parentConversationID, request, modelOverride)
    }

    func sendMessageAndRun(childConversationID: UUID, prompt: String) async throws {
        try await runChild(childConversationID, prompt)
    }

    func lastAssistantText(childConversationID: UUID) async -> String? {
        await fetchLastAssistantText(childConversationID)
    }
}
