import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Managed browser live view")
struct ManagedBrowserLiveViewTests {
    typealias FakeBrowser = ManagedBrowserDisplayTargetTests.FakeBrowser
    typealias Viewer = DisplayLiveViewServerTests.Viewer

    private static func leased(liveView: DisplayLiveViewServer?) async throws -> (FakeBrowser, ManagedBrowserDisplayTarget, Lease) {
        let browser = FakeBrowser()
        await browser.script(url: "https://shop.example.com/")
        let target = ManagedBrowserDisplayTarget(configuration: ManagedBrowserConfiguration(settleDelay: .zero), isolation: .container, liveView: liveView) {
            ManagedBrowserSession(connection: browser)
        }
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "specialist",
            grants: [.domain("example.com", tier: .full)],
            budgets: ComputerUseBudgets(steps: 20, maxDuration: .seconds(600)),
            operatorInitiated: true,
            userPresent: true
        ))
        return (browser, target, lease)
    }

    private static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        await DisplayLiveViewServerTests.eventually(condition)
    }

    private static func frameEvent(_ jpeg: Data, ack: Int) -> CDPEvent {
        CDPEvent(method: "Page.screencastFrame", params: .object([
            "data": .string(jpeg.base64EncodedString()),
            "metadata": .object(["deviceWidth": .integer(1280), "deviceHeight": .integer(800)]),
            "sessionId": .integer(ack),
        ]), sessionID: "s1")
    }

    @Test("Without a live view server the target offers none")
    func none() async throws {
        let (_, target, lease) = try await Self.leased(liveView: nil)
        #expect(target.manifest.observerAccess == .none)
        #expect(try await target.liveView(lease) == nil)
    }

    @Test("A viewer starts the screencast and sees its frames; the last viewer leaving stops it")
    func screencast() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let (browser, target, lease) = try await Self.leased(liveView: server)
        #expect(target.manifest.observerAccess == .stream)
        let link = try #require(try await target.liveView(lease))
        #expect(link.viewOnly)
        #expect(await browser.methods("Page.startScreencast").isEmpty, "nothing is streamed until someone watches")

        let viewer = try Viewer(link)
        #expect(try await viewer.status().label == "Managed browser")
        #expect(await Self.eventually { await !browser.methods("Page.startScreencast").isEmpty })
        await browser.emit(Self.frameEvent(DisplayLiveViewServerTests.jpeg, ack: 5))
        let frame = try await viewer.frame()
        #expect(frame.width == 1280 && frame.height == 800 && frame.jpeg == DisplayLiveViewServerTests.jpeg)
        #expect(await browser.params(of: "Page.screencastFrameAck").first?[wire: "sessionId"]?.wireInt == 5)

        viewer.close()
        #expect(await Self.eventually { await !browser.methods("Page.stopScreencast").isEmpty })
        await target.release(lease, reason: .completed)
    }

    @Test("A viewer's input reaches the page only during takeover")
    func takeoverInput() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let (browser, target, lease) = try await Self.leased(liveView: server)
        let viewer = try Viewer(try #require(try await target.liveView(lease)))
        #expect(try await viewer.status().control == false)
        try await viewer.send(#"{"type":"mouse","action":"down","x":10,"y":20,"button":"left","clickCount":1}"#)
        try await viewer.roundTrip()
        #expect(await browser.methods("Input.").isEmpty)

        try await target.takeover(lease, on: true)
        #expect(try await viewer.status().control == true)
        #expect(try await target.liveView(lease)?.viewOnly == false)
        try await viewer.send(#"{"type":"mouse","action":"down","x":10,"y":20,"button":"left","clickCount":1}"#)
        try await viewer.send(#"{"type":"key","action":"down","key":"a","code":"KeyA","keyCode":65,"modifiers":["meta"]}"#)
        try await viewer.send(#"{"type":"text","text":"hunter2"}"#)
        try await viewer.send(#"{"type":"wheel","x":5000,"y":-3,"dx":0,"dy":120}"#)
        #expect(await Self.eventually { await browser.methods("Input.").count == 4 })

        let press = try #require(await browser.params(of: "Input.dispatchMouseEvent").first)
        #expect(press[wire: "type"]?.wireString == "mousePressed")
        #expect(press[wire: "x"]?.wireNumber == 10 && press[wire: "y"]?.wireNumber == 20)
        let key = try #require(await browser.params(of: "Input.dispatchKeyEvent").first)
        #expect(key[wire: "type"]?.wireString == "rawKeyDown")
        #expect(key[wire: "commands"]?.wireArray?.first?.wireString == "selectAll")
        #expect(await browser.params(of: "Input.insertText").first?[wire: "text"]?.wireString == "hunter2")
        let wheel = try #require(await browser.params(of: "Input.dispatchMouseEvent").last)
        #expect(wheel[wire: "x"]?.wireNumber == 1279 && wheel[wire: "y"]?.wireNumber == 0, "points are kept in the viewport")

        try await target.takeover(lease, on: false)
        #expect(try await viewer.status().control == false)
        await target.release(lease, reason: .completed)
    }

    @Test("An observer watches but never controls, and ending observers leaves the user's viewer")
    func observer() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let (browser, target, lease) = try await Self.leased(liveView: server)
        try await target.takeover(lease, on: true)
        let link = try #require(try await target.liveView(lease, role: .observer))
        #expect(link.role == .observer && link.viewOnly)
        let observer = try Viewer(link)
        #expect(try await observer.status().paused == true)
        try await observer.send(#"{"type":"text","text":"hunter2"}"#)
        try await observer.roundTrip()
        #expect(await browser.methods("Input.").isEmpty)

        #expect(try await target.liveViewers(lease) == 0, "an observer isn't the user watching")
        let user = try Viewer(try #require(try await target.liveView(lease)))
        _ = try await user.status()
        #expect(try await target.liveViewers(lease) == 1)
        try await target.endObservers(lease)
        #expect(try await observer.status().reason == .sharingStopped)
        await browser.emit(Self.frameEvent(DisplayLiveViewServerTests.jpeg, ack: 1))
        #expect(try await user.frame().width == 1280, "the user's viewer stays")
        await target.release(lease, reason: .completed)
        await #expect(throws: DisplayTargetError.leaseNotHeld) { try await target.endObservers(lease) }
    }

    @Test("Release ends the viewers and revokes the link")
    func release() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let (_, target, lease) = try await Self.leased(liveView: server)
        let link = try #require(try await target.liveView(lease))
        let viewer = try Viewer(link)
        _ = try await viewer.status()
        await target.release(lease, reason: .completed)
        #expect(try await viewer.status().reason == .sessionEnded)
        #expect(await (try Viewer(link)).next(within: .seconds(1)) == nil)
        await #expect(throws: DisplayTargetError.leaseNotHeld) { try await target.liveView(lease) }
    }

    @Test("A blocked page the user reached during takeover is cleared at hand-back and reported")
    func handBackPolicy() async throws {
        let (browser, target, lease) = try await Self.leased(liveView: nil)
        try await target.takeover(lease, on: true)
        await browser.script(url: "http://10.0.0.7/admin")
        try await target.takeover(lease, on: false)
        #expect(await browser.params(of: "Page.navigate").last?[wire: "url"]?.wireString == "about:blank")
        let observed = try await target.observe(lease, ObserveRequest(modes: [.accessibility], scope: .display(nil)))
        #expect(observed.tree?.text.contains("During the takeover the page went to http://10.0.0.7/admin") == true)
    }
}
