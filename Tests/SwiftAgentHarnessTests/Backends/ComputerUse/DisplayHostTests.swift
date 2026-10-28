import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Display host protocol: remote targets over a connection")
struct DisplayHostTests {
    private static func leaseRequest(
        target: DisplayTargetID = FakeDisplayTarget.vmManifest.id,
        agentID: String = "agent",
        isHolderAlive: @escaping @Sendable () async -> Bool = { true }
    ) -> LeaseRequest {
        LeaseRequest(
            target: target,
            agentID: agentID,
            grants: ComputerUseSessionFixtures.grants,
            budgets: ComputerUseBudgets(maxSteps: 10, maxDuration: .seconds(60)),
            operatorInitiated: true,
            userPresent: true,
            isHolderAlive: isHolderAlive
        )
    }

    /// A served fake target and a client connected to it over an in-memory pair.
    private static func connected(
        _ target: FakeDisplayTarget = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
    ) async throws -> (FakeDisplayTarget, DisplayHostServer, RemoteDisplayTarget, Task<Void, Never>) {
        let server = DisplayHostServer(target: target, name: "test-host")
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let serving = Task { await server.serve(host) }
        let remote = try await RemoteDisplayTarget.connect(over: client, clientName: "test-client")
        return (target, server, remote, serving)
    }

    @Test("The handshake carries the host's manifest and name")
    func handshake() async throws {
        let (_, _, remote, serving) = try await Self.connected()
        #expect(remote.manifest == FakeDisplayTarget.vmManifest)
        #expect(remote.hostName == "test-host")
        await remote.close()
        await serving.value
    }

