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
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)),
            initiator: .operator,
            userPresent: true,
            isHolderAlive: isHolderAlive
        )
    }

    /// A served fake target and a client connected to it over an in-memory pair.
    private static func connected(
        _ target: FakeDisplayTarget = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest),
        configuration: DisplayHostServerConfiguration = DisplayHostServerConfiguration(),
        sharesFilesystem: Bool = true
    ) async throws -> (FakeDisplayTarget, DisplayHostServer, RemoteDisplayTarget, Task<Void, Never>) {
        let server = DisplayHostServer(target: target, name: "test-host", configuration: configuration)
        let (client, host) = InMemoryDisplayHostConnection.pair(sharesFilesystem: sharesFilesystem)
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
        #expect(try await remote.liveView(lease, role: .observer) == nil)
        #expect(await target.liveViewRoles == [.user, .observer])
        try await remote.endObservers(lease)
        #expect(await target.observerEnds == 1)
        await target.setViewers(2)
        #expect(try await remote.liveViewers(lease) == 2)

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
        #expect(await target.releases == [.holderLost])

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
        var events = await remote.events(lease).makeAsyncIterator()
        await server.requestStop(leaseID: lease.id)
        #expect(await events.next() == .stopRequested)
        await remote.close()
        await serving.value
    }

    @Test("The target's own events reach the holder of the lease they concern, and end at release")
    func targetEvents() async throws {
        let (target, _, remote, serving) = try await Self.connected()
        let lease = try await remote.lease(Self.leaseRequest())
        var events = await remote.events(lease).makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(20))
        target.eventHub.post(.userTyping, to: lease.id)
        target.eventHub.post(.takeoverChanged(on: true), to: lease.id)
        #expect(await events.next() == .userTyping)
        #expect(await events.next() == .takeoverChanged(on: true))
        await remote.release(lease, reason: .completed)
        #expect(await events.next() == nil)
        await remote.close()
        await serving.value
    }

    @Test("A permission change at the host is pushed to lease holders")
    func permissionEvents() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let (_, _, remote, serving) = try await Self.connected(
            target, configuration: DisplayHostServerConfiguration(permissionPollInterval: .milliseconds(20))
        )
        let lease = try await remote.lease(Self.leaseRequest())
        var events = await remote.events(lease).makeAsyncIterator()
        await target.setPermission(.screenCapture, .denied)
        #expect(await events.next() == .permissionsChanged(await target.permissions()))
        await remote.close()
        await serving.value
    }

    @Test("Images travel as files on a shared filesystem, which the client reads and deletes, and inline otherwise")
    func imageFiles() async throws {
        let png = try ComputerUseFixtures.pngScreenshot(width: 32, height: 20)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-images-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (target, _, local, serving) = try await Self.connected(configuration: DisplayHostServerConfiguration(imageDirectory: directory))
        await target.setScreenshot(png)
        #expect(await local.capabilities.contains(.imageFiles))
        let lease = try await local.lease(Self.leaseRequest())
        let observation = try await local.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil)))
        #expect(observation.image?.data == png)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true, "read files are deleted")
        await local.close()
        await serving.value

        let (remoteTarget, _, remote, remoteServing) = try await Self.connected(sharesFilesystem: false)
        await remoteTarget.setScreenshot(png)
        #expect(await !remote.capabilities.contains(.imageFiles))
        let remoteLease = try await remote.lease(Self.leaseRequest())
        #expect(try await remote.observe(remoteLease, ObserveRequest(modes: [.pixels], scope: .display(nil))).image?.data == png)
        await remote.close()
        await remoteServing.value
    }

    @Test("A dropped holder keeps its lease through the grace period and takes it back over a new connection")
    func reattach() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let server = DisplayHostServer(target: target, configuration: DisplayHostServerConfiguration(reattachGrace: .seconds(5)))
        let current = Connections()
        let remote = try await RemoteDisplayTarget.connect(using: {
            let (client, host) = InMemoryDisplayHostConnection.pair()
            await current.set(host, serving: Task { await server.serve(host) })
            return client
        })
        let lease = try await remote.lease(Self.leaseRequest())
        await current.dropHost()
        await #expect(throws: DisplayTargetError.targetBusy(holder: "agent")) {
            _ = try await target.lease(Self.leaseRequest(agentID: "other"))
        }
        for _ in 0..<100 where await current.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let observation = try await remote.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil)))
        #expect(observation.id == "o_1", "the lease works over the new connection")
        #expect(await target.releases.isEmpty)
        await remote.close()
        await current.waitAll()
    }

    @Test("A holder that doesn't come back within the grace period loses the lease as holder-lost")
    func graceExpires() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let server = DisplayHostServer(target: target, configuration: DisplayHostServerConfiguration(reattachGrace: .milliseconds(100)))
        let (client, host) = InMemoryDisplayHostConnection.pair()
        let serving = Task { await server.serve(host) }
        let remote = try await RemoteDisplayTarget.connect(over: client)
        _ = try await remote.lease(Self.leaseRequest())
        await host.close()
        await serving.value
        #expect(await target.releases.isEmpty, "still within the grace period")
        for _ in 0..<100 where await target.releases.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await target.releases == [.holderLost])
        _ = try await target.lease(Self.leaseRequest(agentID: "other"))
    }

    /// The connections a reconnecting client made, so a test can drop one.
    actor Connections {
        private var hosts: [InMemoryDisplayHostConnection] = []
        private var serving: [Task<Void, Never>] = []

        var count: Int { hosts.count }

        func set(_ host: InMemoryDisplayHostConnection, serving task: Task<Void, Never>) {
            hosts.append(host)
            serving.append(task)
        }

        func dropHost() async {
            await hosts.last?.close()
            await serving.last?.value
        }

        func waitAll() async {
            for task in serving { await task.value }
        }
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

        let future = DisplayHostVersion(major: 99, minor: 0)
        try await client.send(DisplayHostCodec.encode(.request(id: 2, body: .hello(version: future, client: "future", capabilities: []))))
        let reply = try DisplayHostCodec.decode(try #require(try await replies.next()))
        #expect(reply == .response(id: 2, body: .failure(.versionMismatch(host: DisplayHostProtocol.version, client: future))))
        await client.close()
        await serving.value
    }

    @Test("A newer minor version is accepted with the capabilities both sides have; requests outside them are refused")
    func minorVersion() async throws {
        let (client, host) = InMemoryDisplayHostConnection.pair(sharesFilesystem: false)
        let serving = Task { await DisplayHostServer(target: FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)).serve(host) }
        var replies = client.inbound.makeAsyncIterator()
        let newer = DisplayHostVersion(major: DisplayHostProtocol.version.major, minor: DisplayHostProtocol.version.minor + 3)
        let offered = [DisplayHostCapability.events, .imageFiles, DisplayHostCapability(rawValue: "holograms")]
        try await client.send(DisplayHostCodec.encode(.request(id: 1, body: .hello(version: newer, client: "newer", capabilities: offered))))
        let welcome = try DisplayHostCodec.decode(try #require(try await replies.next()))
        guard case .response(id: 1, body: .welcome(let version, _, _, let agreed, let directory)) = welcome else {
            Issue.record("expected a welcome, got \(welcome)")
            return
        }
        #expect(version == DisplayHostProtocol.version)
        #expect(agreed == [.events], "image files need a shared filesystem, and holograms are unknown")
        #expect(directory == nil)
        try await client.send(DisplayHostCodec.encode(.request(id: 2, body: .liveViewers(leaseID: UUID()))))
        let refused = try DisplayHostCodec.decode(try #require(try await replies.next()))
        #expect(refused == .response(id: 2, body: .failure(.unsupported(.liveView))))
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
                    id: id, body: .welcome(version: DisplayHostVersion(major: 99, minor: 0), host: "future", manifest: FakeDisplayTarget.vmManifest, capabilities: [], imageDirectory: nil)
                )))
            }
        }
        await #expect(throws: DisplayHostError.versionMismatch(host: DisplayHostVersion(major: 99, minor: 0), client: DisplayHostProtocol.version)) {
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
            budgets: ComputerUseBudgets(steps: 1, maxDuration: .seconds(60)),
            initiator: .operator,
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
