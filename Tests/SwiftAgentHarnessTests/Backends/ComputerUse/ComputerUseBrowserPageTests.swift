import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use: browser pages and browser controls")
struct ComputerUseBrowserPageTests {
    private let classifier = ComputerUseActionClassifier()
    private static let safari = ComputerUseFixtures.safari
    private static let grants: [ComputerUseGrant] = [.app(bundleID: "com.apple.Safari", tier: .view), .domain("apple.com", tier: .click)]
    private static let pageBounds = DisplayRect(x: 0, y: 80, width: 1440, height: 820)

    /// A browser window: an address field in the toolbar with no page URL, and a link and a button on the page.
    private static func browser(id: ObservationID, page: String?, pageBounds: DisplayRect? = Self.pageBounds, app: AppIdentity? = safari) -> DisplayObservation {
        DisplayObservation(
            id: id,
            at: ComputerUseFixtures.epoch,
            target: ObservationTarget(app: app, pid: 4242, windowID: "w1", url: page, pageBounds: pageBounds, bounds: ComputerUseFixtures.geometry.capturedRect),
            tree: ObservationTree(
                text: "window obs=\(id)\n[e1] textfield \"smart search field\"\n[e2] link \"Store\"\n[e3] button \"Shop\"",
                elements: [
                    "e1": ElementRef(id: "e1", role: "AXTextField", label: "smart search field", frame: DisplayRect(x: 300, y: 20, width: 600, height: 30), app: app),
                    "e2": ElementRef(id: "e2", role: "AXLink", label: "Store", frame: DisplayRect(x: 100, y: 200, width: 60, height: 20), app: app, url: page),
                    "e3": ElementRef(id: "e3", role: "AXButton", label: "Shop", frame: DisplayRect(x: 100, y: 300, width: 60, height: 20), app: app, url: page),
                ],
                capturedAt: ComputerUseFixtures.epoch
            )
        )
    }

    private static let defaults = ComputerUseSpecialistDefaults(
        target: "fake-host",
        budgets: ComputerUseBudgetPolicy(defaultSteps: 60, ceilingSteps: 200, maxDuration: .seconds(1_800))
    )

    private static func task(_ arguments: [String: String]) throws -> ComputerUseTask {
        var raw = ["goal": "Open apple.com", "success_criteria": "The page is open"]
        raw.merge(arguments) { _, new in new }
        return try ComputerUseTask(arguments: .object(raw.mapValues(JSON.string)), defaults: defaults)
    }

    private func classify(_ action: ComputerAction, _ observation: DisplayObservation, grants: [ComputerUseGrant] = Self.grants) -> ComputerUseClassification {
        classifier.classify(
            action,
            context: ComputerUseClassificationContext(
                grants: ComputerUseGrantSet(grants),
                observation: { $0 == observation.id ? observation : nil },
                focusedApp: observation.target.app
            )
        )
    }

    private func reason(_ result: ComputerUseClassification) -> String? {
        if case .outOfGrant(let reason) = result.actionClass { return reason }
        return nil
    }

    @Test("A click on an element of a granted page is allowed through the domain grant")
    func grantedPage() {
        let result = classify(.click(at: .ref("e2", observation: "o_1")), Self.browser(id: "o_1", page: "https://www.apple.com/"))
        #expect(result.actionClass == .interact)
        #expect(result.domain == "www.apple.com")
    }

    @Test("The same click on a page whose domain isn't granted names the domain, not a higher app tier")
    func ungrantedPage() throws {
        let result = classify(.click(at: .ref("e2", observation: "o_1")), Self.browser(id: "o_1", page: "https://www.twitch.tv/somebody"))
        let reason = try #require(reason(result))
        #expect(reason == "domain www.twitch.tv is not granted")
        #expect(result.missingGrant == .domain("www.twitch.tv", tier: .click))
    }

    @Test("The browser's own controls follow its app grant up to click; typing there is refused with open-url as the way")
    func browserControls() throws {
        let observation = Self.browser(id: "o_1", page: "https://www.apple.com/")
        let safari: [ComputerUseGrant] = Self.grants + [.app(bundleID: "com.apple.Safari", tier: .full)]
        let click = classify(.click(at: .ref("e1", observation: "o_1")), observation, grants: safari)
        #expect(click.actionClass == .interact, "Safari's grant is capped at click, which covers its controls")
        let typing = classify(.type(text: "apple.com", into: .ref("e1", observation: "o_1")), observation, grants: safari)
        let refusal = try #require(reason(typing))
        #expect(refusal == "com.apple.Safari's own controls go up to click; type needs full; act on the page or navigate with open-url")
        #expect(typing.missingGrant == nil)
        let viewOnly = classify(.click(at: .ref("e1", observation: "o_1")), observation)
        #expect(try #require(reason(viewOnly)).contains("granted at view"))
    }