    @Test("Every target call round-trips, including screenshot bytes")
    func roundTrip() async throws {
        let (target, _, remote, serving) = try await Self.connected()
        let png = try ComputerUseFixtures.pngScreenshot(width: 64, height: 40)
        await target.setScreenshot(png)

        let lease = try await remote.lease(Self.leaseRequest())
        #expect(lease.holder == "agent")
        #expect(await remote.permissions() == PermissionSnapshot(states: [:]))
        #expect(try await remote.describe(lease).displays.first?.id == "main")

        let observation = try await remote.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil)))
        #expect(observation.id == "o_1")
        #expect(observation.image?.data == png)

        let outcomes = try await remote.act(lease, ActionBatch([.type(text: "hi"), .key(combo: try KeyCombo(parsing: "cmd+s"))]))
        #expect(outcomes.map(\.effect) == [.confirmed, .confirmed])
        #expect(await target.actCalls == [[.type(text: "hi"), .key(combo: try KeyCombo(parsing: "cmd+s"))]])

        try await remote.takeover(lease, on: true)
        #expect(await target.takeoverStates == [true])
        #expect(try await remote.liveView(lease) == nil)

        await remote.release(lease, reason: .completed)
        #expect(await target.releases == [.completed])
        await remote.close()
        await serving.value
    }

    @Test("Target errors arrive as the same errors")
    func errors() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest, permissions: [.screenCapture: .denied])
        let (_, _, remote, serving) = try await Self.connected(target)
        #expect(await remote.permissions().missing(FakeDisplayTarget.hostManifest.requires) == [.screenCapture, .accessibility, .postEvents])
        let lease = try await remote.lease(Self.leaseRequest(target: FakeDisplayTarget.hostManifest.id))
        await remote.release(lease, reason: .completed)
        await #expect(throws: DisplayTargetError.leaseNotHeld) {
            _ = try await remote.describe(lease)
        }
        await remote.close()
        await serving.value
    }

    @Test("One connection cannot use another connection's lease")
    func leaseOwnership() async throws {
        let (_, server, first, serving) = try await Self.connected()
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let servingSecond = Task { await server.serve(host) }
        let second = try await RemoteDisplayTarget.connect(over: client)

        let lease = try await first.lease(Self.leaseRequest())
        await #expect(throws: DisplayTargetError.leaseNotHeld) {
            _ = try await second.act(lease, ActionBatch([.type(text: "x")]))
        }
        await #expect(throws: DisplayTargetError.targetBusy(holder: "agent")) {
            _ = try await second.lease(Self.leaseRequest(agentID: "other"))
        }
        await first.close()
        await second.close()
        await serving.value
        await servingSecond.value
    }

    @Test("A disconnected client's leases are released so another client can lease")
    func disconnectReleases() async throws {
        let (target, server, first, serving) = try await Self.connected()
        _ = try await first.lease(Self.leaseRequest())
        await first.close()
        await serving.value
        #expect(await target.releases == [.aborted])

        let (client, host) = InMemoryDisplayHostConnection.pair()
        let servingSecond = Task { await server.serve(host) }
        let second = try await RemoteDisplayTarget.connect(over: client)
        let lease = try await second.lease(Self.leaseRequest(agentID: "other"))
        #expect(lease.holder == "other")
        await second.close()
        await servingSecond.value
    }

    @Test("A lease whose local holder died is released and re-leased")
    func deadLocalHolder() async throws {
        let (_, _, remote, serving) = try await Self.connected()
        _ = try await remote.lease(Self.leaseRequest(agentID: "crashed", isHolderAlive: { false }))
        let lease = try await remote.lease(Self.leaseRequest(agentID: "fresh"))
        #expect(lease.holder == "fresh")
        await remote.close()
        await serving.value
    }

    @Test("Calls in flight fail as driver failures when the host goes away")
    func hostGone() async throws {
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let server = DisplayHostServer(target: FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest))
        let serving = Task { await server.serve(host) }
        let remote = try await RemoteDisplayTarget.connect(over: client)
        let lease = try await remote.lease(Self.leaseRequest())
        await host.close()
        await serving.value
        await #expect(throws: DisplayTargetError.self) {
            _ = try await remote.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil)))
        }
        #expect(await remote.permissions() == PermissionSnapshot(states: [:]))
    }

    @Test("Concurrent calls are matched to their own responses")
    func multiplexing() async throws {
        let (_, _, remote, serving) = try await Self.connected()
        let lease = try await remote.lease(Self.leaseRequest())
        let ids = try await withThrowingTaskGroup(of: ObservationID.self) { group in
            for _ in 0..<20 {
                group.addTask { try await remote.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil))).id }
            }
            return try await group.reduce(into: Set<ObservationID>()) { $0.insert($1) }
        }
        #expect(ids.count == 20)
        await remote.close()
        await serving.value
    }

    @Test("The host can ask a lease holder to stop")
    func stopEvent() async throws {
        let (_, server, remote, serving) = try await Self.connected()
        let lease = try await remote.lease(Self.leaseRequest())
        var events = remote.events.makeAsyncIterator()
        await server.requestStop(leaseID: lease.id)
        #expect(await events.next() == .stopRequested(leaseID: lease.id))
        await remote.close()
        await serving.value
    }

    @Test("A host refuses a client speaking another protocol version, and requests before the handshake")
    func versionMismatch() async throws {
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let serving = Task { await DisplayHostServer(target: FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)).serve(host) }
        var replies = client.inbound.makeAsyncIterator()

        try await client.send(DisplayHostCodec.encode(.request(id: 1, body: .permissions)))
        let early = try DisplayHostCodec.decode(try #require(try await replies.next()))
        guard case .response(id: 1, body: .failure(.protocolError)) = early else {
            Issue.record("expected a protocol error, got \(early)")
            return
        }

        try await client.send(DisplayHostCodec.encode(.request(id: 2, body: .hello(version: 99, client: "future"))))
        let reply = try DisplayHostCodec.decode(try #require(try await replies.next()))
        #expect(reply == .response(id: 2, body: .failure(.versionMismatch(host: DisplayHostProtocol.version, client: 99))))
        await client.close()
        await serving.value
    }

    @Test("A client refuses a host speaking another protocol version")
    func clientVersionCheck() async throws {
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let fakeHost = Task {
            for try await data in host.inbound {
                guard case .request(let id, .hello) = try DisplayHostCodec.decode(data) else { continue }
                try await host.send(DisplayHostCodec.encode(.response(
                    id: id, body: .welcome(version: 99, host: "future", manifest: FakeDisplayTarget.vmManifest)
                )))
            }
        }
        await #expect(throws: DisplayHostError.versionMismatch(host: 99, client: DisplayHostProtocol.version)) {
            _ = try await RemoteDisplayTarget.connect(over: client)
        }
        await host.close()
        _ = await fakeHost.result
    }

    @Test("A computer-use session runs unchanged against a remote target")
    func sessionOverRemote() async throws {
        // The session checks lease expiry against the wall clock.
        let (target, _, remote, serving) = try await Self.connected(FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { Date() }))
        let lease = try await remote.lease(Self.leaseRequest())
        let session = ComputerUseSession(
            target: remote,
            lease: lease,
            configuration: ComputerUseSessionConfiguration(
                task: ComputerUseTaskContext(userRequest: ["Type hello."]),
                classifier: ComputerUseActionClassifier(reviewer: ComputerUseGrantReviewer(overrides: .none))
            )
        )
        let observed = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(observed.outcomes.map(\.effect) == [.confirmed])
        let typed = await session.perform([.type(text: "hello")])
        #expect(typed.outcomes.map(\.effect) == [.confirmed])
        #expect(await target.actCalls.last == [.type(text: "hello")])
        await remote.close()
        await serving.value
    }
}

