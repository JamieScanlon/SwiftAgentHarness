import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment digest checkpoint cache")
struct AttachmentDigestCacheTests {
    private func makeBlobReader(harness: InMemoryHarnessSessionPersistence, conversationID: UUID) -> AttachmentBlobReading {
        AttachmentBlobReading.harness(harness, conversationID: conversationID)
    }

    private func storeTextBlob(
        harness: InMemoryHarnessSessionPersistence,
        text: String
    ) throws -> String {
        let ref = try harness.putBlob(
            data: Data(text.utf8),
            durability: .durable,
            originalName: "sample.txt",
            mimeType: "text/plain",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        )
        return ref.id
    }

    private func summarizeDecision(
        attachmentID: UUID,
        name: String = "notes.txt"
    ) -> ConversationAttachmentProjectionDecision {
        ConversationAttachmentProjectionDecision(
            attachmentID: attachmentID,
            attachmentName: name,
            attachmentKind: "document",
            disposition: .summarize,
            reason: "within_summary_budget"
        )
    }

    private func digestCheckpointEvent(
        conversationID: UUID,
        eventID: Int,
        wire: AttachmentDigestCheckpointWire
    ) -> CachedConversationEvent {
        CachedConversationEvent(
            conversationID: conversationID,
            eventID: eventID,
            kind: ConversationEventKind.attachmentDigestCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(wire)
        )
    }

    @Test("Cache hit reuses digest preview and emits no new checkpoint")
    func cacheHitReusesDigestPreview() throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let body = String(repeating: "abcdefghij", count: 200)
        let blobId = try storeTextBlob(harness: harness, text: body)
        let attachmentID = UUID()
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: blobId,
            kind: "document",
            name: "notes.txt",
            mimeType: "text/plain",
            byteSize: Int64(body.utf8.count),
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let configuration = AttachmentRepresentationMaterializerConfiguration(digestHeadMaxBytes: 64, digestTailMaxBytes: 32)
        let configFingerprint = AttachmentDigestCheckpointPolicy.configFingerprint(
            configuration: configuration,
            modelSupportsVision: true
        )
        let digestBody = AttachmentDigestProducer.produce(
            descriptor: descriptor,
            bytes: Data(body.utf8),
            modelSupportsVision: true,
            configuration: configuration
        )
        let cachedWire = AttachmentDigestCheckpointWire(
            schemaVersion: AttachmentDigestCheckpointWire.currentSchemaVersion,
            basedOnEventID: 1,
            attachmentID: attachmentID,
            contentHash: blobId,
            configFingerprint: configFingerprint,
            digestBody: digestBody,
            createdAt: Date()
        )
        let events = [
            digestCheckpointEvent(conversationID: conversationID, eventID: 10, wire: cachedWire),
        ]
        let resolution = AttachmentDigestCacheResolver.resolve(
            catalog: [descriptor],
            decisions: [summarizeDecision(attachmentID: attachmentID)],
            configuration: configuration,
            modelSupportsVision: true,
            blobReader: makeBlobReader(harness: harness, conversationID: conversationID),
            conversationID: conversationID,
            events: events,
            frontierEventID: 10
        )
        #expect(resolution.newDigestCheckpoints.isEmpty)
        #expect(resolution.digestPreviewByAttachmentID[attachmentID] == digestBody)

