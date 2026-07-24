import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment recency projection policy")
struct AttachmentRecencyProjectionPolicyTests {
    private let policy = ContextEngineAttachmentProjectionPolicyInput(
        inlineByteLimit: 10_000,
        summarizeByteLimit: 100_000
    )
    private let recency = ContextEngineAttachmentRecencyPolicyInput(
        hotAccessTurns: 3,
        demoteInlineAfterTurns: 8,
        demoteDigestAfterTurns: 20,
        hysteresisTurnMargin: 2,
        maxInlineImages: 2
    )

    private func descriptor(
        id: UUID = UUID(),
        kind: String = "document",
        byteSize: Int64 = 500,
        addedAt: Date = Date()
    ) -> ConversationAttachmentDescriptor {
        ConversationAttachmentDescriptor(
            id: id,
            kind: kind,
            name: "\(kind)-\(id.uuidString.prefix(4)).bin",
            mimeType: kind == "image" ? "image/png" : "text/plain",
            byteSize: byteSize,
            addedAt: addedAt
        )
    }

    private func decision(
        for descriptor: ConversationAttachmentDescriptor,
        disposition: ConversationAttachmentProjectionDisposition,
        reason: String = "within_inline_budget"
    ) -> ConversationAttachmentProjectionDecision {
        ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: disposition,
            reason: reason
        )
    }

    private func accessIndex(
        currentTurnIndex: Int,
        lastAccessTurnIndex: Int,
        attachmentID: UUID
    ) -> AttachmentAccessIndex {
        AttachmentAccessIndex(
            currentTurnIndex: currentTurnIndex,
            recordsByAttachmentID: [
                attachmentID: AttachmentAccessRecord(
                    lastAccessTurnIndex: lastAccessTurnIndex,
                    accessCount: 1
                ),
            ]
        )
    }

    @Test("cold inline demotes to digest after hysteresis threshold")
    func coldInlineDemotesToDigest() {
        let attachment = descriptor()
        let natural = [decision(for: attachment, disposition: .inline)]
        let access = accessIndex(currentTurnIndex: 20, lastAccessTurnIndex: 5, attachmentID: attachment.id)
        let demoted = AttachmentRecencyProjectionPolicy.applyRecencyDemotion(
            decisions: natural,
            catalog: [attachment],
            accessIndex: access,
            recencyPolicy: recency
        )
        #expect(demoted[0].disposition == .summarize)
        #expect(demoted[0].reason.contains("recency_cold"))
    }

    @Test("cold digest demotes to reference after hysteresis threshold")
    func coldDigestDemotesToReference() {
        let attachment = descriptor(byteSize: 50_000)
        let natural = [decision(for: attachment, disposition: .summarize, reason: "within_summary_budget")]
        let access = accessIndex(currentTurnIndex: 40, lastAccessTurnIndex: 5, attachmentID: attachment.id)
        let demoted = AttachmentRecencyProjectionPolicy.applyRecencyDemotion(
            decisions: natural,
            catalog: [attachment],
            accessIndex: access,
            recencyPolicy: recency
        )
        #expect(demoted[0].disposition == .searchOnly)
        #expect(demoted[0].reason.contains("recency_cold"))
    }

    @Test("hot attachments are not demoted below natural rung")
    func hotHoldSkipsDemotion() {
        let attachment = descriptor()
        let natural = [decision(for: attachment, disposition: .inline)]
        let access = accessIndex(currentTurnIndex: 10, lastAccessTurnIndex: 8, attachmentID: attachment.id)
        let demoted = AttachmentRecencyProjectionPolicy.applyRecencyDemotion(
            decisions: natural,
            catalog: [attachment],
            accessIndex: access,
            recencyPolicy: recency
        )
        #expect(demoted[0].disposition == .inline)
        #expect(!demoted[0].reason.contains("recency_cold"))
    }

    @Test("image inline cap demotes overflow to digest")
    func imageInlineCapDemotesOverflow() {
        let imageA = descriptor(kind: "image", addedAt: Date(timeIntervalSince1970: 3))
        let imageB = descriptor(kind: "image", addedAt: Date(timeIntervalSince1970: 2))
        let imageC = descriptor(kind: "image", addedAt: Date(timeIntervalSince1970: 1))
        let catalog = [imageA, imageB, imageC]
        let decisions = catalog.map { decision(for: $0, disposition: .inline) }
        let access = AttachmentAccessIndex(
            currentTurnIndex: 5,
            recordsByAttachmentID: [
                imageA.id: AttachmentAccessRecord(lastAccessTurnIndex: 4, accessCount: 1),
                imageB.id: AttachmentAccessRecord(lastAccessTurnIndex: 3, accessCount: 1),
                imageC.id: AttachmentAccessRecord(lastAccessTurnIndex: 2, accessCount: 1),
            ]
        )
        let capped = AttachmentRecencyProjectionPolicy.applyPerKindInlineCaps(
            decisions: decisions,
            catalog: catalog,
            accessIndex: access,
            recencyPolicy: recency
        )
        let byID = Dictionary(uniqueKeysWithValues: capped.map { ($0.attachmentID, $0) })
        #expect(byID[imageA.id]?.disposition == .inline)
        #expect(byID[imageB.id]?.disposition == .inline)
        #expect(byID[imageC.id]?.disposition == .summarize)
        #expect(byID[imageC.id]?.reason.contains("image_inline_cap") == true)
    }

    @Test("natural decision ladder respects size and vision")
    func naturalDecisionLadder() {
        let small = descriptor(byteSize: 500)
        let medium = descriptor(byteSize: 50_000)
        let large = descriptor(byteSize: 500_000)
        let image = descriptor(kind: "image", byteSize: 500)

        #expect(
            AttachmentRecencyProjectionPolicy.naturalDecision(
                for: small,
                modelSupportsVision: true,
                policy: policy
            ).disposition == .inline
        )
        #expect(
            AttachmentRecencyProjectionPolicy.naturalDecision(
                for: medium,
                modelSupportsVision: true,
                policy: policy
            ).disposition == .summarize
        )
        #expect(
            AttachmentRecencyProjectionPolicy.naturalDecision(
                for: large,
                modelSupportsVision: true,
                policy: policy
            ).disposition == .searchOnly
        )
        #expect(
            AttachmentRecencyProjectionPolicy.naturalDecision(
                for: image,
                modelSupportsVision: false,
                policy: policy
            ).disposition == .summarize
        )
        #expect(
            AttachmentRecencyProjectionPolicy.naturalDecision(
                for: image,
                modelSupportsVision: false,
                policy: policy
            ).reason == "vision_unsupported"
        )
    }

    @Test("vision image over text inlineByteLimit stays inline under image budget")
    func visionImageOverTextInlineLimitStaysInline() {
        let defaultPolicy = ContextEngineAttachmentProjectionPolicyInput()
        // ~1.3MB catalog size: exceeds text inlineByteLimit (256KB), under imageInlineByteLimit (5MB).
        let photo = descriptor(kind: "image", byteSize: 1_370_000)
        let decision = AttachmentRecencyProjectionPolicy.naturalDecision(
            for: photo,
            modelSupportsVision: true,
            policy: defaultPolicy
        )
        #expect(decision.disposition == .inline)
        #expect(decision.reason == "within_image_inline_budget")
        #expect(decision.reason != "within_summary_budget")
    }

    @Test("text attachment still demotes at inlineByteLimit")
    func textAttachmentStillUsesInlineByteLimit() {
        let defaultPolicy = ContextEngineAttachmentProjectionPolicyInput()
        let doc = descriptor(kind: "document", byteSize: 300_000)
        let decision = AttachmentRecencyProjectionPolicy.naturalDecision(
            for: doc,
            modelSupportsVision: true,
            policy: defaultPolicy
        )
        #expect(decision.disposition == .summarize)
        #expect(decision.reason == "within_summary_budget")
    }

    @Test("vision image over imageInlineByteLimit but under summarize prefers sanitize-to-inline")
    func visionImageSanitizeToInlineWhenOverImageBudget() {
        let custom = ContextEngineAttachmentProjectionPolicyInput(
            inlineByteLimit: 256_000,
            summarizeByteLimit: 2_000_000,
            imageInlineByteLimit: 100_000
        )
        let photo = descriptor(kind: "image", byteSize: 500_000)
        let decision = AttachmentRecencyProjectionPolicy.naturalDecision(
            for: photo,
            modelSupportsVision: true,
            policy: custom
        )
        #expect(decision.disposition == .inline)
        #expect(decision.reason == "sanitize_to_inline_budget")
    }

    @Test("vision image over summarizeByteLimit is searchOnly")
    func visionImageOverSummarizeIsSearchOnly() {
        let custom = ContextEngineAttachmentProjectionPolicyInput(
            summarizeByteLimit: 200_000,
            imageInlineByteLimit: 100_000
        )
        let photo = descriptor(kind: "image", byteSize: 500_000)
        let decision = AttachmentRecencyProjectionPolicy.naturalDecision(
            for: photo,
            modelSupportsVision: true,
            policy: custom
        )
        #expect(decision.disposition == .searchOnly)
        #expect(decision.reason == "over_budget")
    }
}
