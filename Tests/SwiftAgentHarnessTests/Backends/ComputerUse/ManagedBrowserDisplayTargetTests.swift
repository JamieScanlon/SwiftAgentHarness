import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Managed browser display target")
struct ManagedBrowserDisplayTargetTests {
    typealias Element = ManagedBrowserPageSnapshot.Element

    /// A scripted Chromium: answers the commands the target sends and records them.
    actor FakeBrowser: CDPSending {
        var url = "about:blank"
        var doc = "d1"
        var scroll = (x: 0.0, y: 0.0)
        var mutations = 0
        var elements: [Element] = []
        var live: [String: ManagedBrowserResolvedElement] = [:]
        /// What a navigation to a URL ends at, to stand in for redirects.
        var redirects: [String: String] = [:]
        var lostContexts = 0
        var mutatesOnInput = false
        var submit: String?
        /// What a script's wrapper resolves to.
        var scriptReply = #"{"ok":true,"json":"null"}"#
        private(set) var calls: [(method: String, params: JSON)] = []
        private(set) var shutdowns = 0
        private var continuations: [AsyncStream<CDPEvent>.Continuation] = []

        func script(url: String? = nil, elements: [Element]? = nil, live: [String: ManagedBrowserResolvedElement]? = nil) {
            if let url { self.url = url }
            if let elements { self.elements = elements }
            if let live { self.live = live }
        }

        func setScroll(_ x: Double, _ y: Double) { scroll = (x, y) }
        func setSubmit(_ id: String?) { submit = id }
        func setRedirect(_ from: String, to: String) { redirects[from] = to }
        func loseContext() { lostContexts += 1 }
        func setMutatesOnInput() { mutatesOnInput = true }
        func setScriptReply(_ reply: String) { scriptReply = reply }
        func shutDown() { shutdowns += 1 }

        func emit(_ event: CDPEvent) {
            for continuation in continuations { continuation.yield(event) }
        }

        func methods(_ prefix: String = "") -> [String] {
            calls.map(\.method).filter { $0.hasPrefix(prefix) }
        }

        func params(of method: String) -> [JSON] {
            calls.filter { $0.method == method }.map(\.params)
        }

        func events() -> AsyncStream<CDPEvent> {
            let (stream, continuation) = AsyncStream.makeStream(of: CDPEvent.self)
            continuations.append(continuation)
            return stream
        }

        func send(_ method: String, _ params: JSON, session: String?) async throws -> JSON {
            calls.append((method, params))
            switch method {
            case "Target.createBrowserContext": return .object(["browserContextId": .string("ctx")])
            case "Target.createTarget": return .object(["targetId": .string("page-1")])
            case "Target.attachToTarget": return .object(["sessionId": .string("s1")])
            case "Target.getTargetInfo":
                return .object(["targetInfo": .object(["targetId": .string("page-1"), "browserContextId": .string("default-ctx")])])
            case "Page.getFrameTree": return .object(["frameTree": .object(["frame": .object(["id": .string("f1")])])])
            case "Page.createIsolatedWorld": return .object(["executionContextId": .integer(7 + calls.count)])
            case "Page.captureScreenshot":
                let clip = params[wire: "clip"]
                let scale = clip?[wire: "scale"]?.wireNumber ?? 1
                let width = Int(((clip?[wire: "width"]?.wireNumber ?? 0) * scale).rounded())
                let height = Int(((clip?[wire: "height"]?.wireNumber ?? 0) * scale).rounded())
                return .object(["data": .string(Self.png(width: width, height: height).base64EncodedString())])
            case "Page.navigate":
                let target = params[wire: "url"]?.wireString ?? ""
                url = redirects[target] ?? target
                doc = "d\(calls.count)"
                return .object(["frameId": .string("f1")])
            case "Input.dispatchMouseEvent", "Input.insertText", "Input.dispatchKeyEvent":
                if mutatesOnInput { mutations += 1 }
                return .object([:])
            case "Runtime.evaluate":
                if lostContexts > 0 {
                    lostContexts -= 1
                    throw CDPError(code: -32000, message: "Cannot find context with specified id")
                }
                if case .boolean(true)? = params[wire: "awaitPromise"] {
                    if scriptReply == "terminated" { throw CDPError(code: -32603, message: "Internal error") }
                    return .object(["result": .object(["value": .string(scriptReply)])])
                }
                return .object(["result": .object(["value": .string(try evaluate(params[wire: "expression"]?.wireString ?? ""))])])
            default:
                return .object([:])
            }
        }

        private func evaluate(_ expression: String) throws -> String {
            func called(_ function: String) -> Bool { expression.contains("})()).\(function)(") }
            var page = ManagedBrowserPageSnapshot(
                url: url, title: "Fixture", scrollX: scroll.x, scrollY: scroll.y, viewportWidth: 1280, viewportHeight: 800,
                mutations: mutations, readyState: "complete", doc: doc
            )
            let encoder = JSONEncoder()
            if called("snapshot") {
                page.elements = elements
                page.submit = submit
                return String(decoding: try encoder.encode(page), as: UTF8.self)
            }
            if called("page") { return String(decoding: try encoder.encode(page), as: UTF8.self) }
            let ref = expression.firstMatch(of: /\)\)\.\w+\("([^"]+)"/).map { String($0.1) } ?? ""
            if called("resolve") {
                return String(decoding: try encoder.encode(live[ref] ?? ManagedBrowserResolvedElement(error: "gone")), as: UTF8.self)
            }
            if called("setValue") {
                let value = expression.firstMatch(of: /, "[^"]*", "([^"]*)"\)\)$/).map { String($0.1) }
                return String(decoding: try encoder.encode(ManagedBrowserResolvedElement(value: value)), as: UTF8.self)
            }
            return String(decoding: try encoder.encode(ManagedBrowserResolvedElement(role: "button")), as: UTF8.self)
        }

        static func png(width: Int, height: Int) -> Data {
            var bytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
            for value in [width, height] {
                bytes += [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
            }
            return Data(bytes)
        }
    }

    static let button = Element(id: "e1", role: "button", name: "Save", x: 100, y: 100, w: 80, h: 30, depth: 0)
    static let field = Element(id: "e2", role: "textbox", name: "Password", x: 100, y: 200, w: 200, h: 30, depth: 1, secure: true, autocomplete: "current-password")
    static let link = Element(id: "e3", role: "link", name: "Docs", x: 100, y: 300, w: 60, h: 20, depth: 0, href: "https://docs.example.com/", offscreen: true)

    static func live(_ element: Element, covered: Bool = false, name: String? = nil, role: String? = nil) -> ManagedBrowserResolvedElement {
        ManagedBrowserResolvedElement(
            role: role ?? element.role, name: name ?? element.name, x: element.x, y: element.y, w: element.w, h: element.h,
            covered: covered ? true : nil, coveredBy: covered ? "dialog" : nil
        )
    }

    private struct Fixture {
        let browser: FakeBrowser
        let target: ManagedBrowserDisplayTarget
        let lease: Lease
        let denials: [BrowserNetworkDenial]
    }

    private static func fixture(
        network: BrowserNetworkPolicy = BrowserNetworkPolicy(),
        denials: [BrowserNetworkDenial] = [],
        profile: ManagedBrowserProfile = .throwaway
    ) async throws -> Fixture {
        let browser = FakeBrowser()
        await browser.script(url: "https://app.example.com/", elements: [button, field, link], live: [
            "e1": live(button), "e2": live(field), "e3": live(link),
        ])
        let target = ManagedBrowserDisplayTarget(
            configuration: ManagedBrowserConfiguration(network: network, settleDelay: .zero),
            isolation: profile == .user ? .host : .container,
            profile: profile
        ) {
            ManagedBrowserSession(
                connection: browser,
                networkDenials: { _ in denials },
                shutdown: { await browser.shutDown() }
            )
        }
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "specialist",
            grants: [.domain("example.com", tier: .full)],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(600)),
            initiator: .operator,
            userPresent: profile == .user
        ))
        return Fixture(browser: browser, target: target, lease: lease, denials: denials)
    }

    private static func observe(_ fixture: Fixture, modes: [ObservationMode] = [.accessibility, .pixels], scope: ObservationScope = .display(nil), limit: ObservationImageLimit? = nil) async throws -> DisplayObservation {
        try await fixture.target.observe(fixture.lease, ObserveRequest(modes: modes, scope: scope, maxImage: limit))
    }

    @Test("The tree names the control Return would trigger: the focused field's form submit element")
    func returnTarget() async throws {
        let fixture = try await Self.fixture()
        await fixture.browser.setSubmit("e1")
        let observation = try await fixture.target.observe(fixture.lease, ObserveRequest(modes: [.dom], scope: .display(nil)))
        #expect(observation.tree?.returnTarget == "e1")
    }

    @Test("It declares an isolated, unshared, DOM-and-pixels target with no platform permissions")
    func manifest() {
        let target = ManagedBrowserDisplayTarget(isolation: .container) { throw CDPError.closed }
        #expect(target.manifest.isolation == .container)
        #expect(ManagedBrowserDisplayTarget.localChromium().manifest.isolation == .process, "a launched browser shares the host's OS and network")
        #expect(target.manifest.humanPresence == .exclusive)
        #expect(target.manifest.perception == [.dom, .pixels])
        #expect(target.manifest.delivery == [.background])
        #expect(target.manifest.requires.isEmpty)
        #expect(ManagedBrowserDisplayTarget.hosted(endpoint: URL(string: "ws://browser.example/devtools")!).manifest.isolation == .remoteBrowser)
    }

    @Test("Each lease gets a fresh browser context with downloads denied, disposed with the browser on release")
    func leaseLifecycle() async throws {
        let fixture = try await Self.fixture()
        let opened = await fixture.browser.methods()
        #expect(Array(opened.prefix(4)) == ["Target.createBrowserContext", "Browser.setDownloadBehavior", "Target.createTarget", "Target.attachToTarget"])
        #expect(await fixture.browser.params(of: "Browser.setDownloadBehavior").first?[wire: "behavior"]?.wireString == "deny")
        #expect(await fixture.browser.params(of: "Emulation.setDeviceMetricsOverride").first?[wire: "width"]?.wireInt == 1280)

        await #expect(throws: DisplayTargetError.targetBusy(holder: "specialist")) {
            _ = try await fixture.target.lease(LeaseRequest(
                target: "managed-browser", agentID: "other", grants: [], budgets: ComputerUseBudgets(steps: 1, maxDuration: .seconds(60)),
                initiator: .operator, userPresent: true
            ))
        }
        await fixture.target.release(fixture.lease, reason: .completed)
        #expect(await fixture.browser.methods().contains("Target.disposeBrowserContext"))
        #expect(await fixture.browser.shutdowns == 1)
        await #expect(throws: DisplayTargetError.leaseNotHeld) { _ = try await Self.observe(fixture) }
    }

    @Test("An observation carries the page URL, a compact tree, refs with frames, and the screenshot geometry")
    func observation() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        #expect(observation.target.url == "https://app.example.com/")
        #expect(observation.target.app == nil)
        #expect(observation.target.bounds == DisplayRect(x: 0, y: 0, width: 1280, height: 800))
        let tree = try #require(observation.tree)
        #expect(tree.text == """
        page "Fixture" url=https://app.example.com/ obs=o_1
        [e1] button "Save"
          [e2] textbox "Password"
        [e3] link "Docs" href=https://docs.example.com/ offscreen
        """)
        #expect(tree.elements["e2"]?.isSecureInput == true)
        #expect(tree.elements["e2"]?.inputPurpose == "current-password")
        #expect(tree.elements["e1"]?.url == "https://app.example.com/")
        #expect(tree.elements["e1"]?.frame == DisplayRect(x: 100, y: 100, width: 80, height: 30))
        #expect(observation.image?.geometry == ScreenshotGeometry(
            capturedRect: DisplayRect(x: 0, y: 0, width: 1280, height: 800),
            imageSize: ImagePixelSize(width: 1280, height: 800),
            scaleFactor: 1
        ))
    }

    @Test("Screenshots render at the model's limit, and clips are offset by the page's scroll")
    func screenshotScaling() async throws {
        let fixture = try await Self.fixture()
        await fixture.browser.setScroll(0, 450)
        let small = try await Self.observe(fixture, modes: [.pixels], limit: ObservationImageLimit(longEdgePx: 640))
        #expect(small.image?.geometry.imageSize == ImagePixelSize(width: 640, height: 400))
        let clip = try #require(await fixture.browser.params(of: "Page.captureScreenshot").last?[wire: "clip"])
        #expect(clip[wire: "y"]?.wireNumber == 450)
        #expect(clip[wire: "scale"]?.wireNumber == 0.5)

        let zoom = try await Self.observe(fixture, modes: [.pixels], scope: .region(DisplayRect(x: 100, y: 100, width: 200, height: 50)))
        #expect(zoom.image?.geometry.capturedRect == DisplayRect(x: 100, y: 100, width: 200, height: 50))
        #expect(zoom.image?.geometry.imageSize == ImagePixelSize(width: 400, height: 100))
        #expect(zoom.target.bounds == DisplayRect(x: 100, y: 100, width: 200, height: 50))
    }

    @Test("A click on a ref lands on the element's live center with trusted mouse events")
    func clickRef() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        let outcomes = try await fixture.target.act(fixture.lease, ActionBatch([.click(at: .ref("e1", observation: observation.id), count: 2)]))
        #expect(outcomes.first?.effect == .unverifiable)
        let events = await fixture.browser.params(of: "Input.dispatchMouseEvent")
        #expect(events.map { $0[wire: "type"]?.wireString } == ["mouseMoved", "mousePressed", "mouseReleased", "mousePressed", "mouseReleased"])
        #expect(events.map { $0[wire: "clickCount"]?.wireInt } == [nil, 1, 1, 2, 2])
        #expect(events.allSatisfy { $0[wire: "x"]?.wireNumber == 140 && $0[wire: "y"]?.wireNumber == 115 })
    }

    @Test("A ref that is covered, relabeled, or gone is refused before any input")
    func refDrift() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        await fixture.browser.script(live: ["e1": Self.live(Self.button, covered: true), "e3": Self.live(Self.link, name: "Pay now")])
        let covered = try await fixture.target.act(fixture.lease, ActionBatch([.click(at: .ref("e1", observation: observation.id))]))
        #expect(covered.first?.effect == .refused)
        #expect(covered.first?.evidence?.contains("covered by a dialog") == true)
        let relabeled = try await fixture.target.act(fixture.lease, ActionBatch([.click(at: .ref("e3", observation: observation.id))]))
        #expect(relabeled.first?.evidence == "element e3's label changed since observation o_1")
        let gone = try await fixture.target.act(fixture.lease, ActionBatch([.press(at: .ref("e2", observation: observation.id))]))
        #expect(gone.first?.effect == .refused)
        #expect(gone.first?.escalation == .observe)
        #expect(await fixture.browser.methods("Input.").isEmpty)
    }

    @Test("A point is refused once the page has scrolled or navigated since its observation")
    func pointDrift() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        let point = ActionTarget.point(DisplayPoint(x: 500, y: 400), observation: observation.id)
        await fixture.browser.setScroll(0, 120)
        let scrolled = try await fixture.target.act(fixture.lease, ActionBatch([.click(at: point)]))
        #expect(scrolled.first?.evidence == "the page scrolled since observation o_1")
        await fixture.browser.setScroll(0, 0)
        _ = try await fixture.target.act(fixture.lease, ActionBatch([.openURL("https://app.example.com/next")]))
        let navigated = try await fixture.target.act(fixture.lease, ActionBatch([.click(at: point)]))
        #expect(navigated.first?.evidence == "the page changed since observation o_1")
        #expect(await fixture.browser.methods("Input.").isEmpty)
    }

    @Test("Navigation is checked against the network policy before it starts")
    func navigationPolicy() async throws {
        let fixture = try await Self.fixture(network: BrowserNetworkPolicy(blockedDomains: ["ads.example.com"]))
        for url in ["http://169.254.169.254/latest/meta-data", "file:///etc/passwd", "https://ads.example.com/"] {
            let outcome = try await fixture.target.act(fixture.lease, ActionBatch([.openURL(url)]))
            #expect(outcome.first?.effect == .refused, "\(url)")
            #expect(outcome.first?.evidence?.hasPrefix("network policy blocks") == true)
        }
        #expect(await fixture.browser.methods("Page.navigate").isEmpty)
        let opened = try await fixture.target.act(fixture.lease, ActionBatch([.openURL("https://app.example.com/next")]))
        #expect(opened.first?.effect == .confirmed)
        #expect(opened.first?.evidence == "navigation started; the page navigated to app.example.com")
    }

    @Test("A page that ends on a blocked URL is cleared")
    func finalURL() async throws {
        let fixture = try await Self.fixture(network: BrowserNetworkPolicy(blockedDomains: ["evil.example"]))
        await fixture.browser.setRedirect("https://app.example.com/go", to: "https://evil.example/landing")
        let outcome = try await fixture.target.act(fixture.lease, ActionBatch([.openURL("https://app.example.com/go")]))
        #expect(outcome.first?.effect == .partial)
        #expect(outcome.first?.evidence?.hasPrefix("the page went to https://evil.example/landing, which network policy blocks") == true)
        #expect(await fixture.browser.params(of: "Page.navigate").last?[wire: "url"]?.wireString == "about:blank")
    }

    @Test("A load that fails, such as one the proxy refused, is reported as a failed load, not a blocked page")
    func failedLoad() async throws {
        let fixture = try await Self.fixture()
        await fixture.browser.setRedirect("https://app.example.com/down", to: "chrome-error://chromewebdata/")
        let outcome = try await fixture.target.act(fixture.lease, ActionBatch([.openURL("https://app.example.com/down")]))
        #expect(outcome.first?.effect == .unverifiable)
        #expect(outcome.first?.evidence == "navigation started; the page failed to load")
        #expect(outcome.first?.escalation == .observe)
        #expect(await fixture.browser.params(of: "Page.navigate").count == 1)
    }

    @Test("Connections the network refused during an action are reported with it")
    func deniedConnections() async throws {
        let denial = BrowserNetworkDenial(host: "10.0.0.5", port: 80, reason: "10.0.0.5, a private address; private network access is off", at: Date())
        let fixture = try await Self.fixture(denials: [denial])
        let outcome = try await fixture.target.act(fixture.lease, ActionBatch([.wait(milliseconds: 1)]))
        #expect(outcome.first?.evidence == "waited 1 ms; network policy blocked 10.0.0.5 (10.0.0.5, a private address; private network access is off)")
    }

    @Test("set-value writes through the DOM and is confirmed by reading it back")
    func setValue() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        let outcome = try await fixture.target.act(fixture.lease, ActionBatch([.setValue(at: .ref("e2", observation: observation.id), value: "s3cret")]))
        #expect(outcome.first?.effect == .confirmed)
        #expect(outcome.first?.evidence == "value read back")
    }

    @Test("Typing inserts text and presses line breaks and tabs as keys")
    func typing() async throws {
        #expect(ManagedBrowserDisplayTarget.typingSegments("ab\ncd\te") == [
            .text("ab"), .key(KeyCombo(modifiers: [], key: "return")), .text("cd"), .key(KeyCombo(modifiers: [], key: "tab")), .text("e"),
        ])
        let fixture = try await Self.fixture()
        await fixture.browser.setMutatesOnInput()
        let observation = try await Self.observe(fixture)
        let outcome = try await fixture.target.act(fixture.lease, ActionBatch([.type(text: "hi\n", into: .ref("e2", observation: observation.id))]))
        #expect(outcome.first?.evidence == "typed 3 characters; the page changed")
        #expect(await fixture.browser.params(of: "Input.insertText").map { $0[wire: "text"]?.wireString } == ["hi"])
        #expect(await fixture.browser.params(of: "Input.dispatchKeyEvent").compactMap { $0[wire: "key"]?.wireString } == ["Enter", "Enter"])
    }

    @Test("Key chords carry modifiers; text goes only with unmodified presses; clipboard commands are never sent")
    func keys() throws {
        let selectAll = try #require(CDPInput.keyEvents(try KeyCombo(parsing: "cmd+a")))
        #expect(selectAll.down["commands"]?.wireArray?.compactMap(\.wireString) == ["selectAll"])
        #expect(selectAll.down["text"] == nil)
        #expect(selectAll.down["modifiers"]?.wireInt == 4)
        let paste = try #require(CDPInput.keyEvents(try KeyCombo(parsing: "cmd+v")))
        #expect(paste.down["commands"] == nil)
        let shifted = try #require(CDPInput.keyEvents(try KeyCombo(parsing: "shift+a")))
        #expect(shifted.down["text"]?.wireString == "A")
        #expect(shifted.down["code"]?.wireString == "KeyA")
        let enter = try #require(CDPInput.keyEvents(try KeyCombo(parsing: "enter")))
        #expect(enter.down["windowsVirtualKeyCode"]?.wireInt == 13)
        #expect(CDPInput.keyEvents(try KeyCombo(parsing: "nosuchkey")) == nil)
    }

    @Test("A script runs in a fresh world of its own, never the tree builder's, and returns its value")
    func script() async throws {
        let fixture = try await Self.fixture()
        _ = try await Self.observe(fixture)
        #expect(fixture.target.manifest.scripting == [.javascript])
        await fixture.browser.setScriptReply(#"{"ok":true,"json":"{\"title\":\"Fixture\",\"count\":3}"}"#)
        let source = "return { title: document.title, count: 3 };"
        let outcome = try #require(try await fixture.target.act(fixture.lease, ActionBatch([
            .script(language: .javascript, source: source, timeoutMilliseconds: 4_000),
        ])).first)
        #expect(outcome.effect == .unverifiable)
        #expect(outcome.evidence?.contains(#"returned: {"title":"Fixture","count":3}"#) == true)

        let worlds = await fixture.browser.params(of: "Page.createIsolatedWorld")
        let scriptWorld = try #require(worlds.last)
        #expect(scriptWorld[wire: "worldName"]?.wireString == "computer-use-script")
        let evaluations = await fixture.browser.params(of: "Runtime.evaluate")
        let call = try #require(evaluations.first { if case .boolean(true)? = $0[wire: "awaitPromise"] { true } else { false } })
        #expect(call[wire: "expression"]?.wireString?.contains(source) == true)
        #expect(call[wire: "timeout"]?.wireInt == 4_000)
        #expect(call[wire: "contextId"]?.wireInt != nil)
        #expect(call[wire: "contextId"]?.wireInt != evaluations.first?[wire: "contextId"]?.wireInt)

        _ = try await fixture.target.act(fixture.lease, ActionBatch([.script(language: .javascript, source: "return 1;", timeoutMilliseconds: 1_000)]))
        let scriptWorlds = await fixture.browser.params(of: "Page.createIsolatedWorld").filter { $0[wire: "worldName"]?.wireString == "computer-use-script" }
        #expect(scriptWorlds.count == 2, "every script starts from a clean world")
    }

    @Test("A script that throws or times out is partial, and a long result is cut")
    func scriptFailures() async throws {
        let fixture = try await Self.fixture()
        _ = try await Self.observe(fixture)
        let script = ComputerAction.script(language: .javascript, source: "x.y", timeoutMilliseconds: 1_000)
        await fixture.browser.setScriptReply(#"{"ok":false,"error":"ReferenceError: x is not defined"}"#)
        let thrown = try #require(try await fixture.target.act(fixture.lease, ActionBatch([script])).first)
        #expect(thrown.effect == .partial)
        #expect(thrown.evidence?.contains("threw: ReferenceError: x is not defined") == true)
        #expect(thrown.escalation == .observe)

        await fixture.browser.setScriptReply(#"{"ok":false,"timedOut":true}"#)
        let slow = try #require(try await fixture.target.act(fixture.lease, ActionBatch([script])).first)
        #expect(slow.effect == .partial)
        #expect(slow.evidence?.contains("timed out after 1000 ms") == true)

        await fixture.browser.setScriptReply("terminated")
        let spun = try #require(try await fixture.target.act(fixture.lease, ActionBatch([script])).first)
        #expect(spun.effect == .partial)
        #expect(spun.evidence?.contains("stopped after 1000 ms") == true)

        let long = String(repeating: "a", count: 5_000)
        await fixture.browser.setScriptReply(#"{"ok":true,"json":"\""# + long + #"\""}"#)
        let cut = try #require(try await fixture.target.act(fixture.lease, ActionBatch([script])).first)
        #expect((cut.evidence?.count ?? 0) < 2_200)
        #expect(cut.evidence?.contains("…") == true)
    }

    @Test("The user's browser is a shared host target with their sign-ins, and a tab of the agent's own")
    func userBrowser() async throws {
        let target = ManagedBrowserDisplayTarget.userBrowser(endpoint: .webSocket(URL(string: "ws://127.0.0.1:9222/devtools/browser/x")!))
        #expect(target.manifest.id == "user-browser")
        #expect(target.manifest.isolation == .host)
        #expect(target.manifest.humanPresence == .shared)
        #expect(target.manifest.scripting == [.javascript])

        let fixture = try await Self.fixture(profile: .user)
        #expect(await fixture.browser.methods("Target.createBrowserContext").isEmpty, "the user's own profile, not a throwaway one")
        #expect(await fixture.browser.methods("Browser.setDownloadBehavior").isEmpty, "the user's download settings are left alone")
        let created = try #require(await fixture.browser.params(of: "Target.createTarget").first)
        #expect(created[wire: "browserContextId"] == nil)
        _ = try await Self.observe(fixture)
        await fixture.target.release(fixture.lease, reason: .completed)
        #expect(await fixture.browser.methods("Target.disposeBrowserContext").isEmpty)
        #expect(await fixture.browser.params(of: "Target.closeTarget").compactMap { $0[wire: "targetId"]?.wireString } == ["page-1"])
    }

    @Test("In the user's browser only windows the agent's tab opened are folded in; the user's own tabs are left alone")
    func userBrowserPopups() async throws {
        let fixture = try await Self.fixture(profile: .user)
        func page(_ id: String, _ url: String, opener: String?) -> CDPEvent {
            var info: [String: JSON] = [
                "type": .string("page"), "browserContextId": .string("default-ctx"), "targetId": .string(id), "url": .string(url),
            ]
            if let opener { info["openerId"] = .string(opener) }
            return CDPEvent(method: "Target.targetInfoChanged", params: .object(["targetInfo": .object(info)]), sessionID: nil)
        }
        await fixture.browser.emit(page("user-tab", "https://mail.example.com/", opener: nil))
        await fixture.browser.emit(page("popup", "https://app.example.com/popup", opener: "page-1"))
        for _ in 0..<50 where await fixture.browser.params(of: "Target.closeTarget").isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await fixture.browser.params(of: "Target.closeTarget").compactMap { $0[wire: "targetId"]?.wireString } == ["popup"])
    }

    @Test("A download the agent's tab starts in the user's browser is cancelled and reported")
    func userBrowserDownloads() async throws {
        let fixture = try await Self.fixture(profile: .user)
        await fixture.browser.emit(CDPEvent(
            method: "Page.downloadWillBegin",
            params: .object(["guid": .string("dl-1"), "url": .string("https://app.example.com/setup.pkg"), "suggestedFilename": .string("setup.pkg")]),
            sessionID: "s1"
        ))
        for _ in 0..<50 where await fixture.browser.params(of: "Browser.cancelDownload").isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancel = try #require(await fixture.browser.params(of: "Browser.cancelDownload").first)
        #expect(cancel[wire: "guid"]?.wireString == "dl-1")
        #expect(cancel[wire: "browserContextId"]?.wireString == "default-ctx")
        let observation = try await Self.observe(fixture, modes: [.accessibility])
        #expect(observation.tree?.text.contains("download of setup.pkg") == true)
    }

    @Test("The user's browser is found through the DevToolsActivePort file Chrome writes when debugging is allowed")
    func devToolsActivePort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = UserBrowserEndpoint.devToolsActivePort(directory: directory)
        await #expect(throws: DisplayTargetError.self) { try endpoint.resolve() }
        do {
            _ = try endpoint.resolve()
        } catch {
            #expect(String(describing: error).contains("chrome://inspect/#remote-debugging"))
        }
        try Data("9222\n/devtools/browser/abc-123\n".utf8).write(to: directory.appendingPathComponent("DevToolsActivePort"))
        #expect(try endpoint.resolve() == URL(string: "ws://127.0.0.1:9222/devtools/browser/abc-123"))
        #expect(try UserBrowserEndpoint.webSocket(URL(string: "ws://h:1/x")!).resolve() == URL(string: "ws://h:1/x"))
        #expect(UserBrowserEndpoint.chrome == .devToolsActivePort(directory: UserBrowserEndpoint.chromeUserDataDirectory))
    }

    @Test("Apps and menus don't exist in a managed browser")
    func unsupported() async throws {
        let fixture = try await Self.fixture()
        let launch = try await fixture.target.act(fixture.lease, ActionBatch([.launch(app: "com.apple.Terminal")]))
        #expect(launch.first?.effect == .refused)
        let menu = try await fixture.target.act(fixture.lease, ActionBatch([.menu(path: ["File", "Quit"])]))
        #expect(menu.first?.effect == .refused)
    }

    @Test("The isolated world is recreated when a navigation destroyed it")
    func lostContext() async throws {
        let fixture = try await Self.fixture()
        _ = try await Self.observe(fixture)
        await fixture.browser.loseContext()
        let observation = try await Self.observe(fixture)
        #expect(observation.tree != nil)
        #expect(await fixture.browser.methods("Page.createIsolatedWorld").count == 2)
        #expect(await fixture.browser.params(of: "Page.createIsolatedWorld").first?[wire: "worldName"]?.wireString == "computer-use")
    }

    @Test("Dialogs are dismissed and reported in the next observation")
    func dialogs() async throws {
        let fixture = try await Self.fixture()
        await fixture.browser.emit(CDPEvent(
            method: "Page.javascriptDialogOpening",
            params: .object(["type": .string("confirm"), "message": .string("Delete everything?")]),
            sessionID: "s1"
        ))
        for _ in 0..<50 where await fixture.browser.params(of: "Page.handleJavaScriptDialog").isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.browser.params(of: "Page.handleJavaScriptDialog").first?[wire: "accept"].flatMap { if case .boolean(let flag) = $0 { flag } else { nil } } == false)
        let observation = try await Self.observe(fixture, modes: [.accessibility])
        #expect(observation.tree?.text.hasSuffix("note: The page showed a confirm dialog, which was dismissed: \"Delete everything?\"") == true)
    }

    @Test("Popups are closed and their page opened in the one tab, unless policy blocks it")
    func popups() async throws {
        let fixture = try await Self.fixture(network: BrowserNetworkPolicy(blockedDomains: ["evil.example"]))
        func popup(_ id: String, _ url: String) -> CDPEvent {
            CDPEvent(method: "Target.targetInfoChanged", params: .object(["targetInfo": .object([
                "type": .string("page"), "browserContextId": .string("ctx"), "targetId": .string(id), "url": .string(url),
            ])]), sessionID: nil)
        }
        await fixture.browser.emit(popup("page-2", "https://app.example.com/popup"))
        await fixture.browser.emit(popup("page-3", "https://evil.example/"))
        for _ in 0..<50 where await fixture.browser.params(of: "Target.closeTarget").count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.browser.params(of: "Target.closeTarget").compactMap { $0[wire: "targetId"]?.wireString } == ["page-2", "page-3"])
        #expect(await fixture.browser.params(of: "Page.navigate").compactMap { $0[wire: "url"]?.wireString } == ["https://app.example.com/popup"])
    }
}

@Suite("Computer use: actions on a target with no app")
struct ComputerUsePageTargetClassificationTests {
    private let classifier = ComputerUseActionClassifier()

    @Test("Untargeted input on a managed browser is granted by the focused page's domain")
    func focusedPage() throws {
        let grants = ComputerUseGrantSet([.domain("example.com", tier: .full)])
        func classify(_ url: String?) -> ComputerUseClassification {
            classifier.classify(.key(combo: try! KeyCombo(parsing: "tab")), context: ComputerUseClassificationContext(
                grants: grants, observation: { _ in nil }, focusedApp: nil, focusedURL: url
            ))
        }
        #expect(classify("https://app.example.com/form").actionClass == .interact)
        #expect(classify("https://app.example.com/form").domain == "app.example.com")
        let other = classify("https://other.org/")
        #expect(other.actionClass == .outOfGrant(reason: "domain other.org is not granted"))
        #expect(other.missingGrant == .domain("other.org", tier: .full))
        #expect(classify(nil).actionClass == .unresolvable(reason: "the target app is unknown; observe first"))
    }
}
