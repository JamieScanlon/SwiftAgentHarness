import Foundation
import Logging

/// Short-circuits permanent `dream` cron fires into the memory bridge (no LLM turn).
enum MemoryDreamingDeliver {
    static func wrap(
        dispatch: TriggerDispatchService,
        bridge: MemoryDreamingBridge,
        logger: Logger? = nil
    ) -> @Sendable (HarnessTrigger) async throws -> TriggerActivationResult {
        { trigger in
            if MemoryDreamingBridge.isDreamTrigger(trigger) {
                do {
                    let swept = try await bridge.runDueSweeps()
                    logger?.info("[Dreaming] cron deliver swept \(swept) director\(swept == 1 ? "y" : "ies")")
                } catch {
                    logger?.error("[Dreaming] cron deliver failed: \(error.localizedDescription)")
                }
                return TriggerActivationResult(decision: .admitted, sessionID: nil)
            }
            return try await dispatch.ingest(trigger)
        }
    }
}