        let blocks = AttachmentRepresentationMaterializer.materialize(
            decisions: [summarizeDecision(attachmentID: attachmentID)],
            catalog: [descriptor],
            modelSupportsVision: true,
            blobReader: makeBlobReader(harness: harness, conversationID: conversationID),
            conversationID: conversationID,
            configuration: configuration,
            digestPreviewByAttachmentID: resolution.digestPreviewByAttachmentID
        )
        let block = try #require(blocks.first)
        #expect(block.body.contains(digestBody))
        #expect(block.body.contains("original_byte_count: \(body.utf8.count)"))
    }

    @Test("Policy fingerprint change produces a cache miss")
    func policyFingerprintChangeMissesCache() throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let body = "short text for digest cache policy miss"
        let blobId = try storeTextBlob(harness: harness, text: body)
        let attachmentID = UUID()
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: blobId,
            kind: "document",
            name: "notes.txt",
            mimeType: "text/plain",
            byteSize: Int64(body.utf8.count)
        )
        let oldConfiguration = AttachmentRepresentationMaterializerConfiguration(digestHeadMaxBytes: 64, digestTailMaxBytes: 32)
        let oldFingerprint = AttachmentDigestCheckpointPolicy.configFingerprint(
            configuration: oldConfiguration,
            modelSupportsVision: true
        )
        let cachedWire = AttachmentDigestCheckpointWire(
            schemaVersion: AttachmentDigestCheckpointWire.currentSchemaVersion,
            basedOnEventID: 1,
            attachmentID: attachmentID,
            contentHash: blobId,
            configFingerprint: oldFingerprint,
            digestBody: "stale preview",
            createdAt: Date()
        )
        let newConfiguration = AttachmentRepresentationMaterializerConfiguration(digestHeadMaxBytes: 128, digestTailMaxBytes: 32)
        let resolution = AttachmentDigestCacheResolver.resolve(
            catalog: [descriptor],
            decisions: [summarizeDecision(attachmentID: attachmentID)],
            configuration: newConfiguration,
            modelSupportsVision: true,
            blobReader: makeBlobReader(harness: harness, conversationID: conversationID),
            conversationID: conversationID,
            events: [digestCheckpointEvent(conversationID: conversationID, eventID: 1, wire: cachedWire)],
            frontierEventID: 1
        )
        #expect(resolution.newDigestCheckpoints.count == 1)
        #expect(resolution.newDigestCheckpoints.first?.configFingerprint != oldFingerprint)
        #expect(resolution.digestPreviewByAttachmentID[attachmentID] != "stale preview")
    }

    @Test("Content hash change produces a cache miss")
    func contentHashChangeMissesCache() throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let originalBody = "original attachment bytes"
        let updatedBody = "updated attachment bytes"
        let originalBlobId = try storeTextBlob(harness: harness, text: originalBody)
        let updatedBlobId = try storeTextBlob(harness: harness, text: updatedBody)
        let attachmentID = UUID()
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: updatedBlobId,
            kind: "document",
            name: "notes.txt",
            mimeType: "text/plain",
            byteSize: Int64(updatedBody.utf8.count)
        )
        let configuration = AttachmentRepresentationMaterializerConfiguration()
        let fingerprint = AttachmentDigestCheckpointPolicy.configFingerprint(
            configuration: configuration,
            modelSupportsVision: true
        )
        let staleWire = AttachmentDigestCheckpointWire(
            schemaVersion: AttachmentDigestCheckpointWire.currentSchemaVersion,
            basedOnEventID: 1,
            attachmentID: attachmentID,
            contentHash: originalBlobId,
            configFingerprint: fingerprint,
            digestBody: "old hash preview",
            createdAt: Date()
        )
        let resolution = AttachmentDigestCacheResolver.resolve(
            catalog: [descriptor],
            decisions: [summarizeDecision(attachmentID: attachmentID)],
            configuration: configuration,
            modelSupportsVision: true,
            blobReader: makeBlobReader(harness: harness, conversationID: conversationID),
            conversationID: conversationID,
            events: [digestCheckpointEvent(conversationID: conversationID, eventID: 1, wire: staleWire)],
            frontierEventID: 1
        )
        #expect(resolution.newDigestCheckpoints.count == 1)
        #expect(resolution.newDigestCheckpoints.first?.contentHash == updatedBlobId)
        #expect(resolution.digestPreviewByAttachmentID[attachmentID]?.contains("original_byte_count") == true)
    }

    @Test("latestValidAttachmentDigest rejects mismatched fingerprint and honors invalidation floor")
    func latestValidAttachmentDigestValidity() throws {
        let conversationID = UUID()
        let attachmentID = UUID()
        let contentHash = "abc123"
        let fingerprint = AttachmentDigestCheckpointPolicy.configFingerprint(
            configuration: .default,
            modelSupportsVision: true
        )
        let validWire = AttachmentDigestCheckpointWire(
            schemaVersion: AttachmentDigestCheckpointWire.currentSchemaVersion,
            basedOnEventID: 1,
            attachmentID: attachmentID,
            contentHash: contentHash,
            configFingerprint: fingerprint,
            digestBody: "digest body",
            createdAt: Date()
        )
        let wrongFingerprintWire = AttachmentDigestCheckpointWire(
            schemaVersion: AttachmentDigestCheckpointWire.currentSchemaVersion,
            basedOnEventID: 1,
            attachmentID: attachmentID,
            contentHash: contentHash,
            configFingerprint: "wrong",
            digestBody: "digest body",
            createdAt: Date()
        )
        let events = [
            digestCheckpointEvent(conversationID: conversationID, eventID: 5, wire: wrongFingerprintWire),
            digestCheckpointEvent(conversationID: conversationID, eventID: 6, wire: validWire),
        ]
        let selected = SuiteCheckpointSupport.latestValidAttachmentDigest(
            events: events,
            frontierEventID: 6,
            attachmentID: attachmentID,
            contentHash: contentHash,
            configFingerprint: fingerprint
        )
        #expect(selected?.eventID == 6)

        let invalidatedEvents = events + [
            CachedConversationEvent(
                conversationID: conversationID,
                eventID: 7,
                kind: ConversationEventKind.checkpointInvalidated.rawValue,
                payloadJSON: ConversationEventCodec.encode(
                    CheckpointInvalidatedEventPayload(kinds: [HarnessCheckpointInvalidationKind.attachmentDigest])
                )
            ),
        ]
        #expect(
            SuiteCheckpointSupport.latestValidAttachmentDigest(
                events: invalidatedEvents,
                frontierEventID: 7,
                attachmentID: attachmentID,
                contentHash: contentHash,
                configFingerprint: fingerprint
            ) == nil
        )
    }

    @Test("BranchJournalCheckpointFilter always copies valid attachment digest checkpoints")
    func branchFilterCopiesAttachmentDigest() {
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 1,
            kind: ConversationEventKind.attachmentDigestCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                AttachmentDigestCheckpointWire(
                    schemaVersion: AttachmentDigestCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    attachmentID: UUID(),
                    contentHash: "hash",
                    configFingerprint: "fp",
                    digestBody: "body",
                    createdAt: Date()
                )
            )
        )
        #expect(
            BranchJournalCheckpointFilter.shouldCopyCheckpointEvent(
                event,
                allowedMessageIDs: []
            )
        )
        #expect(
            DerivedArtifactContractMatrix.branchInheritanceRule(
                forPersistedKind: ConversationEventKind.attachmentDigestCheckpoint.rawValue
            ) == .copyVerbatim
        )
    }

    @Test("Descriptor without blob id skips digest checkpoint emission")
    func noBlobSkipsDigestCheckpoint() {
        let attachmentID = UUID()
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            kind: "document",
            name: "generated.pdf",
            mimeType: "application/pdf",
            byteSize: 4_000_000
        )
        let resolution = AttachmentDigestCacheResolver.resolve(
            catalog: [descriptor],
            decisions: [summarizeDecision(attachmentID: attachmentID, name: "generated.pdf")],
            configuration: .default,
            modelSupportsVision: true,
            blobReader: nil,
            conversationID: UUID(),
            events: [],
            frontierEventID: nil
        )
        #expect(resolution.newDigestCheckpoints.isEmpty)
        #expect(resolution.digestPreviewByAttachmentID.isEmpty)
    }
}
