import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("RuntimeStreamingOrchestrationService")
struct RuntimeStreamingOrchestrationServiceTests {
    private func makeService() async throws -> (RuntimeStreamingOrchestrationService, HarnessRuntimeSession) {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let session = HarnessConversationTestFixtures.makeRuntimeSession(container: container)
        let service = RuntimeStreamingOrchestrationService(
            agentRuntime: await session.agentRuntimeSessionService,
            conversationReplay: await session.conversationReplayService
        )
        return (service, session)
    }

    @Test("cancel message stream reaches agent runtime")
    func cancelMessageStream() async throws {
        let (service, _) = try await makeService()
        await service.apiCancelMessageStream()
    }

    @Test("replay and run queries reach replay and agent runtime services")
    func replayAndRunQueries() async throws {
        let (service, _) = try await makeService()
        let conversationID = UUID()
        let runID = UUID()

        let replayActive = await service.apiIsConversationReplayActive(conversationID: conversationID)
        let runs = await service.apiListConversationRuns(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 10, cursor: nil)
        )
        let run = await service.apiGetConversationRun(
            conversationID: conversationID,
            runID: runID,
            includeProjectionDetail: true
        )

        #expect(replayActive == false)
        #expect(runs.runs.isEmpty)
        #expect(run == nil)
    }
}
