import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Session title resolution (Gap 3)")
struct SessionTitleResolutionTests {
    @Test func lineageHashSuffixMatches() {
        #expect(SessionTitleResolution.storedTitleMatchesLineage(baseTitle: "Proj", storedTitle: "Proj"))
        #expect(SessionTitleResolution.storedTitleMatchesLineage(baseTitle: "Proj", storedTitle: "Proj #1"))
        #expect(SessionTitleResolution.storedTitleMatchesLineage(baseTitle: "Proj", storedTitle: "Proj #42"))
        #expect(!SessionTitleResolution.storedTitleMatchesLineage(baseTitle: "Proj", storedTitle: "Proj (1)"))
        #expect(!SessionTitleResolution.storedTitleMatchesLineage(baseTitle: "Proj", storedTitle: "Project #1"))
        #expect(!SessionTitleResolution.storedTitleMatchesLineage(baseTitle: "Proj", storedTitle: "Proj#1"))
    }

    @Test func resolveThrowsWhenAmbiguous() throws {
        let t = Date(timeIntervalSince1970: 10_000)
        let a = SessionCatalogRecord(
            id: UUID(),
            topic: "Dup",
            description: nil,
            messageCount: 0,
            updatedAt: t,
            createdAt: t,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        var b = SessionCatalogRecord(
            id: UUID(),
            topic: "Dup",
            description: nil,
            messageCount: 0,
            updatedAt: t,
            createdAt: t,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        b.id = UUID()
        #expect(throws: SessionPersistenceError.self) {
            try SessionTitleResolution.resolveSessionID(records: [a, b], normalizedTitle: "Dup", lifecycleState: nil)
        }
    }

    @Test func lineagePicksNewestCreatedAtThenMessageCount() {
        let base = "Tree"
        let old = Date(timeIntervalSince1970: 50)
        let new = Date(timeIntervalSince1970: 100)
        var r0 = SessionCatalogRecord(
            id: UUID(),
            topic: "\(base) #1",
            description: nil,
            messageCount: 99,
            updatedAt: old,
            createdAt: old,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        var r1 = SessionCatalogRecord(
            id: UUID(),
            topic: base,
            description: nil,
            messageCount: 1,
            updatedAt: new,
            createdAt: new,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        r1.messageCount = 1
        let pick1 = SessionTitleResolution.newestLineageTitle(records: [r0, r1], baseTitle: base)
        #expect(pick1 == base)

        r0.createdAt = new
        r0.messageCount = 5
        r1.createdAt = new
        r1.messageCount = 10
        let pick2 = SessionTitleResolution.newestLineageTitle(records: [r0, r1], baseTitle: base)
        #expect(pick2 == base)

        r0.messageCount = 10
        r1.messageCount = 10
        let idHi = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let idLo = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        r0.id = idLo
        r1.id = idHi
        // Same `created_at` and `message_count`: higher `id` lexicographic wins (deterministic, never ambiguous).
        let pick3 = SessionTitleResolution.newestLineageTitle(records: [r0, r1], baseTitle: base)
        #expect(pick3 == base)
        let winner = SessionTitleResolution.newestLineageRecord(records: [r0, r1], baseTitle: base, lifecycleState: nil)
        #expect(winner?.id == r1.id)
    }

    @Test func lineageReturnsNilWhenNoMatch() {
        let t = Date()
        let r = SessionCatalogRecord(
            id: UUID(),
            topic: "Other",
            description: nil,
            messageCount: 0,
            updatedAt: t,
            createdAt: t,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        #expect(SessionTitleResolution.newestLineageTitle(records: [r], baseTitle: "Zed") == nil)
    }

    @Test func catalogTitleDisambiguationTrimsWhenUnique() {
        let t = Date()
        var row = SessionCatalogRecord(
            id: UUID(),
            topic: "  MergeMe  ",
            description: nil,
            messageCount: 0,
            updatedAt: t,
            createdAt: t,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        SessionCatalogTitleDisambiguation.apply(to: &row, occupiedNonNullTitles: ["Other"])
        #expect(row.title == "MergeMe")
        #expect(row.topic == "MergeMe")
    }

    @Test func catalogTitleDisambiguationRandomSuffixWhenCollision() {
        let t = Date()
        var row = SessionCatalogRecord(
            id: UUID(),
            topic: "Shared",
            description: nil,
            messageCount: 0,
            updatedAt: t,
            createdAt: t,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        SessionCatalogTitleDisambiguation.apply(to: &row, occupiedNonNullTitles: ["Shared"])
        #expect(row.title != "Shared")
        #expect(row.title?.hasPrefix("Shared ") == true)
        #expect(row.topic == row.title)
    }

    @Test func nfcNormalizationCollapsesComposedAndDecomposedTitles() {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        #expect(SessionTitleResolution.normalizedTitleForLookup(nfc) == SessionTitleResolution.normalizedTitleForLookup(nfd))
    }

    @Test func disambiguationTreatsNfcAndNfdAsSameOccupiedTitle() {
        let t = Date()
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        var row = SessionCatalogRecord(
            id: UUID(),
            topic: nfd,
            description: nil,
            messageCount: 0,
            updatedAt: t,
            createdAt: t,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        SessionCatalogTitleDisambiguation.apply(to: &row, occupiedNonNullTitles: [nfc])
        #expect(row.title != nfc)
        #expect(row.title?.hasPrefix("\(nfc) ") == true)
    }
}
