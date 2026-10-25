import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

/// A content-addressed stand-in for the session blob store.
final class ReplayBlobStore: Sendable {
    private let blobs = Mutex<[String: Data]>([:])

    func put(_ data: Data) -> String {
        let id = String(format: "%064x", abs(data.hashValue)).suffix(64).description
        blobs.withLock { $0[id] = data }
        return id
    }

    func get(_ id: String) throws -> Data {
        guard let data = blobs.withLock({ $0[id] }) else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    var count: Int { blobs.withLock { $0.count } }

    private let expiryLog = Mutex<[String: Date?]>([:])

    func setExpiry(_ id: String, _ expiresAt: Date?) {
        expiryLog.withLock { $0[id] = expiresAt }
    }

    var expiries: [String: Date?] { expiryLog.withLock { $0 } }
}

@Suite("Computer use replays")
struct ComputerUseReplayTests {
    private func session(thumbnailCapacity: Int = 120) async throws -> (FakeDisplayTarget, ComputerUseSession) {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() })
        await target.setScreenshot(try ComputerUseFixtures.pngScreenshot())
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "agent",
            grants: ComputerUseSessionFixtures.grants,
            budgets: ComputerUseBudgets(maxSteps: 50, maxDuration: .seconds(600)),
            operatorInitiated: true,
            userPresent: true
        ))
        var configuration = ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["Save the file."]))
        configuration.replayThumbnailCapacity = thumbnailCapacity
        return (target, ComputerUseSession(target: target, lease: lease, configuration: configuration))
    }

    @Test("Each observation with pixels leaves a small thumbnail; accessibility-only observations don't")
    func thumbnails() async throws {
        let (_, session) = try await session()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([.observe(ObserveRequest(modes: [.accessibility], scope: .display(nil)))])
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1")), ComputerUseSessionFixtures.observe])

        let frames = await session.replayFrames
        #expect(frames.map(\.observationID) == ["o_1", "o_3"])
        let first = try #require(frames.first)
        #expect(max(first.image.width, first.image.height) <= ComputerUseSessionConfiguration.defaultReplayThumbnailEdgePx)
        #expect(first.app == ComputerUseFixtures.textEdit.bundleID)
    }

    @Test("Past capacity, the first frame and the newest ones are kept")
    func capacity() async throws {
        let (_, session) = try await session(thumbnailCapacity: 3)
        for _ in 0..<5 { _ = await session.perform([ComputerUseSessionFixtures.observe]) }
        #expect(await session.replayFrames.map(\.observationID) == ["o_1", "o_4", "o_5"])
    }

    @Test("A replay stores its thumbnails as blobs and lists the action log against them")
    func build() async throws {
        let (_, session) = try await session()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1")), ComputerUseSessionFixtures.observe])
        await session.end()

        let store = ReplayBlobStore()
        let parent = UUID()
        let replay = try await ComputerUseReplay(
            session: session,
            parentConversationID: parent,
            lifecycleID: "call-1",
            targetLabel: "Fake VM",
            storeThumbnail: { store.put($0) }
        )
        #expect(replay.lifecycleID == "call-1")
        #expect(replay.terminalReason == .ended)
        #expect(replay.records.map(\.kind) == [.observe, .click, .observe])
        #expect(replay.thumbnails.map(\.observationID) == ["o_1", "o_2"])
        let thumbnail = try #require(replay.thumbnails.first)
        #expect(try store.get(thumbnail.blobID).count > 0)
        #expect(replay.summary.actionCount == 3)
        #expect(replay.summary.thumbnailCount == 2)
        #expect(try JSONDecoder.computerUseReplay.decode(ComputerUseReplay.self, from: JSONEncoder.computerUseReplay.encode(replay)) == replay)
    }

    @Test("The index keeps each conversation's replays newest first, capped, and looks them up by run")
    func index() async throws {
        let index = ComputerUseReplayIndex(capacityPerConversation: 2)
        let parent = UUID()
        let store = ReplayBlobStore()
        for (offset, lifecycleID) in ["call-1", "call-2", "call-3"].enumerated() {
            let replay = ComputerUseReplay.fixture(parent: parent, lifecycleID: lifecycleID, endedAt: Date(timeIntervalSince1970: Double(offset)))
            await index.record(.fixture(replay, store: store))
        }
        await index.record(.fixture(ComputerUseReplay.fixture(parent: UUID(), lifecycleID: "call-other", endedAt: Date()), store: store))
        #expect(await index.summaries(parent: parent).map(\.lifecycleID) == ["call-3", "call-2"])
        #expect(await index.entry(parent: parent, lifecycleID: "call-1") == nil)
        #expect(await index.entry(parent: parent, lifecycleID: "call-2")?.replay.lifecycleID == "call-2")
    }

    @Test("Expired replays drop out of the index")
    func expiredHidden() async throws {
        let clock = ComputerUseTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let index = ComputerUseReplayIndex(now: { clock.now() })
        let parent = UUID()
        var entry = ComputerUseReplayIndexEntry.fixture(.fixture(parent: parent, lifecycleID: "call-1", endedAt: clock.now()), store: ReplayBlobStore())
        entry.expiresAt = clock.now().addingTimeInterval(60)
        await index.record(entry)
        #expect(await index.summaries(parent: parent).first?.expiresAt == entry.expiresAt)
        clock.advance(seconds: 61)
        #expect(await index.summaries(parent: parent).isEmpty)
        #expect(await index.entry(parent: parent, lifecycleID: "call-1") == nil)
    }

    @Test("The control service serves a replay and only the thumbnails it lists")
    func control() async throws {
        let installation = ComputerUseInstallation()
        let control = ComputerUseControlService(installation: installation)
        let parent = UUID()
        let store = ReplayBlobStore()
        let png = try ComputerUseFixtures.pngScreenshot(width: 32, height: 20)
        let thumbnailID = store.put(png)
        let foreignID = store.put(Data("someone else's blob".utf8))
        var replay = ComputerUseReplay.fixture(parent: parent, lifecycleID: "call-1", endedAt: Date())
        replay.thumbnails = [ComputerUseReplayThumbnail(
            observationID: "o_1", at: Date(), app: nil, width: 32, height: 20, mediaType: "image/png", blobID: thumbnailID
        )]
        await installation.replays.record(.fixture(replay, store: store))

        #expect(await control.replays(conversationID: parent).map(\.lifecycleID) == ["call-1"])
        #expect(await control.replays(conversationID: UUID()).isEmpty)
        #expect(await control.replay(conversationID: parent, lifecycleID: "call-1") == replay)
        #expect(await control.replay(conversationID: UUID(), lifecycleID: "call-1") == nil)
        let thumbnail = try #require(await control.replayThumbnail(conversationID: parent, lifecycleID: "call-1", observationID: "o_1"))
        #expect(thumbnail.data == png)
        #expect(thumbnail.mediaType == "image/png")
        #expect(await control.replayThumbnail(conversationID: parent, lifecycleID: "call-1", observationID: foreignID) == nil)
        #expect(await control.replayThumbnail(conversationID: parent, lifecycleID: "call-1", observationID: "o_2") == nil)
    }

    @Test("Marking a released run for audit moves every blob it holds to the audit retention, and unmarking moves them back")
    func auditReleased() async throws {
        let installation = ComputerUseInstallation()
        installation.install(ComputerUseConfiguration(
            registry: DisplayTargetRegistry(targets: []),
            defaults: ComputerUseSpecialistDefaults(
                target: "t",
                budgets: ComputerUseBudgets(maxSteps: 1, maxDuration: .seconds(60)),
                maxBudgets: ComputerUseBudgets(maxSteps: 1, maxDuration: .seconds(60))
            ),
            approveGrants: { _ in nil },
            retention: ComputerUseRetention(afterRelease: .seconds(3_600), audit: .seconds(30 * 86_400))
        ))
        let control = ComputerUseControlService(installation: installation)
        let parent = UUID()
        let store = ReplayBlobStore()
        let releasedAt = Date()
        var entry = ComputerUseReplayIndexEntry.fixture(.fixture(parent: parent, lifecycleID: "call-1", endedAt: releasedAt), store: store)
        entry.blobIDs = ["shot-1", "thumb-1", "doc"]
        entry.releasedAt = releasedAt
        entry.expiresAt = releasedAt.addingTimeInterval(3_600)
        await installation.replays.record(entry)

        let marked = try #require(await control.setAuditMark(true, conversationID: parent, lifecycleID: "call-1"))
        #expect(marked.released && marked.auditMarked)
        #expect(marked.expiresAt == releasedAt.addingTimeInterval(30 * 86_400))
        #expect(store.expiries == ["shot-1": marked.expiresAt, "thumb-1": marked.expiresAt, "doc": marked.expiresAt])
        #expect(await control.replays(conversationID: parent).first?.auditMarked == true)

        let unmarked = try #require(await control.setAuditMark(false, conversationID: parent, lifecycleID: "call-1"))
        #expect(unmarked.expiresAt == releasedAt.addingTimeInterval(3_600))
        #expect(store.expiries["doc"] == releasedAt.addingTimeInterval(3_600))
        #expect(await control.setAuditMark(true, conversationID: parent, lifecycleID: "call-9") == nil)
    }

    @Test("A live run takes the audit mark at release")
    func auditLive() async throws {
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        let control = ComputerUseControlService(installation: installation)
        let parent = UUID()
        try await ComputerUseFixtures.registerLiveSession(in: installation, parent: parent, lifecycleID: "call-1")
        let status = try #require(await control.setAuditMark(true, conversationID: parent, lifecycleID: "call-1"))
        #expect(!status.released)
        #expect(await installation.blobs.takeAuditMark(parent: parent, lifecycleID: "call-1"))
        #expect(await !installation.blobs.takeAuditMark(parent: parent, lifecycleID: "call-1"))
    }

    @Test("Retention: the TTL runs from release, and audit retention replaces it")
    func retentionRule() {
        let released = Date(timeIntervalSince1970: 1_800_000_000)
        let retention = ComputerUseRetention(afterRelease: .seconds(60), audit: nil)
        #expect(retention.expiry(releasedAt: released, auditMarked: false) == released.addingTimeInterval(60))
        #expect(retention.expiry(releasedAt: released, auditMarked: true) == nil)
        #expect(ComputerUseRetention(afterRelease: .seconds(60), audit: .seconds(600)).expiry(releasedAt: released, auditMarked: true)
            == released.addingTimeInterval(600))
    }
}

extension ComputerUseReplayIndexEntry {
    static func fixture(_ replay: ComputerUseReplay, store: ReplayBlobStore) -> ComputerUseReplayIndexEntry {
        ComputerUseReplayIndexEntry(
            replay: replay,
            documentBlobID: "doc",
            blobIDs: replay.thumbnails.map(\.blobID) + ["doc"],
            releasedAt: replay.endedAt,
            auditMarked: false,
            expiresAt: nil,
            access: ComputerUseBlobAccess(load: { try store.get($0) }, setExpiry: { store.setExpiry($0, $1) })
        )
    }
}

extension ComputerUseReplay {
    static func fixture(parent: UUID, lifecycleID: String, endedAt: Date) -> ComputerUseReplay {
        ComputerUseReplay(
            sessionID: UUID(),
            parentConversationID: parent,
            lifecycleID: lifecycleID,
            target: "Fake VM",
            startedAt: endedAt.addingTimeInterval(-60),
            endedAt: endedAt,
            terminalReason: .ended,
            steps: 1,
            records: [],
            thumbnails: []
        )
    }
}
