import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use replays never record a takeover")
struct ComputerUseTakeoverReplayTests {
    @Test("A takeover's start and end are marked in the session's events, which the replay carries")
    func marksTheGap() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        try await session.setTakeover(true)
        try await session.setTakeover(false)
        let kinds = await session.events.map(\.kind)
        #expect(kinds == [.takeoverStarted, .takeoverEnded])
        #expect(ComputerUseSessionEvent.Kind.takeoverStarted.rawValue == "takeover-started")
        #expect(ComputerUseSessionEvent.Kind.takeoverEnded.rawValue == "takeover-ended")
        let replay = try await ComputerUseReplay(
            session: session, parentConversationID: UUID(), lifecycleID: "run", targetLabel: "Fake", endedAt: Date(),
            storeThumbnail: { _ in "blob" }
        )
        #expect(replay.events.map(\.kind) == [.takeoverStarted, .takeoverEnded])
    }

    @Test("A takeover the session ends with is marked as ended too")
    func endedDuringTakeover() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make()
        try await session.setTakeover(true)
        await session.end(.cancelled)
        #expect(await session.events.map(\.kind) == [.takeoverStarted, .takeoverEnded, .ended])
    }

    @Test("A takeover the user starts at the target is marked as well")
    func targetTakeover() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        await session.announceStart()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        target.eventHub.post(.takeoverChanged(on: true))
        for _ in 0..<400 where await !session.isTakeoverActive { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await session.events.map(\.kind) == [.takeoverStarted])
    }

    @Test("An observation that returns after a takeover began is kept out of the replay")
    func inFlightObservation() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let before = await session.replayFrames.count
        #expect(before == 1)
        await target.setOnObserve { try? await session.setTakeover(true) }
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(await session.isTakeoverActive)
        #expect(await session.replayFrames.count == before, "the user may be typing a credential")
    }
}