@Suite("Display host framing")
struct DisplayHostFramingTests {
    @Test("Frames split across reads and joined in one read both decode")
    func splitAndJoined() throws {
        let one = Data("first".utf8)
        let two = Data(repeating: 7, count: 300)
        let wire = DisplayHostFraming.frame(one) + DisplayHostFraming.frame(two)
        var decoder = DisplayHostFrameDecoder()
        var frames: [Data] = []
        for byte in wire {
            frames += try decoder.append(Data([byte]))
        }
        #expect(frames == [one, two])

        var whole = DisplayHostFrameDecoder()
        #expect(try whole.append(wire) == [one, two])
    }

    @Test("A frame over the limit is refused before it is buffered")
    func oversized() {
        var decoder = DisplayHostFrameDecoder(maxFrameBytes: 16)
        #expect(throws: DisplayHostError.frameTooLarge(17)) {
            _ = try decoder.append(DisplayHostFraming.frame(Data(repeating: 0, count: 17)).prefix(4))
        }
    }
}

@Suite("Display host Unix-socket transport")
struct DisplayHostSocketTests {
    private static func socketPath() -> String {
        // sun_path is 104 bytes on Darwin, so keep it short.
        "/tmp/sah-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test("A client and host talk over a socket; the socket file is private and peers are known")
    func roundTrip() async throws {
        let path = Self.socketPath()
        let listener = try await DisplayHostSocket.listen(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let server = DisplayHostServer(target: target)
        let serving = Task { try await server.serve(listener) }

        let connection = try await DisplayHostSocket.connect(path: path)
        #expect(connection.peer.processID == ProcessInfo.processInfo.processIdentifier)
        #expect(connection.peer.userID == getuid())
        #expect(connection.peer.auditToken?.count == 8)

        let remote = try await RemoteDisplayTarget.connect(over: connection)
        #expect(remote.manifest == FakeDisplayTarget.vmManifest)
        let lease = try await remote.lease(LeaseRequest(
            target: remote.manifest.id,
            agentID: "agent",
            grants: [],
            budgets: ComputerUseBudgets(maxSteps: 1, maxDuration: .seconds(60)),
            operatorInitiated: true,
            userPresent: true
        ))
        let png = try ComputerUseFixtures.pngScreenshot()
        await target.setScreenshot(png)
        #expect(try await remote.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil))).image?.data == png)
        await remote.release(lease, reason: .completed)
        await remote.close()

        await listener.close()
        _ = await serving.result
    }

    @Test("A host rejects peers its requirement refuses, and a client rejects such a host")
    func peerRequirement() async throws {
        let path = Self.socketPath()
        let listener = try await DisplayHostSocket.listen(path: path, peers: DisplayHostPeerRequirement { _ in false })
        defer { try? FileManager.default.removeItem(atPath: path) }
        let serving = Task { try await DisplayHostServer(target: FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)).serve(listener) }

        let refused = try await DisplayHostSocket.connect(path: path)
        await #expect(throws: (any Error).self) {
            _ = try await RemoteDisplayTarget.connect(over: refused)
        }

        await #expect(throws: DisplayHostError.peerRejected) {
            _ = try await DisplayHostSocket.connect(path: path, peers: DisplayHostPeerRequirement { _ in false })
        }
        await listener.close()
        _ = await serving.result
    }
}
