import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use control service")
struct ComputerUseControlServiceTests {
    private let parent = UUID()

    private func installation() -> ComputerUseInstallation {
        ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
    }

    @Test("Status lists the conversation's pending requests and live sessions, not another conversation's")
    func status() async throws {
        let installation = installation()
        let control = ComputerUseControlService(installation: installation)
        try await ComputerUseFixtures.registerLiveSession(in: installation, parent: parent, lifecycleID: "call-1")
        try await ComputerUseFixtures.registerLiveSession(in: installation, parent: UUID(), lifecycleID: "call-other")
        let (_, asking) = try await ComputerUseFixtures.pendingQuestion(
            "Which file?", coordinator: try #require(installation.coordinator), conversationID: parent, lifecycleID: "call-1"
        )
        defer { asking.cancel() }

        let status = await control.status(conversationID: parent)
        #expect(status.pending.map(\.prompt) == ["Which file?"])
        #expect(status.sessions == [
            ComputerUseSessionStatus(lifecycleID: "call-1", target: "Fake host desktop", step: 0, maxSteps: 12, takenOver: false, liveView: false, sharedScreen: true),
        ])
    }

    @Test("Status gives each target's lock state as the target reports it when the status is read")
    func targetLockState() async throws {
        let host = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
        let vm = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher(), targets: [vm, host])
        let control = ComputerUseControlService(installation: installation)
        await host.setLocked(true)

        let expected = [
            ComputerUseTargetStatus(id: host.manifest.id, label: host.manifest.label, locked: true),
            ComputerUseTargetStatus(id: vm.manifest.id, label: vm.manifest.label, locked: false),
        ].sorted { $0.id < $1.id }
        #expect(await control.status(conversationID: parent).targets == expected)

        await host.setLocked(false)
        let unlocked = await control.status(conversationID: parent).targets.first { $0.id == host.manifest.id }
        #expect(unlocked?.locked == false, "unlocked at the desk since the last read")
    }

    @Test("A target that doesn't answer in time reads as unlocked, so a client never unlocks a screen it can't vouch for")
    func lockStateTimeout() async throws {
        let host = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
        await host.setLocked(true)
        await host.setOnIsLocked { try? await Task.sleep(for: .seconds(60)) }
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher(), targets: [host])
        let control = ComputerUseControlService(installation: installation)

        let started = ContinuousClock.now
        let status = await control.status(conversationID: parent, lockStateTimeout: .milliseconds(50))
        #expect(status.targets.map(\.locked) == [false])
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("Stop ends only the conversation's sessions and declines their pending requests")
    func stop() async throws {
        let installation = installation()
        let control = ComputerUseControlService(installation: installation)
        let (mine, _) = try await ComputerUseFixtures.registerLiveSession(in: installation, parent: parent, lifecycleID: "call-1")
        let (other, _) = try await ComputerUseFixtures.registerLiveSession(in: installation, parent: UUID(), lifecycleID: "call-2")
        let (_, asking) = try await ComputerUseFixtures.pendingQuestion(
            "Which file?", coordinator: try #require(installation.coordinator), conversationID: parent, lifecycleID: "call-1"
        )

        #expect(await control.stop(conversationID: parent) == ["call-1"])
        #expect(await asking.value == .declined)
        #expect(await mine.terminalReason == .killSwitch)
        #expect(await other.terminalReason == nil)
        #expect(await control.status(conversationID: parent).sessions.isEmpty)
    }

    @Test("Takeover toggles the conversation's live sessions")
    func takeover() async throws {
        let installation = installation()
        let control = ComputerUseControlService(installation: installation)
        let (session, target) = try await ComputerUseFixtures.registerLiveSession(in: installation, parent: parent, lifecycleID: "call-1")

        #expect(try await control.setTakeover(true, conversationID: parent, lifecycleID: nil) == ["call-1"])
        #expect(await session.isTakeoverActive)
        #expect(try await control.setTakeover(false, conversationID: parent, lifecycleID: "call-1") == ["call-1"])
        #expect(await target.takeoverStates == [true, false])
        #expect(try await control.setTakeover(true, conversationID: parent, lifecycleID: "call-missing").isEmpty)
    }

    @Test("The user lists a live run's viewers and revokes one connection")
    func revokeConnection() async throws {
        let installation = installation()
        let control = ComputerUseControlService(installation: installation)
        let (_, target) = try await ComputerUseFixtures.registerLiveSession(in: installation, parent: parent, lifecycleID: "call-1")
        let watcher = DisplayLiveViewConnection(id: UUID(), role: .observer, connectedAt: ComputerUseFixtures.epoch)
        let user = DisplayLiveViewConnection(id: UUID(), role: .user, connectedAt: ComputerUseFixtures.epoch)
        await target.setConnections([user, watcher])
        #expect(try await control.liveConnections(conversationID: parent, lifecycleID: "call-1") == [user, watcher])
        #expect(try await control.revokeLiveView(conversationID: parent, lifecycleID: "call-1", linkID: watcher.id))
        #expect(try await control.liveConnections(conversationID: parent, lifecycleID: "call-1") == [user])
        #expect(try await control.revokeLiveView(conversationID: parent, lifecycleID: "call-1", linkID: watcher.id) == false)
        #expect(try await control.liveConnections(conversationID: parent, lifecycleID: "call-missing") == nil)
    }

    @Test("A live view link comes from the run's target, and none from an unknown or ended run")
    func liveView() async throws {
        let installation = installation()
        let control = ComputerUseControlService(installation: installation)
        let (session, target) = try await ComputerUseFixtures.registerLiveSession(in: installation, parent: parent, lifecycleID: "call-1")
        let link = DisplayLiveView(url: "http://127.0.0.1:9/view#t", viewOnly: true, expiresAt: ComputerUseFixtures.epoch)
        await target.setLiveViewLink(link)

        #expect(try await control.liveView(conversationID: parent, lifecycleID: "call-1") == link)
        let observerLink = try #require(try await control.liveView(conversationID: parent, lifecycleID: "call-1", role: .observer))
        #expect(observerLink.role == .observer)
        #expect(await target.liveViewRoles == [.user, .observer])
        #expect(try await control.endObservers(conversationID: parent, lifecycleID: "call-1"))
        #expect(await target.observerEnds == 1)
        #expect(try await control.endObservers(conversationID: parent, lifecycleID: "call-missing") == false)
        #expect(try await control.liveView(conversationID: UUID(), lifecycleID: "call-1") == nil)
        #expect(try await control.liveView(conversationID: parent, lifecycleID: "call-missing") == nil)
        await session.stop()
        #expect(try await control.liveView(conversationID: parent, lifecycleID: "call-1") == nil)
        #expect(try await control.endObservers(conversationID: parent, lifecycleID: "call-1") == false)
    }

    @Test("Resolving a request reports unknown ids and kind mismatches separately")
    func resolve() async throws {
        let installation = installation()
        let control = ComputerUseControlService(installation: installation)
        let (request, asking) = try await ComputerUseFixtures.pendingQuestion(
            "Which file?", coordinator: try #require(installation.coordinator), conversationID: parent, lifecycleID: "call-1"
        )

        #expect(await control.resolve(requestID: "nope", conversationID: parent, resolution: .declined) == .notFound)
        #expect(await control.resolve(requestID: request.id, conversationID: UUID(), resolution: .declined) == .notFound)
        #expect(await control.resolve(requestID: request.id, conversationID: parent, resolution: .handedBack(note: nil)) == .wrongKind)
        #expect(await control.resolve(requestID: request.id, conversationID: parent, resolution: .answered("The second")) == .resolved)
        #expect(await asking.value == .answered("The second"))
    }

    @Test("Without an installed configuration there is nothing to control")
    func notInstalled() async throws {
        let control = ComputerUseControlService(installation: ComputerUseInstallation())
        let status = await control.status(conversationID: parent)
        #expect(status.pending.isEmpty && status.sessions.isEmpty)
        #expect(await control.resolve(requestID: "x", conversationID: parent, resolution: .declined) == .notFound)
        #expect(await control.stop(conversationID: parent).isEmpty)
    }
}
