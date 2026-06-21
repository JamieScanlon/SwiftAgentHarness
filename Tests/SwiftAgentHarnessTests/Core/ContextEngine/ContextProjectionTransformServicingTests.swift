import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("ContextProjectionTransformServicing")
struct ContextProjectionTransformServicingTests {
    private actor RecordingContextProjection: ContextProjectionTransformServicing {
        private(set) var lastGatingOverride: ContextCompactionGatingOptions?

        func transformedContextMessages(
            from originalMessages: [Message],
            conversation: ModelConversation,
            phase: ContextTransformInvocationPhase,
            configuration: HarnessRuntimeSession.Configuration,
            gatingOverride: ContextCompactionGatingOptions?
        ) async -> [Message] {
            let _ = (conversation, phase, configuration)
            lastGatingOverride = gatingOverride
            return originalMessages
        }

        func capturedGatingOverride() -> ContextCompactionGatingOptions? {
            lastGatingOverride
        }
    }

    @Test("existential call forwards gatingOverride")
    func existentialForwardsGatingOverride() async {
        let recorder = RecordingContextProjection()
        let projection: any ContextProjectionTransformServicing = recorder
        let conversation = ModelConversation(
            id: UUID(),
            model: Model(
                protocol: .openAIAPI,
                modelName: "gating-test",
                serverURL: URL(string: "http://localhost:1234")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            turns: [],
            interactionMode: .chat
        )
        _ = await projection.transformedContextMessages(
            from: [],
            conversation: conversation,
            phase: .initial,
            configuration: HarnessRuntimeSession.Configuration(),
            gatingOverride: .forcedReactiveRetry
        )
        #expect(await recorder.capturedGatingOverride() == .forcedReactiveRetry)
    }

    @Test("existential call forwards nil gatingOverride")
    func existentialForwardsNilGatingOverride() async {
        let recorder = RecordingContextProjection()
        let projection: any ContextProjectionTransformServicing = recorder
        let conversation = ModelConversation(
            id: UUID(),
            model: Model(
                protocol: .openAIAPI,
                modelName: "gating-test-nil",
                serverURL: URL(string: "http://localhost:1234")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            turns: [],
            interactionMode: .chat
        )
        _ = await projection.transformedContextMessages(
            from: [],
            conversation: conversation,
            phase: .initial,
            configuration: HarnessRuntimeSession.Configuration(),
            gatingOverride: nil
        )
        #expect(await recorder.capturedGatingOverride() == nil)
    }
}
