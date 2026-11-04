import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use on a managed browser")
struct ManagedBrowserSessionTests {
    typealias FakeBrowser = ManagedBrowserDisplayTargetTests.FakeBrowser
    typealias Element = ManagedBrowserPageSnapshot.Element

    static let save = Element(id: "e1", role: "button", name: "Save draft", x: 100, y: 100, w: 80, h: 30, depth: 0)
    static let submit = Element(id: "e2", role: "button", name: "Submit order", x: 100, y: 200, w: 80, h: 30, depth: 0)

    private static func session(userPresent: Bool = false) async throws -> (FakeBrowser, ComputerUseSession) {
        let browser = FakeBrowser()
        await browser.script(url: "https://shop.example.com/cart", elements: [save, submit], live: [
            "e1": ManagedBrowserDisplayTargetTests.live(save), "e2": ManagedBrowserDisplayTargetTests.live(submit),
        ])
        let target = ManagedBrowserDisplayTarget(configuration: ManagedBrowserConfiguration(settleDelay: .zero), isolation: .container) {
            ManagedBrowserSession(connection: browser)
        }
        let registry = try DisplayTargetRegistry(targets: [target])
        let grant = try await registry.lease(
            LeaseRequest(
                target: target.manifest.id,
                agentID: "specialist",
                grants: [.domain("example.com", tier: .full)],
                budgets: ComputerUseBudgets(steps: 20, maxDuration: .seconds(600)),
                initiator: .trigger,
                userPresent: userPresent
            ),
            approve: { request in request.review.grantable.map(\.grant) }
        )
        let session = ComputerUseSession(
            target: grant.target,
            lease: grant.lease,
            configuration: ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["Save the cart as a draft."])),
            now: { ComputerUseFixtures.epoch }
        )
        return (browser, session)
    }

    private static func ref(named name: String, in observation: DisplayObservation?) throws -> (ref: String, observation: ObservationID) {
        let observation = try #require(observation)
        let element = try #require(observation.tree?.elements.values.first { $0.label == name })
        return (element.id, observation.id)
    }

    @Test("A run nobody started at the keyboard may lease the isolated browser, unlike the host desktop")
    func headlessLease() async throws {
        let (_, session) = try await Self.session()
        let observed = await session.perform([.observe(ObserveRequest(modes: [.accessibility, .pixels], scope: .display(nil)))])
        #expect(observed.outcomes.first?.effect == .confirmed)
        #expect(observed.observations.first?.target.url == "https://shop.example.com/cart")
    }

    @Test("Actions are granted by the page's domain; untargeted keys go by the focused page")
    func domainGrants() async throws {
        let (browser, session) = try await Self.session()
        let observed = await session.perform([.observe(ObserveRequest(modes: [.accessibility], scope: .display(nil)))])
        let save = try Self.ref(named: "Save draft", in: observed.observations.first)
        let clicked = await session.perform([.click(at: .ref(save.ref, observation: save.observation))])
        #expect(clicked.records.first?.actionClass == "interact")
        #expect(clicked.outcomes.first?.effect != .refused, "\(clicked.outcomes)")
        let tabbed = await session.perform([.key(combo: try KeyCombo(parsing: "tab"))])
        #expect(tabbed.outcomes.first?.effect != .refused, "\(tabbed.outcomes)")

        await browser.script(url: "https://elsewhere.org/")
        let moved = await session.perform([.observe(ObserveRequest(modes: [.accessibility, .pixels], scope: .display(nil)))])
        let scoped = try #require(moved.observations.first)
        #expect(scoped.tree?.elements.isEmpty == true, "a page on a domain that isn't granted is reported by URL only")
        #expect(scoped.tree?.text.contains("only its URL is reported") == true)
        #expect(scoped.image == nil)
        #expect(scoped.target.url == "https://elsewhere.org/")
        let refused = await session.perform([.openURL("https://elsewhere.org/next")])
        #expect(refused.outcomes.first?.effect == .refused)
        #expect(refused.outcomes.first?.evidence?.hasPrefix("domain elsewhere.org is not granted") == true)
        #expect(await session.missingGrants == [.domain("elsewhere.org", tier: .click)])
    }

    @Test("A consequential action in a run with nobody present is denied, not performed")
    func headlessConsequential() async throws {
        let (browser, session) = try await Self.session()
        let observed = await session.perform([.observe(ObserveRequest(modes: [.accessibility], scope: .display(nil)))])
        let submit = try Self.ref(named: "Submit order", in: observed.observations.first)
        let result = await session.perform([.click(at: .ref(submit.ref, observation: submit.observation))])
        #expect(result.outcomes.first?.effect == .refused)
        #expect(result.records.first?.decision == .headlessDenied)
        #expect(await browser.methods("Input.").isEmpty)
    }

    @Test("Tasks with only domains go to the web target when one is set")
    func defaultTarget() throws {
        let defaults = ComputerUseSpecialistDefaults(target: "host", webTarget: "managed-browser")
        func task(_ extra: [String: String]) throws -> ComputerUseTask {
            var raw = ["goal": "Check the cart", "success_criteria": "The cart is visible"]
            raw.merge(extra) { _, new in new }
            return try ComputerUseTask(arguments: .object(raw.mapValues(JSON.string)), defaults: defaults)
        }
        #expect(try task(["domains": "shop.example.com:click"]).target == "managed-browser")
        #expect(try task(["domains": "shop.example.com:click", "apps": "com.apple.Safari:view"]).target == "host")
        #expect(try task(["domains": "shop.example.com:click", "target": "host"]).target == "host")
        #expect(try task(["apps": "com.apple.TextEdit:full"]).target == "host")
        #expect(ComputerUseSpecialistDefaults(target: "host").target(for: [.domain("a.com", tier: .click)]) == "host")
    }

    @Test("The delegate tool says where web-only tasks run when a web target is set")
    func delegateDescription() async throws {
        let manifests = [ManagedBrowserDisplayTarget(isolation: .container) { throw CDPError.closed }.manifest]
        let withWeb = ComputerUseDelegateToolProvider(targets: manifests, defaults: ComputerUseSpecialistDefaults(target: "host", webTarget: "managed-browser"))
        let parameters = try #require(await withWeb.availableTools().first?.parameters)
        let domains = try #require(parameters.first { $0.name == "domains" }?.description)
        #expect(domains.contains("runs in managed-browser, a separate browser with none of the user's data or sign-ins"))
        let target = try #require(parameters.first { $0.name == "target" }?.description)
        #expect(target == "Display target id. Default host, or managed-browser for a task with domains and no apps. Available: managed-browser (Managed browser, container).")

        let hostOnly = ComputerUseDelegateToolProvider(targets: [], defaults: ComputerUseSpecialistDefaults(target: "host"))
        let hostDomains = try #require(await hostOnly.availableTools().first?.parameters.first { $0.name == "domains" }?.description)
        #expect(hostDomains.hasPrefix("Web domains to grant, comma-separated as domain:tier. A web task needs a domain here and a browser in apps"))
    }
}
