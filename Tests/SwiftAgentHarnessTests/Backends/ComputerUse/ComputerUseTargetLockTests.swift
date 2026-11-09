import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use on a locked target: the grant request says so")
struct ComputerUseTargetLockTests {
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

    @Test("The grant request says whether the target is locked, and the lease carries it to the target")
    func grantRequestCarriesLockState() async throws {
        for locked in [true, false] {
            let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
            await target.setLocked(locked)
            let registry = try DisplayTargetRegistry(targets: [target])
            let asked = Mutex<Bool?>(nil)
            let grant = try await registry.lease(Self.request(target.manifest.id)) { request in
                asked.withLock { $0 = request.targetLocked }
                return request.review.grantable.map(\.grant)
            }
            #expect(asked.withLock { $0 } == locked)
            #expect(await target.leasedLocked == [locked])
            await grant.target.release(grant.lease, reason: .completed)
        }
    }

    @Test("A request nobody has checked says the target isn't locked")
    func uncheckedRequest() {
        #expect(Self.request("x").targetLocked == false)
    }

    @Test("The lock state the user was shown crosses the display host wire, and an older client's request reads as unlocked")
    func wire() throws {
        var request = Self.request("fake-vm")
        request.targetLocked = true
        let wire = DisplayHostLeaseRequest(request)
        let decoded = try JSONDecoder().decode(DisplayHostLeaseRequest.self, from: JSONEncoder().encode(wire))
        #expect(decoded == wire)
        #expect(decoded.leaseRequest(isHolderAlive: { true }).targetLocked)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try #require(String(data: try encoder.encode(wire), encoding: .utf8))
        #expect(json.contains(#""targetLocked":true,"#))
        let olderJSON = json.replacingOccurrences(of: #""targetLocked":true,"#, with: "")
        let older = try JSONDecoder().decode(DisplayHostLeaseRequest.self, from: Data(olderJSON.utf8))
        #expect(older.targetLocked == false)
    }

    @Test("A remote target asks its display host whether the target is locked, and the lease carries the answer")
    func remoteAsksHost() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let server = DisplayHostServer(target: target, name: "test-host")
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let serving = Task { await server.serve(host) }
        let remote = try await RemoteDisplayTarget.connect(over: client, clientName: "test-client")
        #expect(await remote.capabilities.contains(.lockState))
        #expect(await remote.isLocked() == false)
        await target.setLocked(true)
        #expect(await remote.isLocked())

        var request = Self.request(target.manifest.id)
        request.targetLocked = true
        let lease = try await remote.lease(request)
        #expect(await target.leasedLocked == [true])
        await remote.release(lease, reason: .completed)
        await remote.close()
        await serving.value
    }

    @Test("A display host that can't report lock state is taken as unlocked, and isn't asked")
    func olderHost() async throws {
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let requests = Mutex<[DisplayHostRequest]>([])
        let fakeHost = Task {
            for try await data in host.inbound {
                guard case .request(let id, let body) = try DisplayHostCodec.decode(data) else { continue }
                requests.withLock { $0.append(body) }
                if case .hello = body {
                    try await host.send(DisplayHostCodec.encode(.response(id: id, body: .welcome(
                        version: DisplayHostVersion(major: DisplayHostProtocol.version.major, minor: 0),
                        host: "older",
                        manifest: FakeDisplayTarget.vmManifest,
                        capabilities: [.events],
                        imageDirectory: nil
                    ))))
                }
            }
        }
        let remote = try await RemoteDisplayTarget.connect(over: client)
        #expect(await remote.isLocked() == false)
        #expect(requests.withLock { $0.count } == 1, "only the hello was sent")
        await remote.close()
        await host.close()
        _ = await fakeHost.result
    }

    @Test("A host refuses the lock-state question on a connection that didn't agree to it")
    func hostRefusesWithoutCapability() async throws {
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let serving = Task { await DisplayHostServer(target: FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)).serve(host) }
        var replies = client.inbound.makeAsyncIterator()
        try await client.send(DisplayHostCodec.encode(.request(id: 1, body: .hello(version: DisplayHostProtocol.version, client: "raw", capabilities: [.events]))))
        _ = try await replies.next()
        try await client.send(DisplayHostCodec.encode(.request(id: 2, body: .isLocked)))
        let refused = try DisplayHostCodec.decode(try #require(try await replies.next()))
        #expect(refused == .response(id: 2, body: .failure(.unsupported(.lockState))))
        await client.close()
        await serving.value
    }
}
