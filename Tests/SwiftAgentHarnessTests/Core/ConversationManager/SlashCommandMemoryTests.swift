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

private enum SlashCommandMemorySupport {
    static let memoryOverrideEnvKey = AgentMemoryPathResolver.overrideEnvKey

    static func makeContainer() throws -> ModelContainer {
        try HarnessTestModelContainer.makeInMemory()
    }

    static func makeModel(name: String = "slash:memory") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func makeManager(container: ModelContainer) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
    }

    static func withIsolatedMemory<T>(
        _ body: (HarnessRuntimeSession, UUID, URL, URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-slash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryDir = root.appendingPathComponent("memory", isDirectory: true)
        let workRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)

        let previousOverride = ProcessInfo.processInfo.environment[memoryOverrideEnvKey]
        setenv(memoryOverrideEnvKey, memoryDir.path, 1)
        defer {
            if let previousOverride {
                setenv(memoryOverrideEnvKey, previousOverride, 1)
            } else {
                unsetenv(memoryOverrideEnvKey)
            }
            try? FileManager.default.removeItem(at: root)
        }

        let container = try makeContainer()
        let manager = makeManager(container: container)
        let model = makeModel()
        let conversationID = try await manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            cwd: workRoot.path
        )
        return try await body(manager, conversationID, workRoot, memoryDir)
    }
}

@Suite("Slash command /memory", .serialized, .timeLimit(.minutes(1)))
struct SlashCommandMemoryTests {
    @Test("/memory default resolves MEMORY.md and emits surface intent")
    func memoryDefaultEmitsSurfaceIntent() async throws {
        try await SlashCommandMemorySupport.withIsolatedMemory { manager, conversationID, _, _ in
            let recorder = SlashMemoryTopicRecorder()
            await manager.setConversationTopicPublisher(recorder)
            let response = try #require(
                await manager.testing_runSlashCommandIfNeeded("/memory", conversationID: conversationID)
            )
            let intents = await HarnessAsyncTestSupport.surfaceIntents(from: response)
            #expect(intents.count == 1)
            #expect(intents[0].kind == .openFileForEdit)
            #expect(intents[0].scope == "memory")
            #expect(intents[0].filePath.hasSuffix("MEMORY.md"))
            #expect(FileManager.default.fileExists(atPath: intents[0].filePath))
            let topicIntents = await recorder.surfaceIntents()
            #expect(topicIntents.count == 1)
            #expect(topicIntents[0].filePath == intents[0].filePath)
        }
    }

    @Test("/memory valid topic file emits openFileForEdit intent")
    func memoryTopicFileEmitsIntent() async throws {
        try await SlashCommandMemorySupport.withIsolatedMemory { manager, conversationID, _, memoryDirectory in
            let store = AgentMemoryStore(memoryDirectory: memoryDirectory)
            try store.writeTopic(filename: "topic.md", content: "remember this")
            let response = try #require(
                await manager.testing_runSlashCommandIfNeeded("/memory topic.md", conversationID: conversationID)
            )
            let intents = await HarnessAsyncTestSupport.surfaceIntents(from: response)
            #expect(intents.count == 1)
            #expect(intents[0].kind == .openFileForEdit)
            #expect(intents[0].label == "topic.md")
            #expect(intents[0].filePath.hasSuffix("topic.md"))
        }
    }

    @Test("/memory rejects team subdirectory paths")
    func memoryRejectsTeamSubdirectory() async throws {
        try await SlashCommandMemorySupport.withIsolatedMemory { manager, conversationID, _, _ in
            let response = try #require(
                await manager.testing_runSlashCommandIfNeeded("/memory team/feedback_x.md", conversationID: conversationID)
            )
            let intents = await HarnessAsyncTestSupport.surfaceIntents(from: response)
            #expect(intents.isEmpty)
            let messages = try await manager.listCurrentMessages()
            #expect(messages.contains { $0.role == .assistant && $0.content.contains("Memory path not allowed") })
        }
    }

    @Test("repeated /memory reuses bootstrapped session without error")
    func repeatedMemorySlashReusesBootstrap() async throws {
        try await SlashCommandMemorySupport.withIsolatedMemory { manager, conversationID, _, _ in
            let first = try #require(
                await manager.testing_runSlashCommandIfNeeded("/memory", conversationID: conversationID)
            )
            let firstIntents = await HarnessAsyncTestSupport.surfaceIntents(from: first)
            #expect(firstIntents.count == 1)

            let second = try #require(
                await manager.testing_runSlashCommandIfNeeded("/memory", conversationID: conversationID)
            )
            let secondIntents = await HarnessAsyncTestSupport.surfaceIntents(from: second)
            #expect(secondIntents.count == 1)
            #expect(secondIntents[0].filePath == firstIntents[0].filePath)
        }
    }
}
