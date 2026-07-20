import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment rung coordinator")
struct AttachmentRungCoordinatorTests {
    private let recency = ContextEngineAttachmentRecencyPolicyInput(promoteHotSetOnCompaction: 2)

    private func descriptor(
        id: UUID = UUID(),
        byteSize: Int64 = 500,
        addedAt: Date = Date()
    ) -> ConversationAttachmentDescriptor {
        ConversationAttachmentDescriptor(
            id: id,
            kind: "document",
            name: "doc-\(id.uuidString.prefix(4)).txt",
            mimeType: "text/plain",
            byteSize: byteSize,
            addedAt: addedAt
        )
    }

    private func decision(
        for descriptor: ConversationAttachmentDescriptor,
        disposition: ConversationAttachmentProjectionDisposition,
        reason: String
    ) -> ConversationAttachmentProjectionDecision {
        ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: disposition,
            reason: reason
        )
    }

    @Test("target rung changes are held until a cache break event")
    func holdsRungWithoutBreakEvent() {
        let attachment = descriptor()
        let prior = [decision(for: attachment, disposition: .inline, reason: "within_inline_budget")]
        let target = [decision(for: attachment, disposition: .summarize, reason: "recency_cold")]
        let natural = prior
        let access = AttachmentAccessIndex(currentTurnIndex: 1, recordsByAttachmentID: [:])

        let coordinated = AttachmentRungCoordinator.coordinate(
            catalog: [attachment],
            targetDecisions: target,
            priorDecisions: prior,
            naturalDecisions: natural,
            accessIndex: access,
            pendingBreakEvents: [],
            recencyPolicy: recency
        )

        #expect(coordinated.effective[0].disposition == .inline)
        #expect(coordinated.effective[0].reason.contains("hysteresis_hold"))
        #expect(coordinated.target[0].disposition == .summarize)
    }

    @Test("cache break events apply pending target rung")
    func appliesTargetOnBreakEvent() {
        let attachment = descriptor()
        let prior = [decision(for: attachment, disposition: .inline, reason: "within_inline_budget")]
        let target = [decision(for: attachment, disposition: .summarize, reason: "recency_cold")]
        let natural = prior
        let access = AttachmentAccessIndex(currentTurnIndex: 1, recordsByAttachmentID: [:])

        let coordinated = AttachmentRungCoordinator.coordinate(
            catalog: [attachment],
            targetDecisions: target,
            priorDecisions: prior,
            naturalDecisions: natural,
            accessIndex: access,
            pendingBreakEvents: [.cacheExpiry],
            recencyPolicy: recency
        )

        #expect(coordinated.effective[0].disposition == .summarize)
        #expect(!coordinated.effective[0].reason.contains("hysteresis_hold"))
    }

    @Test("compaction commit promotes recently accessed attachments one rung")
    func compactionPromotesHotSet() {
        let hot = descriptor(addedAt: Date(timeIntervalSince1970: 2))
        let cold = descriptor(addedAt: Date(timeIntervalSince1970: 1))
        let catalog = [hot, cold]
        let prior = [
            decision(for: hot, disposition: .searchOnly, reason: "over_budget"),
            decision(for: cold, disposition: .searchOnly, reason: "over_budget"),
        ]
        let target = prior
        let natural = [
            decision(for: hot, disposition: .inline, reason: "within_inline_budget"),
            decision(for: cold, disposition: .inline, reason: "within_inline_budget"),
        ]
        let access = AttachmentAccessIndex(
            currentTurnIndex: 10,
            recordsByAttachmentID: [
                hot.id: AttachmentAccessRecord(lastAccessTurnIndex: 9, accessCount: 2),
                cold.id: AttachmentAccessRecord(lastAccessTurnIndex: 1, accessCount: 1),
            ]
        )
        let singlePromotionRecency = ContextEngineAttachmentRecencyPolicyInput(promoteHotSetOnCompaction: 1)

        let coordinated = AttachmentRungCoordinator.coordinate(
            catalog: catalog,
            targetDecisions: target,
            priorDecisions: prior,
            naturalDecisions: natural,
            accessIndex: access,
            pendingBreakEvents: [.compactionCommit],
            recencyPolicy: singlePromotionRecency
        )

        let byID = Dictionary(uniqueKeysWithValues: coordinated.effective.map { ($0.attachmentID, $0) })
        #expect(byID[hot.id]?.disposition == .summarize)
        #expect(byID[hot.id]?.reason.contains("compaction_hot_set_promotion") == true)
        #expect(byID[cold.id]?.disposition == .searchOnly)
    }
}
