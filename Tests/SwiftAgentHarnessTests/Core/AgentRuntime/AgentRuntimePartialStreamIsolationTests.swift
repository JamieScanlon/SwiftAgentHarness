import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntime partial stream isolation")
struct AgentRuntimePartialStreamIsolationTests {
    @Test("concurrent partial streams are isolated by runID")
    func concurrentPartialStreamsIsolatedByRunID() async throws {
        let service = try makeMinimalAgentRuntimeSessionService()
        let run1 = UUID()
        let run2 = UUID()
        let conversation1 = UUID()
        let conversation2 = UUID()

        let stream1 = await service.beginAgentLoopPartialStream(runID: run1)
        let stream2 = await service.beginAgentLoopPartialStream(runID: run2)

        let collector1 = Task { await collectTextPartials(from: stream1) }
        let collector2 = Task { await collectTextPartials(from: stream2) }

        await service.publishAgentLoopDelta(.text("A"), conversationID: conversation1, runID: run1)
        await service.publishAgentLoopDelta(.text("B"), conversationID: conversation2, runID: run2)

        await service.finishAgentLoopPartialStream(runID: run1)

        let partials1 = await collector1.value
        #expect(partials1 == ["A"])

        await service.publishAgentLoopDelta(.text("C"), conversationID: conversation2, runID: run2)
        await service.finishAgentLoopPartialStream(runID: run2)

        let partials2 = await collector2.value
        #expect(partials2 == ["B", "C"])
        #expect(!partials2.contains("A"))
    }

    private func makeMinimalAgentRuntimeSessionService() throws -> AgentRuntimeSessionService {
        try MinimalAgentRuntimeSession.make()
    }

    private func collectTextPartials(from stream: AsyncStream<ChatStreamingPartial>) async -> [String] {
        var values: [String] = []
        for await partial in stream {
            if case .text(let text) = partial {
                values.append(text)
            }
        }
        return values
    }
}
