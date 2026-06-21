import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Session transcript integrity")
struct SessionTranscriptIntegrityTests {
    private func tempRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("transcript-integrity-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func bootstrapWithMessage(
        local: LocalHarnessSessionPersistence,
        cid: UUID,
        content: String = "hello"
    ) throws {
        try HarnessConversationTestFixtures.bootstrapEmptySession(
            local: local,
            id: cid,
            model: HarnessConversationTestFixtures.makeTestModel(),
            topic: "T"
        )
        let user = Message(id: UUID(), role: .user, content: content, timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: user)
    }

    private func appendSecondMessage(local: LocalHarnessSessionPersistence, cid: UUID) throws {
        let user = Message(id: UUID(), role: .user, content: "second", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: user)
    }

    private func appendGarbageTail(to jsonlURL: URL) throws {
        var text = try String(contentsOf: jsonlURL, encoding: .utf8)
        text += "\nNOT VALID JSON\n"
        try text.write(to: jsonlURL, atomically: true, encoding: .utf8)
    }

    private func corruptMiddleLine(jsonlURL: URL) throws {
        var lines = try String(contentsOf: jsonlURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count >= 3 else {
            Issue.record("expected header plus at least one body line")
            return
        }
        lines.insert("CORRUPT MIDDLE", at: 1)
        try lines.joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)
    }

    private func replaceMiddleBodyLineWithGarbage(jsonlURL: URL) throws {
        var lines = try String(contentsOf: jsonlURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count >= 3 else {
            Issue.record("expected header plus two body lines")
            return
        }
        lines[1] = "{\"broken\":true"
        try lines.joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)
    }

    @Test func tailConfinedWithCatalogAheadIsLosslesslyRepairable() throws {
        let root = tempRoot("tail-repairable")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try bootstrapWithMessage(local: local, cid: cid)
        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try appendGarbageTail(to: jsonlURL)

        let report = try local.verifyTranscript(conversationID: cid)
        #expect(report.damageClass == .tailConfined)
        #expect(report.isLosslesslyRepairable)
        #expect(report.catalogLatestSequence >= report.lastCleanJSONLSequence)
    }

    @Test func structuralMidFileIsNotLosslesslyRepairable() throws {
        let root = tempRoot("structural")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try bootstrapWithMessage(local: local, cid: cid)
        try appendSecondMessage(local: local, cid: cid)
        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try corruptMiddleLine(jsonlURL: jsonlURL)

        let report = try local.verifyTranscript(conversationID: cid)
        #expect(report.damageClass == .structural)
        #expect(!report.isLosslesslyRepairable)
    }

    @Test func transcriptLedTailIsNotLosslesslyRepairable() throws {
        let root = tempRoot("transcript-led")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try bootstrapWithMessage(local: local, cid: cid)
        try appendSecondMessage(local: local, cid: cid)
        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        var lines = try String(contentsOf: jsonlURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        lines.append("TAIL GARBAGE")
        try lines.joined(separator: "\n").write(to: jsonlURL, atomically: true, encoding: .utf8)

        let scan = SessionJSONLTranscriptReader.verifyLineScan(
            from: try String(contentsOf: jsonlURL, encoding: .utf8),
            catalogLatestSequence: 1
        )
        #expect(scan.damageClass == .tailConfined)
        #expect(scan.lastCleanJSONLSequence == 2)
        #expect(!(scan.damageClass == .tailConfined && 1 >= scan.lastCleanJSONLSequence))
    }

    @Test func maskedCorruptionQuarantinesOnMaintenanceScan() throws {
        let root = tempRoot("masked")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try bootstrapWithMessage(local: local, cid: cid, content: "masked")
        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try "not a transcript".write(to: jsonlURL, atomically: true, encoding: .utf8)

        let readBefore = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(readBefore.contains { $0.type == .message })

        let report = try SessionTranscriptIntegrityScanner.runTranscriptIntegrityMaintenance(
            root: root,
            verifyAndRepair: true
        )
        #expect(report.quarantinedCount == 1)

        let integrity = try local.catalogConversation(id: cid)?.transcriptIntegrity
        #expect(integrity?.state == .quarantined)

        let readAfter = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(readAfter.contains { $0.type == .message })
    }

    @Test func autoRepairSideCopiesAndRewritesJSONL() throws {
        let root = tempRoot("auto-repair")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try bootstrapWithMessage(local: local, cid: cid, content: "restore")
        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try appendGarbageTail(to: jsonlURL)

        let verify = try local.verifyTranscript(conversationID: cid)
        #expect(verify.isLosslesslyRepairable)

        let report = try SessionTranscriptIntegrityScanner.runTranscriptIntegrityMaintenance(
            root: root,
            verifyAndRepair: true
        )
        #expect(report.autoRepairedCount == 1)

        let dir = jsonlURL.deletingLastPathComponent()
        let sideCopies = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".jsonl.corrupt-") }
        #expect(!sideCopies.isEmpty)

