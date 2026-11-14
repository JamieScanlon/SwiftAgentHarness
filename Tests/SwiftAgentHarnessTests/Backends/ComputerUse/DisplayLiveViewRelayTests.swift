import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Live view relay")
struct DisplayLiveViewRelayTests {
    /// A target's side of a relayed view: the frames it gives out and what it was handed.
    actor Source {
        private(set) var frameCalls = 0
        private(set) var inputs: [DisplayLiveViewInput] = []
        private(set) var typed: [String] = []
        var frame: DisplayLiveViewFrame? = DisplayLiveViewFrame(jpeg: DisplayLiveViewServerTests.jpeg, width: 800, height: 600)

        func nextFrame() -> DisplayLiveViewFrame? {
            frameCalls += 1
            return frame
        }

        func take(_ input: DisplayLiveViewInput) { inputs.append(input) }
        func record(_ value: String) { typed.append(value) }

        nonisolated var source: DisplayLiveViewRelay.Source {
            DisplayLiveViewRelay.Source(
                frame: { await self.nextFrame() },
                input: { await self.take($0) },
                typed: { await self.record($0) }
            )
        }
    }

    static let click = #"{"type":"mouse","action":"down","x":10,"y":20,"button":"left","clickCount":1,"modifiers":[]}"#

    @Test("Frames are pulled only while someone watches, and stop when the last viewer leaves")
    func framesWhileWatched() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let relay = DisplayLiveViewRelay(server: server, frameInterval: .milliseconds(10))
        let source = Source()
        let lease = UUID()
        await relay.open(lease, label: "Guest", isShared: false, source: source.source)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await source.frameCalls == 0, "nobody watches yet")

        let viewer = try DisplayLiveViewServerTests.Viewer(try #require(try await relay.link(for: lease)))
        _ = try await viewer.status()
        let frame = try await viewer.frame()
        #expect(frame.width == 800 && frame.height == 600)
        #expect(await relay.viewerCount(lease) == 1)

        viewer.close()
        #expect(await DisplayLiveViewServerTests.eventually { await relay.viewerCount(lease) == 0 })
        try await Task.sleep(for: .milliseconds(30))
        let settled = await source.frameCalls
        try await Task.sleep(for: .milliseconds(60))
        #expect(await source.frameCalls == settled, "no frames once nobody watches")
        await relay.close(lease)
    }

    @Test("A viewer's input reaches the target only while the lease has control, and its typing is reported")
    func inputDuringControl() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let relay = DisplayLiveViewRelay(server: server, frameInterval: .milliseconds(10))
        let source = Source()
        let lease = UUID()
        await relay.open(lease, label: "Guest", isShared: false, source: source.source)
        let viewer = try DisplayLiveViewServerTests.Viewer(try #require(try await relay.link(for: lease)))
        _ = try await viewer.status()

        try await viewer.send(Self.click)
        try await viewer.roundTrip()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await source.inputs.isEmpty)

        await relay.setControl(true, for: lease)
        try await viewer.send(Self.click)
        try await viewer.send(#"{"type":"text","text":"hunter2"}"#)
        try await viewer.roundTrip()
        #expect(await DisplayLiveViewServerTests.eventually { await source.inputs.count == 2 })
        await relay.setControl(false, for: lease)
        #expect(await DisplayLiveViewServerTests.eventually { await source.typed == ["hunter2"] })
        await relay.close(lease)
    }

    @Test("Closing a lease's view ends its viewers and revokes its links; other leases keep theirs")
    func closeOne() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let relay = DisplayLiveViewRelay(server: server, frameInterval: .milliseconds(10))
        let first = UUID()
        let second = UUID()
        await relay.open(first, label: "One", isShared: false, source: Source().source)
        await relay.open(second, label: "Two", isShared: false, source: Source().source)
        let viewer = try DisplayLiveViewServerTests.Viewer(try #require(try await relay.link(for: first)))
        _ = try await viewer.status()
        let unused = try #require(try await relay.link(for: first))

        await relay.close(first)
        #expect(try await viewer.status().reason == .sessionEnded)
        #expect(try await relay.link(for: first) == nil)
        let late = try DisplayLiveViewServerTests.Viewer(unused)
        #expect(await late.next() == nil, "the closed view's links are revoked")
        #expect(try await relay.link(for: second) != nil)
        await relay.close(second)
    }

    @Test("A shared target's view takes no observers by default")
    func sharedObservers() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let relay = DisplayLiveViewRelay(server: server)
        let lease = UUID()
        await relay.open(lease, label: "This Mac", isShared: true, source: Source().source)
        await #expect(throws: DisplayTargetError.self) { try await relay.link(for: lease, role: .observer) }
        #expect(try await relay.link(for: lease) != nil)
        await relay.close(lease)
    }
}
