import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use action classification")
struct ComputerUseActionClassifierTests {
    private let classifier = ComputerUseActionClassifier()

    private func classify(
        _ action: ComputerAction,
        grants: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .full)],
        observations: [DisplayObservation] = [ComputerUseFixtures.observation(id: "o_1")],
        focusedApp: AppIdentity? = ComputerUseFixtures.textEdit,
        safetySignals: [String] = []
    ) -> ComputerUseClassification {
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        return classifier.classify(
            action,
            context: ComputerUseClassificationContext(
                grants: ComputerUseGrantSet(grants),
                observation: { byID[$0] },
                focusedApp: focusedApp,
                safetySignals: safetySignals
            )
        )
    }

    @Test("Observe, zoom, and waits are observe-class without a grant check")
    func observeClass() {
        #expect(classify(.observe(ObserveRequest(modes: [.pixels], scope: .display(nil))), grants: []).actionClass == .observe)
        #expect(classify(.zoom(region: DisplayRect(x: 0, y: 0, width: 10, height: 10), observation: "o_1")).actionClass == .observe)
        #expect(classify(.wait(milliseconds: 100)).actionClass == .observe)
    }

    @Test("Scroll, move, and launch of a granted app are navigate-class")
    func navigateClass() {
        #expect(classify(.scroll(at: .ref("e5", observation: "o_1"), dx: 0, dy: -3, unit: .line)).actionClass == .navigate)
        #expect(classify(.move(to: .ref("e2", observation: "o_1"))).actionClass == .navigate)
        #expect(classify(.launch(app: "com.apple.TextEdit")).actionClass == .navigate)
    }

    @Test("Clicking, pressing, and typing in a granted app at full tier are interact-class")
    func interactClass() throws {
        let click = classify(.click(at: .ref("e2", observation: "o_1")))
        #expect(click.actionClass == .interact)
        #expect(click.app?.bundleID == "com.apple.TextEdit")
        #expect(click.elementRole == "AXButton")
        #expect(classify(.type(text: "hello", into: .ref("e5", observation: "o_1"))).actionClass == .interact)
        #expect(classify(.key(combo: try KeyCombo(parsing: "cmd+b"))).actionClass == .interact)
    }

    @Test("Actions on a non-granted app are out of grant")
    func notGranted() {
        let result = classify(.click(at: .ref("e2", observation: "o_1")), grants: [.app(bundleID: "com.apple.Notes", tier: .full)])
        guard case .outOfGrant = result.actionClass else {
            Issue.record("expected out of grant, got \(result.actionClass)")
            return
        }
        guard case .outOfGrant = classify(.launch(app: "com.apple.Notes"), grants: []).actionClass else {
            Issue.record("launching a non-granted app must be out of grant")
            return
        }
    }

    @Test("Launching a browser is refused with a pointer to open-url, since browsers stay at view")
    func browserLaunch() {
        let result = classify(.launch(app: "com.apple.Safari"), grants: [.app(bundleID: "com.apple.Safari", tier: .full)])
        guard case .outOfGrant(let reason) = result.actionClass else {
            Issue.record("expected out of grant, got \(result.actionClass)")
            return
        }
        #expect(reason.contains("open-url"), "\(reason)")
    }

    @Test("Tier violations are out of grant: view allows no pointer actions, click allows no typing")
    func tierViolations() throws {
        let view: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .view)]
        let click: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .click)]
        #expect(classify(.click(at: .ref("e2", observation: "o_1")), grants: view).actionClass.isOutOfGrant)
        #expect(classify(.click(at: .ref("e2", observation: "o_1")), grants: click).actionClass == .interact)
        #expect(classify(.type(text: "rm -rf ~", into: .ref("e5", observation: "o_1")), grants: click).actionClass.isOutOfGrant)
        #expect(classify(.key(combo: try KeyCombo(parsing: "cmd+v")), grants: click).actionClass.isOutOfGrant)
    }

    @Test("Terminals stay click-only even when a full grant slipped through")
    func terminalCapAtActionTime() {
        let observation = ComputerUseFixtures.observation(id: "o_t", app: ComputerUseFixtures.terminal)
        let result = classify(
            .type(text: "ls", into: .ref("e5", observation: "o_t")),
            grants: [.app(bundleID: "com.apple.Terminal", tier: .full)],
            observations: [observation],
            focusedApp: ComputerUseFixtures.terminal
        )
        #expect(result.actionClass.isOutOfGrant)
    }

    @Test("Blocked categories are out of grant at action time even when the bundle id was granted")
    func blockedCategoryAtActionTime() {
        let bank = AppIdentity(bundleID: "com.example.bank", category: "public.app-category.finance")
        let result = classify(
            .click(at: .ref("e2", observation: "o_b")),
            grants: [.app(bundleID: "com.example.bank", tier: .full)],
            observations: [ComputerUseFixtures.observation(id: "o_b", app: bank)],
            focusedApp: bank
        )
        #expect(result.actionClass.isOutOfGrant)
    }

    @Test("Browser pages need a domain grant; the browser app grant alone allows only viewing")
    func browserDomains() {
        let page = ComputerUseFixtures.observation(id: "o_w", app: ComputerUseFixtures.safari, url: "https://docs.example.com/a")
        let appOnly: [ComputerUseGrant] = [.app(bundleID: "com.apple.Safari", tier: .view)]
        #expect(classify(.click(at: .ref("e2", observation: "o_w")), grants: appOnly, observations: [page]).actionClass.isOutOfGrant)
        let withDomain = appOnly + [.domain("example.com", tier: .full)]
        let result = classify(.click(at: .ref("e2", observation: "o_w")), grants: withDomain, observations: [page])
        #expect(result.actionClass == .interact)
        #expect(result.domain == "docs.example.com")
    }

    @Test("open-url requires http(s) and a granted domain")
    func openURL() {
        let grants: [ComputerUseGrant] = [.domain("example.com", tier: .click)]
        #expect(classify(.openURL("https://example.com/path"), grants: grants).actionClass == .navigate)
        #expect(classify(.openURL("https://other.com/"), grants: grants).actionClass.isOutOfGrant)
        #expect(classify(.openURL("file:///etc/passwd"), grants: grants).actionClass.isOutOfGrant)
        #expect(classify(.openURL("tel:5551234"), grants: grants).actionClass.isOutOfGrant)
        #expect(classify(.openURL("x-apple.systempreferences:com.apple.preference.security"), grants: grants).actionClass.isOutOfGrant)
    }

    @Test("The stop key is never synthesized, in any spelling")
    func stopKey() throws {
        #expect(classify(.key(combo: try KeyCombo(parsing: "Esc"))).actionClass.isOutOfGrant)
        #expect(classify(.hold(combo: try KeyCombo(parsing: "escape"), milliseconds: 100)).actionClass.isOutOfGrant)
        #expect(classify(.type(text: "a\u{1b}b", into: .ref("e5", observation: "o_1"))).actionClass.isOutOfGrant)
    }

    @Test("Global shortcuts need the system-keys flag")
    func systemKeys() throws {
        let combo = try KeyCombo(parsing: "cmd+tab")
        #expect(classify(.key(combo: combo)).actionClass.isOutOfGrant)
        let flagged: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .full, flags: [.systemKeys])]
        #expect(classify(.key(combo: combo), grants: flagged).actionClass == .interact)
    }

    @Test("Pasting needs the clipboard-write flag")
    func pasteNeedsClipboard() {
        let paste = ComputerAction.type(text: "hi", into: .ref("e5", observation: "o_1"), mode: .paste)
        #expect(classify(paste).actionClass.isOutOfGrant)
        let flagged: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .full, flags: [.clipboardWrite])]
        #expect(classify(paste, grants: flagged).actionClass == .interact)
    }

    @Test("Secure and payment fields, consequential labels, system settings, and vendor signals are consequential")
    func consequential() throws {
        #expect(classify(.type(text: "hunter2", into: .ref("e7", observation: "o_1"))).actionClass.isConsequential)
        #expect(classify(.setValue(at: .ref("e9", observation: "o_1"), value: "4111")).actionClass.isConsequential)
        #expect(classify(.press(at: .ref("e8", observation: "o_1"))).actionClass.isConsequential)
        #expect(classify(.key(combo: try KeyCombo(parsing: "shift+cmd+delete"))).actionClass.isConsequential)
        #expect(classify(.click(at: .ref("e2", observation: "o_1")), safetySignals: ["malicious-instructions"]).actionClass.isConsequential)

        let settings = ComputerUseFixtures.observation(id: "o_s", app: ComputerUseFixtures.systemSettings)
        let result = classify(
            .click(at: .ref("e2", observation: "o_s")),
            grants: [.app(bundleID: "com.apple.systempreferences", tier: .full)],
            observations: [settings],
            focusedApp: ComputerUseFixtures.systemSettings
        )
        #expect(result.actionClass.isConsequential)
    }

    @Test("A label cannot lower a class: 'Bold' stays interact, never below")
    func labelsOnlyEscalate() {
        #expect(classify(.press(at: .ref("e2", observation: "o_1"))).actionClass == .interact)
    }

    @Test("Unknown observations, unknown refs, and points outside the observation are unresolvable")
    func unresolvable() {
        #expect(classify(.click(at: .ref("e2", observation: "o_gone"))).actionClass.isUnresolvable)
        #expect(classify(.click(at: .ref("e404", observation: "o_1"))).actionClass.isUnresolvable)
        #expect(classify(.click(at: .point(DisplayPoint(x: 5000, y: 5000), observation: "o_1"))).actionClass.isUnresolvable)
        #expect(classify(.zoom(region: DisplayRect(x: 0, y: 0, width: 1, height: 1), observation: "o_gone")).actionClass.isUnresolvable)
        #expect(classify(.type(text: "x"), focusedApp: nil).actionClass.isUnresolvable)
    }

    @Test("Harness-derived identifiers describe the action without any on-screen text")
    func proposedActionHasNoScreenText() {
        let result = classify(.press(at: .ref("e8", observation: "o_1")))
        let proposed = result.proposedAction
        #expect(proposed.kind == "press")
        #expect(proposed.app == "com.apple.TextEdit")
        #expect(proposed.elementRole == "AXButton")
        #expect(!String(describing: proposed).contains("Delete account"))
    }
}

extension ComputerUseActionClass {
    var isOutOfGrant: Bool { if case .outOfGrant = self { return true } else { return false } }
    var isConsequential: Bool { if case .consequential = self { return true } else { return false } }
    var isUnresolvable: Bool { if case .unresolvable = self { return true } else { return false } }
}
