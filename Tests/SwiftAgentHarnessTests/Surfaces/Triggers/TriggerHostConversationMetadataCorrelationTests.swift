import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerHostConversationMetadataCorrelation")
struct TriggerHostConversationMetadataCorrelationTests {
    @Test("fingerprint round-trips correlation triad")
    func fingerprintRoundTrip() {
        let trigger = HarnessTrigger(
            id: "webhook-1",
            source: .webhook,
            payload: "hello",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: TriggerCorrelation(
                rootId: "webhook-1",
                parentTriggerId: nil,
                correlationId: "webhook-1"
            )
        )
        let metadata = TriggerHostConversationMetadata.stampHostMetadata(
            existing: nil,
            trigger: trigger,
            sessionKey: "webhook:isolated:route"
        )
        let restored = TriggerHostConversationMetadata.triggerFromFingerprint(metadata)
        #expect(restored?.id == "webhook-1")
        #expect(restored?.correlation?.rootId == "webhook-1")
        #expect(restored?.correlation?.correlationId == "webhook-1")
    }
}
