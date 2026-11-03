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
                                let body = request.hasPrefix("GET /second") ? second : request.hasPrefix("GET /file") ? "payload" : page
                                let type = request.hasPrefix("GET /file")
                                    ? "application/octet-stream\r\nContent-Disposition: attachment; filename=\"setup.pkg\""
                                    : "text/html"
                                let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
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

    @Test("Streams the page to a live view and takes the viewer's input during takeover")
    func liveView() async throws {
        let server = try await Self.server()
        defer { Task { try? await server.channel.close(); await server.task.value } }
        let liveView = DisplayLiveViewServer()
        defer { Task { await liveView.stop() } }
        let target = ManagedBrowserDisplayTarget.localChromium(
            configuration: ManagedBrowserConfiguration(network: BrowserNetworkPolicy(allowsPrivateNetwork: true, blockedDomains: ["tracker.test"])),
            chromium: ManagedChromiumConfiguration(headless: true),
            liveView: liveView
        )
        let lease = try await Self.lease(target)
        _ = try await target.act(lease, ActionBatch([.openURL("http://127.0.0.1:\(server.port)/")]))
        let first = try await target.observe(lease, ObserveRequest(modes: [.accessibility], scope: .display(nil)))
        let button = try #require(first.tree?.elements.values.first { $0.role == "button" }?.frame)

        let viewer = try DisplayLiveViewServerTests.Viewer(try #require(try await target.liveView(lease)))
        #expect(try await viewer.status().control == false)
        let frame = try await viewer.frame()
        #expect(frame.jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(frame.width == 1280 && frame.height == 800)

        try await target.takeover(lease, on: true)
        #expect(try await viewer.status().control == true)
        let (x, y) = (button.center.x, button.center.y)
        try await viewer.send(#"{"type":"mouse","action":"down","x":\#(x),"y":\#(y),"button":"left","clickCount":1}"#)
        try await viewer.send(#"{"type":"mouse","action":"up","x":\#(x),"y":\#(y),"button":"left","clickCount":1}"#)
        try await viewer.roundTrip()
        try await Task.sleep(for: .milliseconds(300))
        try await target.takeover(lease, on: false)
        #expect(try await viewer.status().control == false)

        let after = try await target.observe(lease, ObserveRequest(modes: [.accessibility], scope: .display(nil)))
        #expect(after.tree?.elements.values.contains { $0.role == "button" && $0.label == "Clicked" } == true)
        await target.release(lease, reason: .completed)
        #expect(try await viewer.status().type == "ended")
    }

    @Test("The browser exits on its own when the harness's end of the pipe closes, and its profile is swept later")
    func exitsWithPipe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-profiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // No page is loaded, so the proxy port is never dialed.
        let browser = try await ManagedChromium.launch(ManagedChromiumConfiguration(headless: true, profileRoot: root), proxyPort: 9)
        let processID = browser.processID
        await browser.connection.close()
        let deadline = ContinuousClock.now + .seconds(10)
        var status: Int32 = 0
        var exited = false
        while ContinuousClock.now < deadline {
            if waitpid(processID, &status, WNOHANG) == processID { exited = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(exited, "the browser outlived its pipe")
        if !exited { kill(processID, SIGKILL) }

        let profiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(profiles.count == 1, "the profile is left until something sweeps it")
        let old = Date().addingTimeInterval(-ManagedChromium.unlockedProfileGrace - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(profiles[0]).path)
        ManagedChromium.removeStaleProfiles(in: root, hostName: ManagedChromium.currentHostName(), now: Date())
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await browser.shutdown()
    }

    @Test("Runs scripts against the page's DOM, out of reach of the page's JavaScript and the tree builder")
    func scripts() async throws {
        let server = try await Self.server()
        defer { Task { try? await server.channel.close(); await server.task.value } }
        let target = ManagedBrowserDisplayTarget.localChromium(
            configuration: ManagedBrowserConfiguration(network: BrowserNetworkPolicy(allowsPrivateNetwork: true, blockedDomains: ["tracker.test"])),
            chromium: ManagedChromiumConfiguration(headless: true)
        )
        let lease = try await Self.lease(target)
        _ = try await target.act(lease, ActionBatch([.openURL("http://127.0.0.1:\(server.port)/")]))
        func run(_ source: String, timeout: Int = 5_000) async throws -> ActionOutcome {
            try #require(try await target.act(lease, ActionBatch([.script(language: .javascript, source: source, timeoutMilliseconds: timeout)])).first)
        }

        let read = try await run("""
        await new Promise((resolve) => setTimeout(resolve, 10));
        document.getElementById("name").value = "Ada";
        return { title: document.title, heading: document.querySelector("h1").textContent, pageGlobal: typeof window.onclickHandlerFromPage };
        """)
        #expect(read.evidence?.contains(#"returned: {"title":"Smoke page","heading":"Managed browser","pageGlobal":"undefined"}"#) == true, "\(read)")
        let observed = try await target.observe(lease, ObserveRequest(modes: [.accessibility], scope: .display(nil)))
        #expect(observed.tree?.text.contains("Managed browser") == true, "the tree builder's world is untouched")

        let thrown = try await run("missing.call();")
        #expect(thrown.effect == .partial)
        #expect(thrown.evidence?.contains("threw: ReferenceError") == true, "\(thrown)")

        let slow = try await run("await new Promise(() => {});", timeout: 300)
        #expect(slow.evidence?.contains("timed out after 300 ms") == true, "\(slow)")

        let spin = try await run("while (true) {}", timeout: 300)
        #expect(spin.effect == .partial, "\(spin)")
        #expect(spin.evidence?.contains("stopped after 300 ms") == true, "\(spin)")
        let after = try await run("return 1 + 1;")
        #expect(after.evidence?.contains("returned: 2") == true, "the page still answers after a runaway script: \(after)")

        let blocked = try await run(#"location.href = "http://tracker.test/"; await new Promise((r) => setTimeout(r, 500)); return 0;"#)
        #expect(blocked.evidence?.contains("tracker.test") == true, "\(blocked)")
        await target.release(lease, reason: .completed)
    }

    @Test("Attaches to a running browser's own profile: a tab of its own, the user's tabs untouched, downloads cancelled")
    func userBrowser() async throws {
        let server = try await Self.server()
        defer { Task { try? await server.channel.close(); await server.task.value } }
        let executable = try #require(ManagedChromiumConfiguration().resolvedExecutable())
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("user-browser-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let chrome = Process()
        chrome.executableURL = executable
        chrome.arguments = [
            "--headless=new", "--remote-debugging-port=0", "--user-data-dir=\(profile.path)", "--no-first-run",
            "--no-default-browser-check", "--use-mock-keychain", "about:blank",
        ]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        try chrome.run()
        defer { chrome.terminate() }
        let endpoint = UserBrowserEndpoint.devToolsActivePort(directory: profile)
        for _ in 0..<100 where (try? endpoint.resolve()) == nil { try await Task.sleep(for: .milliseconds(100)) }
        let port = try #require(try endpoint.resolve().port)
        func pages() async throws -> [String] {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/list")!)
            let list = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            return list.filter { $0["type"] as? String == "page" }.compactMap { $0["id"] as? String }.sorted()
        }
        let userTabs = try await pages()
        #expect(userTabs.count == 1)

        let target = ManagedBrowserDisplayTarget.userBrowser(
            endpoint: endpoint,
            configuration: ManagedBrowserConfiguration(id: "user-browser", label: "Your browser", network: BrowserNetworkPolicy(allowsPrivateNetwork: true))
        )
        let lease = try await Self.lease(target)
        #expect(try await pages().count == 2, "the agent gets a tab of its own")
        let home = "http://127.0.0.1:\(server.port)/"
        let opened = try await target.act(lease, ActionBatch([.openURL(home)]))
        #expect(opened.first?.effect == .confirmed, "\(opened)")
        let title = try await target.act(lease, ActionBatch([.script(language: .javascript, source: "return document.title;", timeoutMilliseconds: 2_000)]))
        #expect(title.first?.evidence?.contains(#"returned: "Smoke page""#) == true, "\(title)")

        _ = try await target.act(lease, ActionBatch([.openURL(home + "file")]))
        try await Task.sleep(for: .milliseconds(500))
        let observed = try await target.observe(lease, ObserveRequest(modes: [.accessibility], scope: .display(nil)))
        #expect(observed.tree?.text.contains("download of setup.pkg, which was cancelled") == true, "\(observed.tree?.text ?? "")")

        await target.release(lease, reason: .completed)
        #expect(try await pages() == userTabs, "release closes only the agent's tab")
        #expect(chrome.isRunning, "the user's browser keeps running")
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