    @Test("A point inside the page takes the page's domain; a point outside it lands on the browser's controls")
    func points() throws {
        let observation = Self.browser(id: "o_1", page: "https://www.apple.com/")
        let inPage = classify(.click(at: .point(DisplayPoint(x: 700, y: 500), observation: "o_1")), observation)
        #expect(inPage.actionClass == .interact)
        #expect(inPage.domain == "www.apple.com")

        let toolbar = classify(.click(at: .point(DisplayPoint(x: 600, y: 30), observation: "o_1")), observation)
        #expect(toolbar.domain == nil)
        #expect(try #require(reason(toolbar)).contains("com.apple.Safari is granted at view"))

        let unknownPage = classify(.click(at: .point(DisplayPoint(x: 700, y: 500), observation: "o_2")), Self.browser(id: "o_2", page: "https://www.apple.com/", pageBounds: nil))
        #expect(try #require(reason(unknownPage)).contains("com.apple.Safari is granted at view"))
    }

    @Test("An element under the web area is page content even without a URL of its own, and takes the page's domain")
    func webContentWithoutURL() throws {
        var observation = Self.browser(id: "o_1", page: "https://www.twitch.tv/somebody")
        observation.tree?.elements["e4"] = ElementRef(id: "e4", role: "AXButton", label: "Follow", app: Self.safari, isWebContent: true)
        let safari: [ComputerUseGrant] = Self.grants + [.app(bundleID: "com.apple.Safari", tier: .click)]
        let result = classify(.click(at: .ref("e4", observation: "o_1")), observation, grants: safari)
        #expect(reason(result) == "domain www.twitch.tv is not granted", "the app grant doesn't reach into the page")
    }

    @Test("Page content on a page whose address the browser doesn't report can't be classified, so it isn't allowed")
    func webContentUnknownPage() {
        var observation = Self.browser(id: "o_1", page: nil)
        observation.tree?.elements["e4"] = ElementRef(id: "e4", role: "AXButton", label: "Follow", app: Self.safari, isWebContent: true)
        let safari: [ComputerUseGrant] = Self.grants + [.app(bundleID: "com.apple.Safari", tier: .click)]
        let result = classify(.click(at: .ref("e4", observation: "o_1")), observation, grants: safari)
        guard case .unresolvable(let why) = result.actionClass else {
            Issue.record("expected unresolvable, got \(result.actionClass)")
            return
        }
        #expect(why.contains("doesn't report"))
    }

    @Test("Targets that are only a page, with no app, still take the target's URL for every element and point")
    func pageOnlyTargets() {
        let observation = Self.browser(id: "o_1", page: "https://www.apple.com/", pageBounds: nil, app: nil)
        #expect(classify(.click(at: .ref("e1", observation: "o_1")), observation, grants: [.domain("apple.com", tier: .click)]).actionClass == .interact)
        #expect(classify(.click(at: .point(DisplayPoint(x: 600, y: 30), observation: "o_1")), observation, grants: [.domain("apple.com", tier: .click)]).actionClass == .interact)
    }

    @Test("Asking for a browser above click, or a browser with no domains, comes back as a grant note")
    func grantNotes() throws {
        let reviewer = ComputerUseGrantReviewer()
        func notes(_ arguments: [String: String]) throws -> [String] {
            try Self.task(arguments).grantNotes(reviewedBy: reviewer)
        }
        #expect(try notes(["apps": "com.apple.Safari:full", "domains": "apple.com:click"]) == [
            "com.apple.Safari is a browser: its own controls stay at click whatever the grant; grant domains for its pages instead",
        ])
        #expect(try notes(["apps": "com.apple.Safari:click", "domains": "apple.com:click"]).isEmpty)
        #expect(try notes(["apps": "com.apple.Safari:view"]) == [
            "com.apple.Safari is a browser and no domains are granted, so its pages can only be viewed",
        ])
        #expect(try notes(["apps": "com.apple.Terminal:full"]) == [
            "com.apple.Terminal stays at click whatever the grant: Terminal or IDE: typing here is shell access.",
        ])
        #expect(try notes(["apps": "com.apple.Safari:view,com.apple.TextEdit:full", "domains": "apple.com:click"]).isEmpty)
    }

    @Test("The result carries grant notes, and leaves the key out when there are none")
    func resultCarriesNotes() throws {
        let task = try Self.task(["apps": "com.apple.Safari:click"])
        let notes = task.grantNotes(reviewedBy: ComputerUseGrantReviewer())
        var result = ComputerUseResult.notStarted(.blocked, reason: "denied", task: task)
        #expect(!result.jsonString.contains("grantNotes"))
        result.grantNotes = notes
        #expect(result.jsonString.contains(#""grantNotes":["com.apple.Safari is a browser"#))
    }

    @Test("The grant card says a browser shows its pages on any domain")
    func browserWarning() throws {
        let review = ComputerUseGrantReviewer().review([.app(bundleID: "com.apple.Safari", tier: .view)])
        let warning = try #require(review.grantable.first?.warning)
        #expect(warning.contains("on any domain"))
    }
}

extension ComputerUseBrowserPageTests {
    @Test("Typing in a browser without citing an element asks for a page element")
    func uncitedTyping() throws {
        let result = classify(.type(text: "hello"), Self.browser(id: "o_1", page: "https://www.apple.com/"))
        #expect(try #require(reason(result)).hasPrefix("cite an element on the page; com.apple.Safari's own controls"))
    }
}
