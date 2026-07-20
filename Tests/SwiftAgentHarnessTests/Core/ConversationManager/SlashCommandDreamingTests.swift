import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Slash command /dreaming", .serialized, .timeLimit(.minutes(1)))
struct SlashCommandDreamingTests {
    private static let controlOverrideEnvKey = DreamingControlStore.overrideEnvKey

    /// Do not touch `SAH_MEMORY_PATH_OVERRIDE` — that env is shared with `/memory` slash tests and races across suites.
    private static func withIsolatedRoots(
        _ body: (HarnessRuntimeSession, UUID, DreamingControlStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-slash-\(UUID().uuidString)", isDirectory: true)
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
            modelName: "slash:dreaming",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let conversationID = try await manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            cwd: workRoot.path
        )
        let control = DreamingControlStore(rootDirectory: controlRoot)
        try await body(manager, conversationID, control)
    }

    @Test("/dreaming status reports on/off and cron")
    func status() async throws {
        try await Self.withIsolatedRoots { manager, conversationID, control in
            let previous = control.isEnabled()
            defer { try? control.setEnabled(previous) }
            try control.setEnabled(true)
            let response = try #require(
                await manager.testing_runSlashCommandIfNeeded("/dreaming status", conversationID: conversationID)
            )
            #expect(response != nil)
            let messages = try await manager.listCurrentMessages()
            let assistant = try #require(messages.last { $0.role == .assistant })
            #expect(assistant.content.contains("Dreaming:"))
            #expect(assistant.content.contains("Cron:"))
        }
    }

    @Test("/dreaming off then on toggles control store")
    func toggle() async throws {
        try await Self.withIsolatedRoots { manager, conversationID, control in
            let previous = control.isEnabled()
            defer { try? control.setEnabled(previous) }

            _ = try #require(
                await manager.testing_runSlashCommandIfNeeded("/dreaming off", conversationID: conversationID)
            )
            #expect(!control.isEnabled())
            let offMessages = try await manager.listCurrentMessages()
            let offAssistant = try #require(offMessages.last { $0.role == .assistant })
            #expect(offAssistant.content.lowercased().contains("disabled"))

            _ = try #require(
                await manager.testing_runSlashCommandIfNeeded("/dreaming on", conversationID: conversationID)
            )
            #expect(control.isEnabled())
            let onMessages = try await manager.listCurrentMessages()
            let onAssistant = try #require(onMessages.last { $0.role == .assistant })
            #expect(onAssistant.content.lowercased().contains("enabled"))
        }
    }

    @Test("/dreaming unknown arg shows usage")
    func usage() async throws {
        try await Self.withIsolatedRoots { manager, conversationID, _ in
            _ = try #require(
                await manager.testing_runSlashCommandIfNeeded("/dreaming bounce", conversationID: conversationID)
            )
            let messages = try await manager.listCurrentMessages()
            let assistant = try #require(messages.last { $0.role == .assistant })
            #expect(assistant.content.contains("Usage: /dreaming status|explain|on|off"))
        }
    }

    @Test("/dreaming explain with no report is clear")
    func explainEmpty() async throws {
        try await Self.withIsolatedRoots { manager, conversationID, _ in
            _ = try #require(
                await manager.testing_runSlashCommandIfNeeded("/dreaming explain", conversationID: conversationID)
            )
            let messages = try await manager.listCurrentMessages()
            let assistant = try #require(messages.last { $0.role == .assistant })
            #expect(
                assistant.content.contains("No sweep report yet")
                    || assistant.content.contains("No workspace memory directory")
            )
        }
    }
}
