#if os(macOS)
import Foundation
import Testing
import XPC
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

/// A target with no platform needs, so these tests exercise only the transports.
private actor StubDisplayTarget: DisplayTarget {
    nonisolated let manifest = DisplayTargetManifest(
        id: "stub",
        label: "Stub",
        platform: "macos",
        isolation: .vm,
        perception: [.pixels],
        delivery: [.background],
        humanPresence: .none
    )
    private let lock = DisplayTargetLeaseLock()

    func lease(_ request: LeaseRequest) async throws -> Lease {
        let lease = Lease(request: request, issuedAt: Date())
        try await lock.acquire(leaseID: lease.id, holder: .init(id: request.agentID, isAlive: request.isHolderAlive))
        return lease
    }

    func release(_ lease: Lease, reason: ReleaseReason) async {
        await lock.release(leaseID: lease.id)
    }

    func permissions() async -> PermissionSnapshot { PermissionSnapshot(states: [:]) }

    func describe(_ lease: Lease) async throws -> TargetLayout {
        TargetLayout(displays: [DisplayInfo(id: "main", frame: DisplayRect(x: 0, y: 0, width: 100, height: 100), scaleFactor: 1, isPrimary: true)])
    }

    func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        throw DisplayTargetError.unsupported("observe")
    }

    func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome] {
        batch.actions.indices.map { ActionOutcome(action: $0, effect: .confirmed) }
    }

    func takeover(_ lease: Lease, on: Bool) async throws {}
}

private func leaseRequest() -> LeaseRequest {
    LeaseRequest(
        target: "stub",
        agentID: "agent",
        grants: [],
        budgets: ComputerUseBudgets(steps: 1, maxDuration: .seconds(60)),
        operatorInitiated: true,
        userPresent: true
    )
}

@Suite("macOS display host: code-signature peer requirements")
struct MacCodeSignaturePeerTests {
    private static func socketPath() -> String {
        "/tmp/sah-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test("A malformed requirement is refused up front")
    func malformed() {
        #expect(throws: MacCodeSignatureError.self) {
            _ = try DisplayHostPeerRequirement.codeSignature("this is not a requirement (")
        }
    }

    @Test("A peer without an audit token is refused")
    func noToken() async throws {
        let requirement = try DisplayHostPeerRequirement.codeSignature(MacCodeSignature.designatedRequirementOfThisProcess())
        #expect(await !requirement.accepts(DisplayHostPeer(processID: getpid(), userID: getuid())))
    }

    @Test("Over a socket, a peer meeting the requirement is accepted and one that doesn't is refused")
    func socket() async throws {
        let path = Self.socketPath()
        let listener = try await DisplayHostSocket.listen(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let serving = Task { try await DisplayHostServer(target: StubDisplayTarget()).serve(listener) }

        let ownSigner = try DisplayHostPeerRequirement.codeSignature(MacCodeSignature.designatedRequirementOfThisProcess())
        let accepted = try await DisplayHostSocket.connect(path: path, peers: ownSigner)
        let remote = try await RemoteDisplayTarget.connect(over: accepted)
        #expect(remote.manifest.id == "stub")
        await remote.close()

        let other = try DisplayHostPeerRequirement.codeSignature(#"identifier "com.example.not-this-process""#)
        await #expect(throws: DisplayHostError.peerRejected) {
            _ = try await DisplayHostSocket.connect(path: path, peers: other)
        }
        await listener.close()
        _ = await serving.result
    }

    @Test("An ad-hoc signed process has no team to require")
    func noTeam() throws {
        guard MacCodeSignature.teamIdentifierOfThisProcess() == nil else { return }
        #expect(throws: MacCodeSignatureError.noTeamIdentifier) {
            _ = try DisplayHostPeerRequirement.sameTeamAsThisProcess()
        }
    }
}

@Suite("macOS display host: XPC transport")
struct MacDisplayHostXPCTests {
    @available(macOS 26.0, *)
    private static func ownIdentifier() throws -> XPCPeerRequirement {
        let identifier: String = try #require(MacCodeSignature.signingIdentifierOfThisProcess())
        var facts = XPCDictionary()
        facts["signing-identifier"] = identifier
        return XPCPeerRequirement(lightweightCodeRequirements: facts)
    }

    @available(macOS 26.0, *)
    @Test("A client and host talk over an anonymous XPC listener")
    func roundTrip() async throws {
        let requirement = try Self.ownIdentifier()
        let listener = try DisplayHostXPC.anonymousListener(requirement: requirement)
        let serving = Task { try await DisplayHostServer(target: StubDisplayTarget()).serve(listener) }

        let connection = try DisplayHostXPC.connect(endpoint: listener.endpoint, requirement: requirement)
        let remote = try await RemoteDisplayTarget.connect(over: connection)
        #expect(remote.manifest.id == "stub")
        let lease = try await remote.lease(leaseRequest())
        #expect(try await remote.act(lease, ActionBatch([.type(text: "hi")])).map(\.effect) == [.confirmed])
        await #expect(throws: DisplayTargetError.unsupported("observe")) {
            _ = try await remote.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil)))
        }
        await remote.release(lease, reason: .completed)
        await remote.close()
        await listener.close()
        _ = await serving.result
    }

    @available(macOS 26.0, *)
    @Test("A host refuses clients its requirement rejects")
    func hostRefuses() async throws {
        let listener = try DisplayHostXPC.anonymousListener(requirement: .isFromSameTeam())
        let serving = Task { try await DisplayHostServer(target: StubDisplayTarget()).serve(listener) }
        let connection = try DisplayHostXPC.connect(endpoint: listener.endpoint, requirement: try Self.ownIdentifier())
        await #expect(throws: (any Error).self) {
            _ = try await RemoteDisplayTarget.connect(over: connection)
        }
        await connection.close()
        await listener.close()
        _ = await serving.result
    }

    @available(macOS 26.0, *)
    @Test("A client refuses hosts its requirement rejects")
    func clientRefuses() async throws {
        let listener = try DisplayHostXPC.anonymousListener(requirement: try Self.ownIdentifier())
        let serving = Task { try await DisplayHostServer(target: StubDisplayTarget()).serve(listener) }
        let connection = try DisplayHostXPC.connect(endpoint: listener.endpoint, requirement: .isFromSameTeam())
        await #expect(throws: (any Error).self) {
            _ = try await RemoteDisplayTarget.connect(over: connection)
        }
        await connection.close()
        await listener.close()
        _ = await serving.result
    }
}
#endif
