import Foundation
import SwiftAgentKit
import EasyJSON

public extension TriggersRuntimeWiring {
    /// Embedded REST loopback for trigger host conversation creation.
    static func embeddedCreateConversation(
        modelRef: String,
        session: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession(),
        fallback: @escaping @Sendable (String?) async throws -> UUID
    ) -> @Sendable (String?) async throws -> UUID {
        { topic in
            try await HarnessEmbeddedMutation.createConversation(
                modelRef: modelRef,
                topic: topic,
                session: session,
                fallback: fallback
            )
        }
    }
}

public extension TriggersRuntimeWiring.DelegatedPorts {
    /// Delegated child run dispatch via embedded REST when transport is configured.
    static func embeddedLoopback(
        spawnSubAgent: @escaping @Sendable (UUID, SubAgentSpawnRequest, Model?) async throws -> UUID,
        lastAssistantText: @escaping @Sendable (UUID) async -> String?,
        stampDelegatedHost: @escaping @Sendable (UUID, HarnessTrigger, String) async throws -> Void,
        resolveParentConversation: @escaping @Sendable (UUID) async -> (parentID: UUID, metadata: JSON?)?,
        session: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession(),
        fallbackSendMessageAndRun: @escaping @Sendable (UUID, String) async throws -> Void
    ) -> TriggersRuntimeWiring.DelegatedPorts {
        TriggersRuntimeWiring.DelegatedPorts(
            spawnSubAgent: spawnSubAgent,
            sendMessageAndRun: { childID, prompt in
                try await HarnessEmbeddedMutation.sendMessageAndDrain(
                    conversationID: childID,
                    prompt: prompt,
                    session: session,
                    fallback: {
                        try await fallbackSendMessageAndRun(childID, prompt)
                    }
                )
            },
            lastAssistantText: lastAssistantText,
            stampDelegatedHost: stampDelegatedHost,
            resolveParentConversation: resolveParentConversation
        )
    }
}
