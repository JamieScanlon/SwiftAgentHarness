import Foundation

public struct DisplayHostServerConfiguration: Sendable {
    /// How long a lease outlives its dropped connection, waiting for the client to reattach, before it is released
    /// as `holder-lost`. Only for connections that agreed on reattaching.
    public var reattachGrace: Duration
    /// How often the host checks the target's permissions while it has leases, to tell holders of a change.
    public var permissionPollInterval: Duration
    /// Where images are written for connections that take them as files. A private temporary folder by default.
    public var imageDirectory: URL

    public init(
        reattachGrace: Duration = .seconds(5),
        permissionPollInterval: Duration = .seconds(2),
        imageDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("display-host-\(UUID().uuidString)", isDirectory: true)
    ) {
        self.reattachGrace = reattachGrace
        self.permissionPollInterval = permissionPollInterval
        self.imageDirectory = imageDirectory
    }
}

/// Serves one ``DisplayTarget`` to harnesses over display-host connections.
///
/// The process that runs this owns the target's platform permissions; how it is packaged (a menu-bar app, a
/// login item, a daemon, an existing app, an agent inside a VM) is up to the integrator. Each connection may use
/// only the leases it was issued or reattached. A lease's holder is alive while its connection is open; when the
/// connection drops, the lease waits out the reattach grace and is then released as `holder-lost`.
public actor DisplayHostServer {
    public nonisolated let name: String
    public nonisolated let configuration: DisplayHostServerConfiguration
    private let target: any DisplayTarget
    private var connections: [UUID: ConnectionState] = [:]
    private var leases: [UUID: HeldLease] = [:]
    private var endedWhileDetached: [UUID: EndedLease] = [:]
    /// Compared against when a reattach names no lease, so a refusal takes the same work either way.
    private let decoyToken = DisplayLiveViewServer.token()
    /// Holder keys whose lease is still held, connected or within its grace.
    private var liveHolders: Set<UUID> = []
    private var permissionWatch: Task<Void, Never>?
    private var lastPermissions: PermissionSnapshot?

    private struct ConnectionState {
        var connection: any DisplayHostConnection
        var greeted = false
        var open = true
        var capabilities: Set<DisplayHostCapability> = []
    }

    private struct HeldLease {
        var lease: Lease
        var holderKey: UUID
        /// `nil` while orphaned, waiting for a reattach.
        var connection: UUID?
        var reattachToken: String
        /// Watches the target's events for the lease's whole life, attached or not.
        var forwarder: Task<Void, Never>?
        var expiry: Task<Void, Never>?
        var takeover = false
    }

    /// A lease the host ended while it was detached, kept for the grace period so its holder learns why.
    private struct EndedLease {
        var lease: Lease
        var reattachToken: String
        var reason: ReleaseReason
        var expiry: Task<Void, Never>
    }

    public init(target: any DisplayTarget, name: String = ProcessInfo.processInfo.processName, configuration: DisplayHostServerConfiguration = DisplayHostServerConfiguration()) {
        self.target = target
        self.name = name
        self.configuration = configuration
    }

    /// Serves every connection `listener` accepts until it finishes.
    public func serve(_ listener: any DisplayHostListener) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            for try await connection in listener.connections {
                group.addTask { await self.serve(connection) }
            }
        }
    }

    /// Serves `connection` until it closes, then orphans or releases its leases.
    public func serve(_ connection: any DisplayHostConnection) async {
        let id = UUID()
        connections[id] = ConnectionState(connection: connection)
        await withDiscardingTaskGroup { group in
            do {
                for try await data in connection.inbound {
                    guard case .request(let requestID, let body) = try? DisplayHostCodec.decode(data) else { continue }
                    group.addTask {
                        let response = await self.handle(body, connection: id)
                        guard let message = try? DisplayHostCodec.encode(.response(id: requestID, body: response)) else { return }
                        try? await connection.send(message)
                    }
                }
            } catch {}
            markClosed(id)
        }
        await disconnect(id)
        await connection.close()
    }

    /// Asks the holder of `leaseID`, or of every lease when `nil`, to stop.
    public func requestStop(leaseID: UUID? = nil) async {
        for held in leases.values where leaseID.map({ $0 == held.lease.id }) ?? true {
            await send(.stopRequested, about: held.lease.id)
        }
    }

    // MARK: - Requests

    private func handle(_ request: DisplayHostRequest, connection id: UUID) async -> DisplayHostResponse {
        if case .hello(let version, _, let offered) = request {
            guard version.major == DisplayHostProtocol.version.major else {
                return .failure(.versionMismatch(host: DisplayHostProtocol.version, client: version))
            }
            var agreed = DisplayHostProtocol.capabilities.intersection(offered)
            if connections[id]?.connection.sharesFilesystem != true { agreed.remove(.imageFiles) }
            connections[id]?.greeted = true
            connections[id]?.capabilities = agreed
            return .welcome(
                version: DisplayHostProtocol.version,
                host: name,
                manifest: target.manifest,
                capabilities: agreed.sorted { $0.rawValue < $1.rawValue },
                imageDirectory: agreed.contains(.imageFiles) ? configuration.imageDirectory.path : nil
            )
        }
        guard let state = connections[id], state.greeted else { return .failure(.protocolError("hello must come first")) }
        if let needed = Self.capability(for: request), !state.capabilities.contains(needed) {
            return .failure(.unsupported(needed))
        }

        do {
            switch request {
            case .hello:
                return .failure(.protocolError("hello was already sent"))
            case .lease(let wire):
                let key = UUID()
                liveHolders.insert(key)
                let lease: Lease
                do {
                    lease = try await target.lease(wire.leaseRequest { [weak self] in
                        await self?.isHolderAlive(key) ?? false
                    })
                } catch {
                    liveHolders.remove(key)
                    throw error
                }
                guard connections[id]?.open == true else {
                    liveHolders.remove(key)
                    await target.release(lease, reason: .holderLost)
                    return .failure(.target(.driverFailure("connection closed")))
                }
                let token = DisplayLiveViewServer.token()
                leases[lease.id] = HeldLease(lease: lease, holderKey: key, connection: id, reattachToken: token)
                await startForwarding(lease)
                await watchPermissions()
                return .lease(lease, reattachToken: state.capabilities.contains(.reattach) ? token : nil)
            case .reattach(let leaseID, let token):
                if let ended = endedWhileDetached[leaseID], ObserverTokenIssuer.matches(ended.reattachToken, token) {
                    ended.expiry.cancel()
                    endedWhileDetached[leaseID] = nil
                    return .reattached(ended.lease, reattachToken: nil, snapshot: DisplayHostLeaseSnapshot(
                        permissions: await target.permissions(), takeover: false, releasedReason: ended.reason
                    ))
                }
                let expected = leases[leaseID]?.reattachToken ?? decoyToken
                guard ObserverTokenIssuer.matches(expected, token), var held = leases[leaseID], held.connection == nil else {
                    throw DisplayTargetError.leaseNotHeld
                }
                held.expiry?.cancel()
                held.expiry = nil
                held.connection = id
                held.reattachToken = DisplayLiveViewServer.token()
                leases[leaseID] = held
                return .reattached(held.lease, reattachToken: held.reattachToken, snapshot: DisplayHostLeaseSnapshot(
                    permissions: await target.permissions(), takeover: held.takeover
                ))
            case .release(let leaseID, let reason):
                if let held = leases[leaseID], held.connection == id {
                    await release(leaseID, reason: reason)
                }
                return .done
            case .permissions:
                return .permissions(await target.permissions())
            case .describe(let leaseID):
                return .layout(try await target.describe(try lease(leaseID, connection: id)))
            case .observe(let leaseID, let observe):
                let observation = try await target.observe(try lease(leaseID, connection: id), observe)
                guard state.capabilities.contains(.imageFiles), let data = observation.image?.data else {
                    return .observation(observation, imageFile: nil)
                }
                var stripped = observation
                stripped.image?.data = nil
                return .observation(stripped, imageFile: try writeImage(data))
            case .act(let leaseID, let batch):
                return .outcomes(try await target.act(try lease(leaseID, connection: id), batch))
            case .liveView(let leaseID, let role):
                return .liveView(try await target.liveView(try lease(leaseID, connection: id), role: role))
            case .liveViewers(let leaseID):
                return .liveViewers(try await target.liveViewers(try lease(leaseID, connection: id)))
            case .liveConnections(let leaseID):
                return .liveConnections(try await target.liveConnections(try lease(leaseID, connection: id)))
            case .revokeLiveView(let leaseID, let linkID):
                return .revoked(try await target.revokeLiveView(try lease(leaseID, connection: id), id: linkID))
            case .endObservers(let leaseID):
                try await target.endObservers(try lease(leaseID, connection: id))
                return .done
            case .takeover(let leaseID, let on):
                try await target.takeover(try lease(leaseID, connection: id), on: on)
                leases[leaseID]?.takeover = on
                return .done
            case .liveFrame(let leaseID):
                let frame = try await target.liveFrame(try lease(leaseID, connection: id))
                guard state.capabilities.contains(.imageFiles), var frame else { return .liveFrame(frame, imageFile: nil) }
                let file = try writeImage(frame.jpeg)
                frame.jpeg = Data()
                return .liveFrame(frame, imageFile: file)
            case .liveInput(let leaseID, let input):
                try await target.liveInput(try lease(leaseID, connection: id), input)
                return .done
            case .downloads(let leaseID):
                return .downloads(await target.downloads(try lease(leaseID, connection: id)))
            }
        } catch let error as DisplayTargetError {
            return .failure(.target(error))
        } catch {
            return .failure(.target(.driverFailure(String(describing: error))))
        }
    }

    private static func capability(for request: DisplayHostRequest) -> DisplayHostCapability? {
        switch request {
        case .liveView, .liveViewers, .liveConnections, .revokeLiveView, .endObservers, .liveFrame, .liveInput: .liveView
        case .downloads: .downloads
        case .reattach: .reattach
        case .hello, .lease, .release, .permissions, .describe, .observe, .act, .takeover: nil
        }
    }

    private func lease(_ leaseID: UUID, connection id: UUID) throws(DisplayTargetError) -> Lease {
        guard let held = leases[leaseID], held.connection == id else { throw .leaseNotHeld }
        return held.lease
    }

    private func writeImage(_ data: Data) throws -> String {
        let directory = configuration.imageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw DisplayTargetError.driverFailure("couldn't write an image file")
        }
        return file.path
    }

    // MARK: - Holders

    private func isHolderAlive(_ key: UUID) -> Bool {
        liveHolders.contains(key)
    }

    private func markClosed(_ id: UUID) {
        connections[id]?.open = false
    }

    private func disconnect(_ id: UUID) async {
        guard let state = connections.removeValue(forKey: id) else { return }
        for (leaseID, var held) in leases where held.connection == id {
            guard state.capabilities.contains(.reattach) else {
                await release(leaseID, reason: .holderLost)
                continue
            }
            held.connection = nil
            let grace = configuration.reattachGrace
            held.expiry = Task { [weak self] in
                guard (try? await Task.sleep(for: grace)) != nil else { return }
                await self?.expire(leaseID)
            }
            leases[leaseID] = held
        }
    }

    private func expire(_ leaseID: UUID) async {
        guard let held = leases[leaseID], held.connection == nil else { return }
        await release(leaseID, reason: .holderLost)
    }

    private func release(_ leaseID: UUID, reason: ReleaseReason) async {
        guard let held = leases.removeValue(forKey: leaseID) else { return }
        held.forwarder?.cancel()
        held.expiry?.cancel()
        liveHolders.remove(held.holderKey)
        await target.release(held.lease, reason: reason)
        if leases.isEmpty {
            permissionWatch?.cancel()
            permissionWatch = nil
            lastPermissions = nil
        }
    }

    // MARK: - Events

    private func startForwarding(_ lease: Lease) async {
        let stream = await target.events(lease)
        leases[lease.id]?.forwarder?.cancel()
        leases[lease.id]?.forwarder = Task { [weak self] in
            for await event in stream {
                await self?.handle(event, about: lease.id)
            }
        }
    }

    /// The host keeps the lease's state for a returning holder, and acts on a stop press itself while nobody holds
    /// the connection: the event would otherwise go nowhere.
    private func handle(_ event: DisplayTargetEvent, about leaseID: UUID) async {
        guard let held = leases[leaseID] else { return }
        switch event {
        case .takeoverChanged(let on):
            leases[leaseID]?.takeover = on
        case .stopRequested where held.connection == nil:
            let grace = configuration.reattachGrace
            endedWhileDetached[leaseID] = EndedLease(
                lease: held.lease,
                reattachToken: held.reattachToken,
                reason: .killSwitch,
                expiry: Task { [weak self] in
                    guard (try? await Task.sleep(for: grace)) != nil else { return }
                    await self?.forgetEnded(leaseID)
                }
            )
            // Releasing cancels the forwarder, which is the task running this.
            leases[leaseID]?.forwarder = nil
            await release(leaseID, reason: .killSwitch)
            return
        default:
            break
        }
        await send(event, about: leaseID)
    }

    private func forgetEnded(_ leaseID: UUID) {
        endedWhileDetached[leaseID] = nil
    }

    /// Sends `event` to the connection holding the lease. An orphaned lease's events are dropped.
    private func send(_ event: DisplayTargetEvent, about leaseID: UUID) async {
        guard let id = leases[leaseID]?.connection, let state = connections[id], state.open,
              state.capabilities.contains(.events),
              let message = try? DisplayHostCodec.encode(.event(.target(leaseID: leaseID, event: event)))
        else { return }
        try? await state.connection.send(message)
    }

    private func watchPermissions() async {
        guard permissionWatch == nil else { return }
        let baseline = await target.permissions()
        guard permissionWatch == nil, !leases.isEmpty else { return }
        lastPermissions = baseline
        let interval = configuration.permissionPollInterval
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: interval)) != nil else { return }
                await self?.checkPermissions()
            }
        }
    }

    private func checkPermissions() async {
        let current = await target.permissions()
        guard let last = lastPermissions, current != last else { return }
        lastPermissions = current
        for leaseID in leases.keys {
            await send(.permissionsChanged(current), about: leaseID)
        }
    }
}
