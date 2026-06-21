import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor SlashMemoryTopicRecorder: ConversationTopicPublishing {
    private(set) var payloads: [ConversationTopicEventPayload] = []

    func publishPersistedConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        transcriptSequence: Int
    ) async {
        _ = conversationID
        _ = transcriptSequence
        payloads.append(payload)
    }

    func publishTransientConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        runID: UUID,
        modelCallId: UUID?
    ) async {
        _ = conversationID
        _ = runID
        _ = modelCallId
        payloads.append(payload)
    }

    func publishConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload) async {
        _ = conversationID
        payloads.append(payload)
    }

    func surfaceIntents() -> [ClientSurfaceIntent] {
        let decoder = JSONDecoder()
        return payloads.compactMap { payload in
            guard payload.semanticKind == .surfaceIntent,
                  let json = payload.jsonUTF8,
                  let data = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(ClientSurfaceIntent.self, from: data)
        }
    }
}

@Suite("Slash command /memory", .serialized)
struct SlashCommandMemoryTests {
    private func makeMemorySession() async throws -> (HarnessRuntimeSession, UUID, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-slash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(
            config: .default,
            userConfigDir: root.appendingPathComponent("user", isDirectory: true)
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: CompactionConcurrencyCoordinator(),
            memoryService: memoryService,
            logger: nil
        )
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let manager = HarnessRuntimeSession(
            container: container,
            contextEngine: engine,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = Model(
            protocol: .openAIAPI,
            modelName: "slash:memory",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        _ = try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await manager.currentConversationID)
        guard var conversation = await manager.testing_modelConversation(conversationID: cid) else {
            throw NSError(domain: "SlashCommandMemoryTests", code: 1)
        }
        conversation.harnessPersistenceCwd = root.path
        await manager.persistenceDomain.replaceConversationInRegistry(conversation)
        let context = try memoryService.makeSessionContext(conversationID: cid, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: context)
        return (manager, cid, root, context.memoryDirectory)
    }

    private func collectSurfaceIntents(from response: ChatStreamResponse) async -> [ClientSurfaceIntent] {
        var intents: [ClientSurfaceIntent] = []
        for await partial in response.partialContent {
            if case .surfaceIntent(let intent) = partial {
                intents.append(intent)
            }
        }
        return intents
    }

    @Test("/memory rejects path traversal")
    func memoryRejectsTraversal() async throws {
        let (manager, cid, root, _) = try await makeMemorySession()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let response = try #require(
            await manager.testing_runSlashCommandIfNeeded("/memory ../../outside", conversationID: cid)
        )
        let intents = await collectSurfaceIntents(from: response)
        #expect(intents.isEmpty)
        let messages = try await manager.listCurrentMessages()
        #expect(messages.contains { $0.role == .assistant && $0.content.contains("Memory path not allowed") })
    }

    @Test("/memory default resolves MEMORY.md and emits surface intent")
    func memoryDefaultEmitsSurfaceIntent() async throws {
        let (manager, cid, root, _) = try await makeMemorySession()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let recorder = SlashMemoryTopicRecorder()
        await manager.setConversationTopicPublisher(recorder)
        let response = try #require(await manager.testing_runSlashCommandIfNeeded("/memory", conversationID: cid))
        let intents = await collectSurfaceIntents(from: response)
        #expect(intents.count == 1)
        #expect(intents[0].kind == .openFileForEdit)
        #expect(intents[0].scope == "memory")
        #expect(intents[0].filePath.hasSuffix("MEMORY.md"))
        #expect(FileManager.default.fileExists(atPath: intents[0].filePath))
        let topicIntents = await recorder.surfaceIntents()
        #expect(topicIntents.count == 1)
        #expect(topicIntents[0].filePath == intents[0].filePath)
    }

    @Test("/memory valid topic file emits openFileForEdit intent")
    func memoryTopicFileEmitsIntent() async throws {
        let (manager, cid, root, memoryDirectory) = try await makeMemorySession()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = AgentMemoryStore(memoryDirectory: memoryDirectory)
        try store.writeTopic(filename: "topic.md", content: "remember this")
        let response = try #require(
            await manager.testing_runSlashCommandIfNeeded("/memory topic.md", conversationID: cid)
        )
        let intents = await collectSurfaceIntents(from: response)
        #expect(intents.count == 1)
        #expect(intents[0].kind == .openFileForEdit)
        #expect(intents[0].label == "topic.md")
        #expect(intents[0].filePath.hasSuffix("topic.md"))
    }

    @Test("/memory rejects team subdirectory paths")
    func memoryRejectsTeamSubdirectory() async throws {
        let (manager, cid, root, _) = try await makeMemorySession()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let response = try #require(
            await manager.testing_runSlashCommandIfNeeded("/memory team/feedback_x.md", conversationID: cid)
        )
        let intents = await collectSurfaceIntents(from: response)
        #expect(intents.isEmpty)
        let messages = try await manager.listCurrentMessages()
        #expect(messages.contains { $0.role == .assistant && $0.content.contains("Memory path not allowed") })
    }
}
