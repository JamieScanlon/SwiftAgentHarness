import Foundation

/// Publisher-facing API for model pool resource topics (`model/{id}/state`, `pool/health`, `models/registry`).
/// Production publishers should depend on a communication-layer facade instead of concrete hubs.
public protocol ModelPoolResourceTopicPublishing: Sendable {
    func broadcast(modelID: UUID, payload: ModelStatePayload) async
    func broadcastModelCalls(modelID: UUID, payload: ModelCallsPayload) async
    func broadcastPoolHealth(_ payload: PoolHealthPayload) async
    /// Refreshes the cached `models/registry` snapshot served on subscribe. Does **not** fan
    /// out an event envelope; granular deltas are emitted via ``broadcastModelsRegistryEvent(_:)``.
    func cacheRegistrySnapshot(_ payload: ModelsRegistryPayload) async
    /// Fans out a granular per-model `models/registry` change event.
    func broadcastModelsRegistryEvent(_ payload: ModelsRegistryEventPayload) async
    /// Full-snapshot fan-out. Default-implemented as `cacheRegistrySnapshot(payload)` so
    /// callers can refresh snapshot state without emitting a granular event.
    func broadcastModelsRegistry(_ payload: ModelsRegistryPayload) async
}

public extension ModelPoolResourceTopicPublishing {
    /// Default routes `broadcastModelsRegistry` to `cacheRegistrySnapshot` so producers
    /// can update the cached snapshot for new subscribers.
    func broadcastModelsRegistry(_ payload: ModelsRegistryPayload) async {
        await cacheRegistrySnapshot(payload)
    }
}

extension CommunicationLayer: ModelPoolResourceTopicPublishing {
    public func broadcast(modelID: UUID, payload: ModelStatePayload) async {
        await modelPoolTopics.broadcast(modelID: modelID, payload: payload)
    }

    public func broadcastPoolHealth(_ payload: PoolHealthPayload) async {
        await modelPoolTopics.broadcastPoolHealth(payload)
    }

    public func broadcastModelCalls(modelID: UUID, payload: ModelCallsPayload) async {
        await modelPoolTopics.broadcastModelCalls(modelID: modelID, payload: payload)
    }

    public func cacheRegistrySnapshot(_ payload: ModelsRegistryPayload) async {
        await modelPoolTopics.cacheRegistrySnapshot(payload)
    }

    public func broadcastModelsRegistryEvent(_ payload: ModelsRegistryEventPayload) async {
        await modelPoolTopics.broadcastModelsRegistryEvent(payload)
    }

    public func broadcastModelsRegistry(_ payload: ModelsRegistryPayload) async {
        await modelPoolTopics.broadcastModelsRegistry(payload)
    }
}
