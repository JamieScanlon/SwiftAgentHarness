import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerDelegatedDispatchService")
struct TriggerDelegatedDispatchServiceTests {
    final class MockSpawn: TriggerDelegatedSpawning, @unchecked Sendable {
        var lastRequest: SubAgentSpawnRequest?
        var lastParent: UUID?
        var lastPrompt: String?

        func spawnDelegatedSubAgent(
            parentConversationID: UUID,
            request: SubAgentSpawnRequest,
            modelOverride: Model?
        ) async throws -> UUID {
            lastParent = parentConversationID
            lastRequest = request
            return UUID()
        }

        func sendMessageAndRun(childConversationID: UUID, prompt: String) async throws {
            lastPrompt = prompt
        }

        func lastAssistantText(childConversationID: UUID) async -> String? { nil }
    }

    @Test("builds isolated background spawn request")
    func spawnRequestShape() async throws {
        let mock = MockSpawn()
        let registry = TriggerDelegatedRunRegistry()
        let service = TriggerDelegatedDispatchService(spawn: mock, runRegistry: registry)
        let host = UUID()
        let trigger = HarnessTrigger(
            id: "wh-1",
            source: .webhook,
            sourceMetadata: [
                "routeName": "alerts",
                "delegateProfileJSON": try #require(
                    TriggerDelegateProfileCodec.encodeToMetadata(
                        TriggerDelegateProfile(runInBackground: false, taskDescription: "triage")
                    )
                ),
            ],
            payload: "event",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .delegated
        )
        let built = TriggerPromptBuilder().build(trigger: trigger)
        let child = try await service.dispatch(
            trigger: trigger,
            hostConversationID: host,
            sessionKey: "webhook:delegated:alerts",
            built: built
        )
        #expect(mock.lastParent == host)
        #expect(mock.lastRequest?.context == .isolated)
        #expect(mock.lastRequest?.runInBackground == false)
        #expect(mock.lastRequest?.interactionMode == "trigger-delegate")
        #expect(mock.lastRequest?.taskDescription == "triage")
        let record = await registry.record(forChildConversationID: child)
        #expect(record?.trigger.id == "wh-1")
    }

    @Test("inlines provenance reminder into delegated prompt")
    func inlineProvenanceReminder() async throws {
        let mock = MockSpawn()
        let service = TriggerDelegatedDispatchService(
            spawn: mock,
            runRegistry: TriggerDelegatedRunRegistry()
        )
        let trigger = HarnessTrigger(
            id: "wh-2",
            source: .webhook,
            sourceMetadata: [
                "delegateProfileJSON": try #require(
                    TriggerDelegateProfileCodec.encodeToMetadata(
                        TriggerDelegateProfile(runInBackground: false)
                    )
                ),
            ],
            payload: "event",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .delegated
        )
        let built = TriggerPromptBuilder().build(trigger: trigger)
        _ = try await service.dispatch(
            trigger: trigger,
            hostConversationID: UUID(),
            sessionKey: "webhook:delegated:alerts",
            built: built
        )
        #expect(mock.lastRequest?.prompt?.contains("[trigger-context]") == true)
        #expect(mock.lastRequest?.prompt?.contains("[trigger]") == true)
        #expect(mock.lastPrompt?.hasPrefix("[trigger-context]") == true)
    }
}
