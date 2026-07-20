import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment projection checkpoint wire v3")
struct AttachmentProjectionCheckpointWireTests {
    private func sampleDecision(
        disposition: ConversationAttachmentProjectionDisposition = .summarize
    ) -> ConversationAttachmentProjectionDecision {
        ConversationAttachmentProjectionDecision(
            attachmentID: UUID(),
            attachmentName: "notes.txt",
            attachmentKind: "document",
            disposition: disposition,
            reason: "within_summary_budget"
        )
    }

    @Test("schema v3 round-trips effective and target decisions")
    func v3RoundTrip() throws {
        let effective = [sampleDecision(disposition: .inline)]
        let target = [sampleDecision(disposition: .summarize)]
        let wire = AttachmentProjectionCheckpointWire(
            schemaVersion: 3,
            basedOnEventID: 42,
            projectionFingerprint: "fp-v3",
            decisions: effective,
            targetDecisions: target,
            materializedBlocks: [],
            accessWatermarkTurnIndex: 17,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoded = try ConversationEventCodec.encode(wire)
        let decoded = try #require(ConversationEventCodec.decode(AttachmentProjectionCheckpointWire.self, from: encoded))
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.decisions == effective)
        #expect(decoded.targetDecisions == target)
        #expect(decoded.accessWatermarkTurnIndex == 17)
        #expect(decoded.projectionFingerprint == "fp-v3")
    }

    @Test("schema v2 decodes with nil target decisions and watermark")
    func v2BackwardCompatibility() throws {
        let effective = [sampleDecision()]
        let v2JSON = """
        {
          "schemaVersion": 2,
          "basedOnEventID": 7,
          "projectionFingerprint": "fp-v2",
          "decisions": [
            {
              "attachmentID": "\(effective[0].attachmentID.uuidString)",
              "attachmentName": "notes.txt",
              "attachmentKind": "document",
              "disposition": "summarize",
              "reason": "within_summary_budget"
            }
          ],
          "materializedBlocks": [],
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoded = try #require(
            ConversationEventCodec.decode(
                AttachmentProjectionCheckpointWire.self,
                from: v2JSON
            )
        )
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.decisions == effective)
        #expect(decoded.targetDecisions == nil)
        #expect(decoded.accessWatermarkTurnIndex == nil)
    }
}
