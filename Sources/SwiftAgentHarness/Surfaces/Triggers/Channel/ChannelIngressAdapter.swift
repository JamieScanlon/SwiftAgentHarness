import Foundation

struct ChannelIngressAdapter: Sendable {
    let dispatch: TriggerDispatchService

    func ingest(_ trigger: HarnessTrigger) async throws -> TriggerActivationResult {
        try await dispatch.ingest(trigger)
    }
}
