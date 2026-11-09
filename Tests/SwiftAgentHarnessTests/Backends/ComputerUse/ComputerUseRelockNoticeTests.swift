import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

@Suite("A target that couldn't be locked again after a run says so")
struct ComputerUseRelockNoticeTests {
    static let notice = "Your Mac could not be locked after the run and may be unlocked."

    private static func request(_ target: DisplayTargetID, grants: [ComputerUseGrant] = ComputerUseSessionFixtures.grants) -> LeaseRequest {
        LeaseRequest(
            target: target,
            agentID: "agent",
            grants: grants,
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)),
            initiator: .operator,
            userPresent: true
        )
    }

    @Test("A relock failure the target reports at release reaches the conversation on the session's last activity")
    func sessionPostsNotice() async throws {
        let activities = Mutex<[ComputerUseActivity]>([])
        let (target, session) = try await ComputerUseSessionFixtures.make(activity: { activity in
            activities.withLock { $0.append(activity) }
        })
        await session.announceStart()
        await target.setRelockNotice(Self.notice)
        await session.end(.ended)
        let ended = try #require(activities.withLock { $0.last })
        #expect(ended.status == .ended)
        #expect(ended.notice == Self.notice)
        #expect(await session.relockNotice == Self.notice)
        let payload = SubAgentSpawnService.activityPayload(ended, target: "This Mac", lifecycleID: "run", liveView: false)
        #expect(payload.notice == Self.notice)
    }

    @Test("A session whose target relocked, or never needed to, ends with no notice")
    func noNotice() async throws {
        let activities = Mutex<[ComputerUseActivity]>([])
        let (_, session) = try await ComputerUseSessionFixtures.make(activity: { activity in
            activities.withLock { $0.append(activity) }
        })
        await session.announceStart()
        await session.end(.ended)
        #expect(activities.withLock { $0.last?.notice } == nil)
    }

    @Test("A host's relock failure crosses the wire before the release returns, and only to a client that agreed to it")
    func overTheWire() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        await target.setRelockNotice(Self.notice)
        let server = DisplayHostServer(target: target, name: "test-host")
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let serving = Task { await server.serve(host) }
        let remote = try await RemoteDisplayTarget.connect(over: client)
        #expect(await remote.capabilities.contains(.relockNotice))
        let lease = try await remote.lease(Self.request(target.manifest.id))
        let events = await remote.events(lease)
        await remote.release(lease, reason: .completed)
        var received: [DisplayTargetEvent] = []
        for await event in events { received.append(event) }
        #expect(received == [.relockFailed(Self.notice)])
        await remote.close()
        await serving.value
    }

    @Test("A client that didn't agree to relock notices isn't sent one")
    func olderClient() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        await target.setRelockNotice(Self.notice)
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let serving = Task { await DisplayHostServer(target: target).serve(host) }
        var replies = client.inbound.makeAsyncIterator()
        try await client.send(DisplayHostCodec.encode(.request(id: 1, body: .hello(version: DisplayHostProtocol.version, client: "raw", capabilities: [.events]))))
        _ = try await replies.next()
        try await client.send(DisplayHostCodec.encode(.request(id: 2, body: .lease(request: DisplayHostLeaseRequest(Self.request(target.manifest.id))))))
        guard case .response(2, .lease(let lease, _)) = try DisplayHostCodec.decode(try #require(try await replies.next())) else {
            Issue.record("expected a lease")
            return
        }
        try await client.send(DisplayHostCodec.encode(.request(id: 3, body: .release(leaseID: lease.id, reason: .completed))))
        let next = try DisplayHostCodec.decode(try #require(try await replies.next()))
        #expect(next == .response(id: 3, body: .done), "no event before the release's reply")
        await client.close()
        await serving.value
    }
}

@Suite("Whether the user unlocked the target from somewhere else")
struct ComputerUseRemoteUnlockTests {
    private static func request(_ target: DisplayTargetID) -> LeaseRequest {
        LeaseRequest(
            target: target,
            agentID: "agent",
            grants: [.app(bundleID: ComputerUseFixtures.textEdit.bundleID, tier: .full)],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)),
            initiator: .operator,
            userPresent: true
        )
    }

    @Test("An unlock card answered off the target marks the lease a remote unlock; answered on it, or with no unlock, it isn't")
    func remoteUnlock() async throws {
        for (locked, offTarget, expected) in [(true, true, true), (true, false, false), (false, true, false)] {
            let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
            await target.setLocked(locked)
            let registry = try DisplayTargetRegistry(targets: [target])
            let grant = try await registry.lease(Self.request(target.manifest.id)) { request in
                ComputerUseGrantAnswer(grants: request.review.grantable.map(\.grant), answeredOffTarget: offTarget)
            }
            #expect(await target.leasedRemoteUnlock == [expected], "locked \(locked), off target \(offTarget)")
            await grant.target.release(grant.lease, reason: .completed)
        }
    }

    @Test("A plain approver is taken as answered on the target")
    func plainApprover() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
        await target.setLocked(true)
        let registry = try DisplayTargetRegistry(targets: [target])
        let grant = try await registry.lease(Self.request(target.manifest.id), approve: { $0.review.grantable.map(\.grant) })
        #expect(await target.leasedRemoteUnlock == [false])
        await grant.target.release(grant.lease, reason: .completed)
    }

    @Test("A remote unlock crosses the display host wire, and an older client's request reads as not remote")
    func wire() throws {
        var request = Self.request("fake-vm")
        request.foundLocked = true
        request.remoteUnlock = true
        let wire = DisplayHostLeaseRequest(request)
        let decoded = try JSONDecoder().decode(DisplayHostLeaseRequest.self, from: JSONEncoder().encode(wire))
        #expect(decoded.leaseRequest(isHolderAlive: { true }).remoteUnlock)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try #require(String(data: try encoder.encode(wire), encoding: .utf8))
        let older = json.replacingOccurrences(of: #","remoteUnlock":true"#, with: "")
        #expect(older != json)
        #expect(try JSONDecoder().decode(DisplayHostLeaseRequest.self, from: Data(older.utf8)).remoteUnlock == false)
    }
}
