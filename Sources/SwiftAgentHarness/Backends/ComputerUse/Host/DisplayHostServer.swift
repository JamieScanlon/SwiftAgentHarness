import Foundation

/// Serves one ``DisplayTarget`` to harnesses over display-host connections.
///
/// The process that runs this owns the target's platform permissions; how it is packaged (a menu-bar app, a
/// login item, a daemon, an existing app, an agent inside a VM) is up to the integrator. Each connection may use
/// only the leases it was issued, a lease's holder counts as alive while its connection is open, and a closed
/// connection's leases are released as aborted.
public actor DisplayHostServer {
    public nonisolated let name: String
    private let target: any DisplayTarget
    private var connections: [UUID: ConnectionState] = [:]

    private struct ConnectionState {
        var connection: any DisplayHostConnection
        var greeted = false
        var open = true
        var leases: [UUID: Lease] = [:]
    }

    public init(target: any DisplayTarget, name: String = ProcessInfo.processInfo.processName) {
        self.target = target
        self.name = name
    }

    /// Serves every connection `listener` accepts until it finishes.
    public func serve(_ listener: any DisplayHostListener) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            for try await connection in listener.connections {
                group.addTask { await self.serve(connection) }
            }
        }
    }

    /// Serves `connection` until it closes, then releases its leases.
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
        let message: Data
        do {
            message = try DisplayHostCodec.encode(.event(.stopRequested(leaseID: leaseID)))
        } catch {
            return
        }
        for state in connections.values where state.open {
            guard leaseID.map({ state.leases[$0] != nil }) ?? !state.leases.isEmpty else { continue }
            try? await state.connection.send(message)
        }
    }

    private func handle(_ request: DisplayHostRequest, connection id: UUID) async -> DisplayHostResponse {
        if case .hello(let version, _) = request {
            guard version == DisplayHostProtocol.version else {
                return .failure(.versionMismatch(host: DisplayHostProtocol.version, client: version))
            }
            connections[id]?.greeted = true
            return .welcome(version: DisplayHostProtocol.version, host: name, manifest: target.manifest)
        }
        guard connections[id]?.greeted == true else { return .failure(.protocolError("hello must come first")) }

        do {
            switch request {
            case .hello:
                return .failure(.protocolError("hello was already sent"))
            case .lease(let wire):
                let lease = try await target.lease(wire.leaseRequest { [weak self] in
                    await self?.isOpen(id) ?? false
                })
                guard connections[id]?.open == true else {
                    await target.release(lease, reason: .aborted)
                    return .failure(.target(.driverFailure("connection closed")))
                }
                connections[id]?.leases[lease.id] = lease
                return .lease(lease)
            case .release(let leaseID, let reason):
                if let lease = connections[id]?.leases.removeValue(forKey: leaseID) {
                    await target.release(lease, reason: reason)
                }
                return .done
            case .permissions:
                return .permissions(await target.permissions())
            case .describe(let leaseID):
                return .layout(try await target.describe(try lease(leaseID, connection: id)))
            case .observe(let leaseID, let observe):
                return .observation(try await target.observe(try lease(leaseID, connection: id), observe))
            case .act(let leaseID, let batch):
                return .outcomes(try await target.act(try lease(leaseID, connection: id), batch))
            case .liveView(let leaseID):
                return .liveView(try await target.liveView(try lease(leaseID, connection: id)))
            case .takeover(let leaseID, let on):
                try await target.takeover(try lease(leaseID, connection: id), on: on)
                return .done
            }
        } catch let error as DisplayTargetError {
            return .failure(.target(error))
        } catch {
            return .failure(.target(.driverFailure(String(describing: error))))
        }
    }

    private func lease(_ leaseID: UUID, connection id: UUID) throws(DisplayTargetError) -> Lease {
        guard let lease = connections[id]?.leases[leaseID] else { throw .leaseNotHeld }
        return lease
    }

    private func isOpen(_ id: UUID) -> Bool {
        connections[id]?.open ?? false
    }

    private func markClosed(_ id: UUID) {
        connections[id]?.open = false
    }

    private func disconnect(_ id: UUID) async {
        guard let state = connections.removeValue(forKey: id) else { return }
        for lease in state.leases.values {
            await target.release(lease, reason: .aborted)
        }
    }
}
