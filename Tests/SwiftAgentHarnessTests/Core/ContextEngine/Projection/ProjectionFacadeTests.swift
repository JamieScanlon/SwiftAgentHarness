import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationManager projection facade")
struct ConversationManagerProjectionFacadeTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "proj:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("rawMessages and UI projection match stored transcript when no turn-summary overlays apply")
    func rawAndUIProjectionRoundTrip() throws {
        let container = try makeContainer()
        let cm = ConversationManager(container: container)
        let conv = try cm.createConversation(
            with: makeModel(),
            userSystemPrompt: "system",
            topic: "T",
            description: nil,
            metadata: nil
        )
        let raw = try #require(cm.rawMessages(conversationID: conv.id))
        #expect(raw.map(\.id) == conv.messages.map(\.id))
        let ui = cm.projectedMessagesForUI(conversation: conv)
        #expect(ui.map(\.id) == conv.messages.map(\.id))
        let full = cm.projectUIMessagesWithMetrics(conversationID: conv.id, baseMessages: conv.messages)
        #expect(full.messages.map(\.id) == conv.messages.map(\.id))
        #expect(full.frontierEventID >= 0)
    }

    @Test("latestValidCheckpoint compaction dispatch matches ContextCompactionCheckpointSupport")
    func latestValidConversationCheckpointCompactionMatchesDirect() {
        let config = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
        let id1 = UUID(), id2 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "a", timestamp: Date(), toolCalls: []),
            Message(id: id2, role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
        ]
        let fp = ContextCompactionCheckpointSupport.configFingerprint(config)
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: [id1],
                    syntheticMessages: [
                        ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "s")
                    ],
                    configFingerprint: fp,
                    basedOnEventID: 4,
                    createdAt: Date()
                )
            ),
            createdAt: Date()
        )
        let viaDispatch = LatestValidConversationCheckpoint.latestValidCompaction(
            events: [event],
            rawMiddle: middle,
            config: config,
            frontierEventID: 99
        )
        let direct = ContextCompactionCheckpointSupport.latestValidCheckpoint(
            events: [event],
            rawMiddle: middle,
            config: config,
            frontierEventID: 99
        )
        #expect(viaDispatch?.eventID == direct?.eventID)
        #expect(viaDispatch?.payload.coveredMessageIDs == direct?.payload.coveredMessageIDs)
    }
}