        let repaired = try SessionJSONLTranscriptReader.loadEntries(fileURL: jsonlURL)
        #expect(repaired.contains { $0.type == .message })
        #expect(try local.catalogConversation(id: cid)?.transcriptIntegrity == nil)
    }

    @Test func appendOnQuarantinedThrows() throws {
        let root = tempRoot("append-block")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try bootstrapWithMessage(local: local, cid: cid)
        try local.quarantineTranscript(conversationID: cid, reason: "test")

        let message = Message(id: UUID(), role: .user, content: "blocked", timestamp: Date(), toolCalls: [])
        #expect(throws: SessionPersistenceError.self) {
            try HarnessConversationTestFixtures.appendThinTranscriptMessage(
                local: local,
                conversationID: cid,
                message: message
            )
        }
    }

    @Test func repairQuarantinedTranscriptClearsFlagAndAllowsAppend() throws {
        let root = tempRoot("repair-quarantine")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try bootstrapWithMessage(local: local, cid: cid, content: "fix me")
        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try "truncated".write(to: jsonlURL, atomically: true, encoding: .utf8)
        try local.quarantineTranscript(conversationID: cid, reason: "structural")

        try local.repairQuarantinedTranscript(conversationID: cid)
        #expect(try local.catalogConversation(id: cid)?.transcriptIntegrity == nil)

        let message = Message(id: UUID(), role: .user, content: "after repair", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(
            local: local,
            conversationID: cid,
            message: message
        )
        let entries = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(entries.count >= 2)
    }

    @Test func maintenanceScanContinuesAfterPerConversationDamage() throws {
        let root = tempRoot("scan-continue")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let healthy = UUID()
        let damaged = UUID()
        try bootstrapWithMessage(local: local, cid: healthy, content: "ok")
        try bootstrapWithMessage(local: local, cid: damaged, content: "bad")
        try "garbage".write(
            to: local.transcriptFileURL(conversationID: damaged),
            atomically: true,
            encoding: .utf8
        )

        let report = try SessionTranscriptIntegrityScanner.runTranscriptIntegrityMaintenance(
            root: root,
            verifyAndRepair: true
        )
        #expect(report.conversationCount == 2)
        #expect(report.quarantinedCount == 1)
        #expect(try local.catalogConversation(id: healthy)?.transcriptIntegrity == nil)
        #expect(try local.catalogConversation(id: damaged)?.transcriptIntegrity?.state == .quarantined)
    }

    @Test func integrityReportSeverityElevatedForLocalizedDamage() throws {
        let root = tempRoot("severity-elevated")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let healthy = UUID()
        let damaged = UUID()
        try bootstrapWithMessage(local: local, cid: healthy)
        try bootstrapWithMessage(local: local, cid: damaged)
        try "garbage".write(
            to: local.transcriptFileURL(conversationID: damaged),
            atomically: true,
            encoding: .utf8
        )

        let report = try SessionTranscriptIntegrityScanner.integrityReport(
            root: root,
            verifyAndRepair: false
        )
        #expect(report.severity == .elevated)
    }

    @Test func integrityReportStoreAbsentSuspectedWhenMostlyEmptyDamaged() throws {
        let root = tempRoot("severity-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        for _ in 0..<3 {
            let cid = UUID()
            try local.bootstrapEmptyConversation(
                SessionCatalogRecord(
                    id: cid,
                    topic: "empty",
                    description: nil,
                    messageCount: 0,
                    updatedAt: Date(),
                    createdAt: Date(),
                    modelName: "m",
                    interactionModeRaw: InteractionMode.chat.rawValue,
                    controlPlaneRevision: 0,
                    agentId: SessionPersistenceLayout.defaultAgentId
                )
            )
            try "garbage".write(to: local.transcriptFileURL(conversationID: cid), atomically: true, encoding: .utf8)
        }

        let report = try SessionTranscriptIntegrityScanner.integrityReport(
            root: root,
            verifyAndRepair: true
        )
        #expect(report.quarantinedCount == 3)
        #expect(report.severity == .storeAbsentSuspected)
    }

    @Test func sameCountContentDamageQuarantinesWithoutDriftReconcile() throws {
        let root = tempRoot("same-count")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try bootstrapWithMessage(local: local, cid: cid)
        try appendSecondMessage(local: local, cid: cid)
        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        let beforeCount = try SessionJSONLTranscriptReader.entryLineCount(fileURL: jsonlURL)
        try replaceMiddleBodyLineWithGarbage(jsonlURL: jsonlURL)
        let afterCount = try SessionJSONLTranscriptReader.entryLineCount(fileURL: jsonlURL)
        #expect(beforeCount == afterCount)

        _ = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(try local.catalogConversation(id: cid)?.transcriptIntegrity == nil)

        let report = try SessionTranscriptIntegrityScanner.runTranscriptIntegrityMaintenance(
            root: root,
            verifyAndRepair: true
        )
        #expect(report.quarantinedCount == 1)
        #expect(try local.catalogConversation(id: cid)?.transcriptIntegrity?.state == .quarantined)
    }

    @Test func refreshTranscriptIntegrityFromMaintenanceUpdatesRegistry() throws {
        let (stack, local, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "transcript-refresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = UUID()
        let model = HarnessConversationTestFixtures.makeTestModel()
        try bootstrapWithMessage(local: local, cid: cid, content: "registry")
        try stack.conversationManager.resetConversationsFromCatalog(availableModels: [model])
        #expect(stack.conversationManager.modelConversation(id: cid)?.transcriptIntegrity == nil)

        try "garbage".write(to: local.transcriptFileURL(conversationID: cid), atomically: true, encoding: .utf8)
        let report = try SessionTranscriptIntegrityScanner.runTranscriptIntegrityMaintenance(
            root: root,
            verifyAndRepair: true
        )
        #expect(report.quarantinedCount == 1)
        #expect(stack.conversationManager.modelConversation(id: cid)?.transcriptIntegrity == nil)

        try stack.conversationManager.refreshTranscriptIntegrityFromMaintenance(report: report)
        let updated = try #require(stack.conversationManager.modelConversation(id: cid))
        #expect(updated.transcriptIntegrity?.state == .quarantined)
    }

    @Test func inMemoryQuarantineBlocksAppendAndRepairClears() throws {
        let harness = InMemoryHarnessSessionPersistence()
        let cid = UUID()
        try harness.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "mem",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
                controlPlaneRevision: 0,
                agentId: SessionPersistenceLayout.defaultAgentId,
                transcriptIntegrity: SessionTranscriptIntegrity(state: .quarantined, reason: "test")
            )
        )
        let message = Message(id: UUID(), role: .user, content: "x", timestamp: Date(), toolCalls: [])
        let entry = try SessionTranscriptMapping.entry(from: message, sequence: 1, parentEntryId: nil)
        #expect(throws: SessionPersistenceError.self) {
            try harness.appendTranscriptEntry(conversationID: cid, entry: entry)
        }
        try harness.repairQuarantinedTranscript(conversationID: cid)
        try harness.appendTranscriptEntry(conversationID: cid, entry: entry)
        let read = try harness.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(read.count == 1)
    }
}
