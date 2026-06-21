import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("API layer mode registry transport")
struct APILayerModeRegistryTransportTests {
    @Test("mode registry change publishes mode_registry_changed on trace/server")
    func modeRegistryChangedPublishesServerTraceEvent() async throws {
        let traceHub = TraceTopicHub()
        let communicationLayer = CommunicationLayer(
            modelPoolTopics: ModelStateTopicHub(),
            conversationEvents: ConversationEventsTopicHub(),
            conversationState: ConversationStateTopicHub(),
            traceTopics: traceHub,
            subAgentLifecycle: SubAgentLifecycleTopicHub(),
            capabilityRegistries: CapabilityRegistryTopicHub(),
            conversationsRegistry: ConversationsRegistryTopicHub()
        )
        let api = APILayer(port: 0)
        await api.setCommunicationWireResources(
            layer: communicationLayer,
            coordinator: ModelInvocationCoordinator()
        )

        final class Collector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = Collector()
        let token = await traceHub.registerConnection { line in
            collector.lines.append(line.json)
        }
        try await traceHub.subscribe(token: token, topic: TraceTopicFormat.serverTopic, since: nil) {
            TraceTopicPayload(spans: [])
        }

        await api.publishModeRegistryChangedOnWire()

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let eventData = try #require(collector.lines.last?.data(using: .utf8))
        let event = try decoder.decode(CommResourceTopicMessage<TraceTopicPayload>.self, from: eventData)
        #expect(event.kind == .event)
        #expect(event.value?.spans.contains(where: { $0.name == "mode_registry_changed" }) == true)
    }
}
