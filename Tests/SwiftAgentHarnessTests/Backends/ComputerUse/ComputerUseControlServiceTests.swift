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
            ComputerUseSessionStatus(lifecycleID: "call-1", target: "Fake host desktop", step: 0, maxSteps: 12, takenOver: false),
        ])
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
