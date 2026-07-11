import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment recency projection integration")
struct AttachmentRecencyProjectionIntegrationTests {
    private let policy = ContextEngineAttachmentProjectionPolicyInput(
        inlineByteLimit: 10_000,
        summarizeByteLimit: 100_000,
        recencyPolicy: ContextEngineAttachmentRecencyPolicyInput(
            hotAccessTurns: 3,
            demoteInlineAfterTurns: 8,
            demoteDigestAfterTurns: 20,
            hysteresisTurnMargin: 2,
            maxInlineImages: 2
        )
    )

    private func descriptor(
        id: UUID = UUID(),
        kind: String = "document",
        byteSize: Int64 = 500
    ) -> ConversationAttachmentDescriptor {
        ConversationAttachmentDescriptor(
            id: id,
            kind: kind,
            name: "file.bin",
            mimeType: kind == "image" ? "image/png" : "text/plain",
            byteSize: byteSize
        )
    }

    private func fillerMessages(count: Int) -> [Message] {
        (0..<count).map { index in
            Message(
                id: UUID(),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "turn-\(index)",
                timestamp: Date(),
                toolCalls: []
            )
        }
    }

    @Test("stale inline attachment stays effective until cache break event")
    func staleInlineHeldUntilBreakEvent() {
        let attachmentID = UUID()
        let catalog = [descriptor(id: attachmentID)]
        var messages = fillerMessages(count: 12)
        messages.append(
            Message(
                id: UUID(),
                role: .assistant,
                content: "",
                timestamp: Date(),
                toolCalls: [
                    ToolCall(
                        name: ConversationAttachmentToolProvider.readAttachmentToolName,
                        arguments: .object(["attachment_id": .string(attachmentID.uuidString)]),
                        id: "tc-1"
                    ),
                ]
            )
        )
        messages.append(contentsOf: fillerMessages(count: 12))

        let priorInline = ContextEngineAttachmentProjectionArtifact(
            projectionFingerprint: "prior",
            decisions: [
                ConversationAttachmentProjectionDecision(
                    attachmentID: attachmentID,
                    attachmentName: "file.bin",
                    attachmentKind: "document",
                    disposition: .inline,
                    reason: "within_inline_budget"
                ),
            ],
            targetDecisions: nil,
            materializedBlocks: [],
            accessWatermarkTurnIndex: 10
        )

        let held = ContextEngineAttachmentProjectionPolicyHelper.resolveAttachmentProjectionArtifact(
            catalog: catalog,
            modelSupportsVision: true,
            policy: policy,
            blobReader: nil,
            conversationID: UUID(),
            messages: messages,
            priorAttachmentProjection: priorInline,
            pendingCacheBreakEvents: []
        )
        #expect(held?.decisions[0].disposition == .inline)
        #expect(held?.decisions[0].reason.contains("hysteresis_hold") == true)
        #expect(held?.targetDecisions?[0].disposition == .summarize)

        let applied = ContextEngineAttachmentProjectionPolicyHelper.resolveAttachmentProjectionArtifact(
            catalog: catalog,
            modelSupportsVision: true,
            policy: policy,
            blobReader: nil,
            conversationID: UUID(),
            messages: messages,
            priorAttachmentProjection: held,
            pendingCacheBreakEvents: [.cacheExpiry]
        )
        #expect(applied?.decisions[0].disposition == .summarize)
        #expect(applied?.decisions[0].reason.contains("hysteresis_hold") == false)
    }

    @Test("third inline image demotes when cap exceeded")
    func thirdImageDemotedByCap() {
        let images = (0..<3).map { _ in descriptor(kind: "image", byteSize: 500) }
        let artifact = ContextEngineAttachmentProjectionPolicyHelper.resolveAttachmentProjectionArtifact(
            catalog: images,
            modelSupportsVision: true,
            policy: policy,
            blobReader: nil,
            conversationID: UUID(),
            messages: fillerMessages(count: 2)
        )
        let inlineCount = artifact?.decisions.filter { $0.disposition == .inline }.count ?? 0
        let cappedCount = artifact?.decisions.filter { $0.reason.contains("image_inline_cap") }.count ?? 0
        #expect(inlineCount == 2)
        #expect(cappedCount == 1)
    }
}
