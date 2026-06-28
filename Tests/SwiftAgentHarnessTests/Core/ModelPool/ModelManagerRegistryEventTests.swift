import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor StubResourceTopicHub: ModelPoolResourceTopicPublishing {
    var snapshots: [ModelsRegistryPayload] = []
    var events: [ModelsRegistryEventPayload] = []

    func broadcast(modelID: UUID, payload: ModelStatePayload) async {}

    func broadcastModelCalls(modelID: UUID, payload: ModelCallsPayload) async {}

    func broadcastPoolHealth(_ payload: PoolHealthPayload) async {}

    func cacheRegistrySnapshot(_ payload: ModelsRegistryPayload) async {
        snapshots.append(payload)
    }

    func broadcastModelsRegistryEvent(_ payload: ModelsRegistryEventPayload) async {
        events.append(payload)
    }

    func broadcastModelsRegistry(_ payload: ModelsRegistryPayload) async {
        snapshots.append(payload)
    }
}

@Suite("ModelManager → models/registry granular events")
struct ModelManagerRegistryEventTests {
    private static func makeModel(id: UUID = UUID(), name: String = "model") -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            routing: ModelRoutingMetadata(
                rateLimit: ModelRateLimitMetadata(requests: 9, tokens: 90_000, windowMs: 60_000)
            )
        )
    }

    @Test("addModels emits .added events for new entries and caches snapshot")
    func addEmitsAddedEvent() async throws {
        let hub = StubResourceTopicHub()
        let manager = ModelManager(
            registryTopicHub: hub,
            authProfileStore: AuthProfileStore(environment: [:])
        )
        let model = Self.makeModel(name: "first")
        try await manager.addModels([model])
        let snapshots = await hub.snapshots
        let events = await hub.events
        #expect(!snapshots.isEmpty)
        #expect(!events.isEmpty)
        let lastEvent = events.last
        #expect(lastEvent?.changes.contains(where: { $0.kind == .added && $0.modelID == model.id }) == true)
    }

    @Test("Adding the same model twice is a no-op (no second event)")
    func unchangedRegistryEmitsNothing() async throws {
        let hub = StubResourceTopicHub()
        let manager = ModelManager(
            registryTopicHub: hub,
            authProfileStore: AuthProfileStore(environment: [:])
        )
        let model = Self.makeModel(name: "stable")
        try await manager.addModels([model])
        let eventsAfterFirst = await hub.events.count
        try await manager.addModels([model])
        let eventsAfterSecond = await hub.events.count
        #expect(eventsAfterFirst == eventsAfterSecond)
        let snapshotsCount = await hub.snapshots.count
        #expect(snapshotsCount >= 2)
    }

    @Test("Cached snapshot stays current with the latest registry contents")
    func snapshotCacheStaysCurrent() async throws {
        let hub = StubResourceTopicHub()
        let manager = ModelManager(
            registryTopicHub: hub,
            authProfileStore: AuthProfileStore(environment: [:])
        )
        let first = Self.makeModel(name: "first")
        let second = Self.makeModel(name: "second")
        try await manager.addModels([first])
        try await manager.addModels([second])
        let lastSnapshot = await hub.snapshots.last
        #expect(lastSnapshot != nil)
        let names = lastSnapshot?.models.map(\.modelName).sorted() ?? []
        #expect(names == ["first", "second"])
        let routingValues = lastSnapshot?.models.compactMap { $0.routing?.rateLimit?.requests } ?? []
        #expect(routingValues == [9, 9])
    }
}
