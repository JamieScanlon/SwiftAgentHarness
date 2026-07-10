import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Slash command /active-memory", .serialized, .timeLimit(.minutes(1)))
struct SlashCommandActiveMemoryTests {
    private static let controlOverrideEnvKey = ActiveMemoryControlStore.overrideEnvKey

    private static func withIsolatedRoots(
        _ body: (HarnessRuntimeSession, UUID, ActiveMemoryControlStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-slash-\(UUID().uuidString)", isDirectory: true)
        let workRoot = root.appendingPathComponent("workspace", isDirectory: true)
        let controlRoot = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: controlRoot, withIntermediateDirectories: true)

        let previousControl = ProcessInfo.processInfo.environment[controlOverrideEnvKey]
        setenv(controlOverrideEnvKey, controlRoot.path, 1)
        defer {
            if let previousControl {
                setenv(controlOverrideEnvKey, previousControl, 1)
            } else {
                unsetenv(controlOverrideEnvKey)
            }
            try? FileManager.default.removeItem(at: root)
        }

        let container = try HarnessTestModelContainer.makeInMemory()
        let manager = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = Model(
            protocol: .openAIAPI,
            modelName: "slash:active-memory",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let conversationID = try await manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            cwd: workRoot.path
        )
        let control = ActiveMemoryControlStore(rootDirectory: controlRoot)
        try await body(manager, conversationID, control)
    }

    @Test("/active-memory status reports knobs")
    func status() async throws {
        try await Self.withIsolatedRoots { manager, conversationID, _ in
            let response = try #require(
                await manager.testing_runSlashCommandIfNeeded("/active-memory status", conversationID: conversationID)
            )
            #expect(response != nil)
            let messages = try await manager.listCurrentMessages()
            let assistant = try #require(messages.last { $0.role == .assistant })
            #expect(assistant.content.contains("Active memory (session):"))
            #expect(assistant.content.contains("queryMode:"))
        }
    }

    @Test("/active-memory off --global toggles control store")
    func globalToggle() async throws {
        try await Self.withIsolatedRoots { manager, conversationID, control in
            _ = try #require(
                await manager.testing_runSlashCommandIfNeeded(
                    "/active-memory off --global",
                    conversationID: conversationID
                )
            )
            #expect(!control.isEnabled())
            _ = try #require(
                await manager.testing_runSlashCommandIfNeeded(
                    "/active-memory on --global",
                    conversationID: conversationID
                )
            )
            #expect(control.isEnabled())
        }
    }

    @Test("/active-memory off sets session metadata")
    func sessionToggle() async throws {
        try await Self.withIsolatedRoots { manager, conversationID, _ in
            _ = try #require(
                await manager.testing_runSlashCommandIfNeeded("/active-memory off", conversationID: conversationID)
            )
            let conv = try #require(await manager.persistenceDomain.modelConversation(id: conversationID))
            #expect(!ActiveMemorySessionFlags.isSessionEnabled(metadata: conv.metadata))
            _ = try #require(
                await manager.testing_runSlashCommandIfNeeded("/active-memory on", conversationID: conversationID)
            )
            let onConv = try #require(await manager.persistenceDomain.modelConversation(id: conversationID))
            #expect(ActiveMemorySessionFlags.isSessionEnabled(metadata: onConv.metadata))
        }
    }
}
