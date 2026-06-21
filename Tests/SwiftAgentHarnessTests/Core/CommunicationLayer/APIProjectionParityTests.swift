import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private func makeModel(name: String = "test:latest") -> Model {
    Model(
        protocol: .ollama,
        modelName: name,
        serverURL: URL(string: "http://localhost:11434")!,
        capabilities: [],
        modelProtocol: .ollama
    )
}

private func makeConversationAPI(_ runtimeSession: HarnessRuntimeSession) async -> APILayerConversationAdapter {
    await makeSplitConversationAdapter(runtimeSession: runtimeSession)
}

private func seedConversation(host: HarnessRuntimeSession, model: Model, userInputTrustRaw: String? = nil) async throws -> UUID {
    let user = Message(
        id: UUID(),
        role: .user,
        content: "Hello",
        timestamp: Date(),
        toolCalls: [],
        inputTrustRaw: userInputTrustRaw
    )
    return try await HarnessConversationTestFixtures.seedRegistryConversation(
        host: host,
        model: model,
        extraMessages: [user]
    )
}

@Suite("API projection parity", .serialized)
struct APIProjectionParityTests {

    @Test("apiListMessagesThrowing matches currentMessages after selection")
    func listMessagesMatchesPublishedProjection() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "api-parity-list")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let convID = try await seedConversation(host: fixture.host, model: model)
        let runtimeSession = fixture.host
        let conversationAPI = await makeConversationAPI(runtimeSession)
        try await runtimeSession.selectConversation(conversationID: convID)

        await runtimeSession.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .assistant, content: "projected-only", timestamp: Date(), toolCalls: []),
        ])

        let api = try await conversationAPI.apiListMessagesThrowing(conversationID: convID)
        let published = await runtimeSession.currentMessages
        #expect(api.count == published.count)
        for (a, b) in zip(api, published) {
            #expect(a.id == b.id)
            #expect(a.content == b.content)
            #expect(a.role == b.role)
        }
    }

    @Test("apiGetConversation transcript matches apiListMessagesThrowing when conversation is selected")
    func getConversationMatchesListWhenSelected() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "api-parity-get")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let convID = try await seedConversation(host: fixture.host, model: model)
        let runtimeSession = fixture.host
        let conversationAPI = await makeConversationAPI(runtimeSession)
        try await runtimeSession.selectConversation(conversationID: convID)

        await runtimeSession.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .assistant, content: "orch-line", timestamp: Date(), toolCalls: []),
        ])

        guard let row = await conversationAPI.apiGetConversation(id: convID) else {
            Issue.record("missing conversation")
            return
        }
        let listed = try await conversationAPI.apiListMessagesThrowing(conversationID: convID)
        #expect(row.messages.count == listed.count)
        for (r, e) in zip(row.messages, listed) {
            #expect(r.id == e.id)
            #expect(r.content == e.content)
        }
    }

    @Test("User inputTrustRaw round-trips through apiListMessagesThrowing")
    func inputTrustRoundTripsThroughListMessages() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "api-parity-trust")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let convID = try await seedConversation(
            host: fixture.host,
            model: model,
            userInputTrustRaw: MessageInputTrust.automation.rawValue
        )
        let runtimeSession = fixture.host
        let conversationAPI = await makeConversationAPI(runtimeSession)
        try await runtimeSession.selectConversation(conversationID: convID)

        let listed = try await conversationAPI.apiListMessagesThrowing(conversationID: convID)
        let userMsg = listed.first { $0.role == .user }
        #expect(userMsg?.inputTrustRaw == MessageInputTrust.automation.rawValue)
    }

    @Test("apiGetConversationWithDerived includes raw and derived arrays")
    func getConversationWithDerivedIncludesArrays() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "api-parity-derived")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let convID = try await seedConversation(host: fixture.host, model: model)
        let runtimeSession = fixture.host
        let conversationAPI = await makeConversationAPI(runtimeSession)

        let payload = await conversationAPI.apiGetConversationWithDerived(id: convID)
        #expect(payload != nil)
        #expect(payload?.conversation.id == convID)
        #expect((payload?.rawEvents.count ?? 0) >= 1)
        #expect(payload?.derivedEvents != nil)
    }

    @Test("apiProjectConversation returns projected messages with metadata")
    func projectConversationReturnsProjectionPayload() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "api-parity-project")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let convID = try await seedConversation(host: fixture.host, model: model)
        let runtimeSession = fixture.host
        let conversationAPI = await makeConversationAPI(runtimeSession)

        let response = try await conversationAPI.apiProjectConversation(
            conversationID: convID,
            request: ConversationProjectRequest()
        )
        #expect(response.projectedMessages.count >= 1)
        #expect(response.metadata.frontierEventID >= 0)
    }
}
