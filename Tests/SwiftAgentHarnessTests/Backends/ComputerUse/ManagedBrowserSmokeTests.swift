import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwiftAgentHarness

/// Drives a real Chromium. Opt in with `SWIFTAGENTHARNESS_BROWSER_SMOKE=1`; needs Chrome or Chromium installed.
@Suite(
    "Managed browser smoke",
    .enabled(if: ProcessInfo.processInfo.environment["SWIFTAGENTHARNESS_BROWSER_SMOKE"] == "1"),
    .serialized
)
struct ManagedBrowserSmokeTests {
    static let page = """
    <!doctype html><html><head><title>Smoke page</title></head><body>
    <h1>Managed browser</h1>
    <button id="b" onclick="this.textContent='Clicked'">Click me</button>
    <label>Name <input id="name" autocomplete="name"></label>
    <label>Secret <input id="pw" type="password"></label>
    <a href="/second">Second page</a>
    <img src="http://tracker.test/pixel.png" alt="">
    </body></html>
    """

    static let second = "<!doctype html><title>Second</title><p>You made it.</p>"

    /// Serves the two pages over plain HTTP on loopback.
    private static func server() async throws -> (port: Int, channel: any Channel, task: Task<Void, Never>) {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel) }
            }
        let task = Task<Void, Never> {
            try? await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await connection in inbound {
                        group.addTask {
                            try? await connection.executeThenClose { input, output in
                                var request = ""
                                for try await buffer in input {
                                    request += String(buffer: buffer)
                                    if request.contains("\r\n\r\n") { break }
                                }
                                let body = request.hasPrefix("GET /second") ? second : page
                                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                                try await output.write(ByteBuffer(string: response))
                            }
                        }
                    }
                }
            }
        }
        return (try #require(server.channel.localAddress?.port), server.channel, task)
    }

    private static func lease(_ target: ManagedBrowserDisplayTarget) async throws -> Lease {
        try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "smoke",
            grants: [.domain("127.0.0.1", tier: .full)],
            budgets: ComputerUseBudgets(steps: 50, maxDuration: .seconds(600)),
            operatorInitiated: true,
            userPresent: true
        ))
    }

    @Test("Observes the DOM and pixels, clicks, types, sets values, and navigates")
    func drives() async throws {
        let server = try await Self.server()
        defer { Task { try? await server.channel.close(); await server.task.value } }
        let target = ManagedBrowserDisplayTarget.localChromium(
            configuration: ManagedBrowserConfiguration(network: BrowserNetworkPolicy(allowsPrivateNetwork: true, blockedDomains: ["tracker.test"])),
            chromium: ManagedChromiumConfiguration(headless: true)
        )
        let lease = try await Self.lease(target)
        let home = "http://127.0.0.1:\(server.port)/"

        let opened = try await target.act(lease, ActionBatch([.openURL(home)]))
        #expect(opened.first?.effect == .confirmed, "\(opened)")
        #expect(opened.first?.evidence?.contains("tracker.test") == true, "\(opened)")

        let first = try await target.observe(lease, ObserveRequest(modes: [.accessibility, .pixels], scope: .display(nil)))
        let tree = try #require(first.tree)
        print(tree.text)
        #expect(first.target.url == home)
        #expect(first.image?.geometry.imageSize == ImagePixelSize(width: 1280, height: 800))
        #expect(first.image?.geometry.capturedRect == DisplayRect(x: 0, y: 0, width: 1280, height: 800))
        let button = try #require(tree.elements.values.first { $0.role == "button" })
        let name = try #require(tree.elements.values.first { $0.role == "textbox" && $0.inputPurpose == "name" })
        let secret = try #require(tree.elements.values.first { $0.isSecureInput })
        let link = try #require(tree.elements.values.first { $0.role == "link" })
        #expect(tree.text.contains("heading 1 \"Managed browser\""))

        let clicked = try await target.act(lease, ActionBatch([.click(at: .ref(button.id, observation: first.id))]))
        #expect(clicked.first?.evidence?.contains("the page changed") == true, "\(clicked)")
        let typed = try await target.act(lease, ActionBatch([.type(text: "Ada", into: .ref(name.id, observation: first.id))]))
        #expect(typed.first?.effect == .unverifiable, "\(typed)")
        let set = try await target.act(lease, ActionBatch([.setValue(at: .ref(secret.id, observation: first.id), value: "hunter2")]))
        #expect(set.first?.effect == .confirmed, "\(set)")

        let second = try await target.observe(lease, ObserveRequest(modes: [.accessibility], scope: .display(nil)))
        let after = try #require(second.tree)
        #expect(after.elements[button.id]?.label == "Clicked")
        #expect(after.text.contains("value=\"Ada\""))
        #expect(after.text.contains("(7 characters)"))
        #expect(!after.text.contains("hunter2"))

        let stale = try await target.act(lease, ActionBatch([.click(at: .ref(button.id, observation: first.id))]))
        #expect(stale.first?.effect == .refused, "a label change is drift: \(stale)")

        let zoom = try await target.observe(lease, ObserveRequest(modes: [.pixels], scope: .region(DisplayRect(x: 0, y: 0, width: 200, height: 100))))
        #expect(zoom.image?.geometry.imageSize == ImagePixelSize(width: 400, height: 200))

        let navigated = try await target.act(lease, ActionBatch([.click(at: .point(link.frame!.center, observation: second.id))]))
        #expect(navigated.first?.evidence?.contains("navigated") == true, "\(navigated)")
        let third = try await target.observe(lease, ObserveRequest(modes: [.accessibility], scope: .display(nil)))
        #expect(third.target.url == home + "second")
        #expect(third.tree?.text.contains("You made it.") == true)

        let scheme = try await target.act(lease, ActionBatch([.openURL("file:///etc/hosts")]))
        #expect(scheme.first?.effect == .refused)
        await target.release(lease, reason: .completed)
    }

    @Test("Loopback is unreachable under the default policy, even through a page")
    func defaultPolicy() async throws {
        let server = try await Self.server()
        defer { Task { try? await server.channel.close(); await server.task.value } }
        let target = ManagedBrowserDisplayTarget.localChromium(chromium: ManagedChromiumConfiguration(headless: true))
        let lease = try await Self.lease(target)
        let refused = try await target.act(lease, ActionBatch([.openURL("http://127.0.0.1:\(server.port)/")]))
        #expect(refused.first?.effect == .refused)
        #expect(refused.first?.evidence?.contains("loopback") == true, "\(refused)")
        let local = try await target.act(lease, ActionBatch([.openURL("http://localhost:\(server.port)/")]))
        #expect(local.first?.effect == .refused, "\(local)")
        await target.release(lease, reason: .completed)
    }

    @Test("Public pages load through the proxy")
    func publicPage() async throws {
        let target = ManagedBrowserDisplayTarget.localChromium(chromium: ManagedChromiumConfiguration(headless: true))
        let lease = try await Self.lease(target)
        let opened = try await target.act(lease, ActionBatch([.openURL("https://example.com/")]))
        print(opened)
        let observed = try await target.observe(lease, ObserveRequest(modes: [.accessibility], scope: .display(nil)))
        print(observed.tree?.text ?? "no tree")
        #expect(observed.tree?.text.contains("Example Domain") == true)
        await target.release(lease, reason: .completed)
    }
}
