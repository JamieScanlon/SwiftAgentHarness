import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use: script classification")
struct ComputerUseScriptClassificationTests {
    private let classifier = ComputerUseActionClassifier()
    private let script = ComputerAction.script(language: .javascript, source: "return 1;", timeoutMilliseconds: 1_000)

    private func classify(tier: ComputerUseGrantTier, sharedTarget: Bool = false, url: String = "https://app.example.com/") -> ComputerUseClassification {
        classifier.classify(script, context: ComputerUseClassificationContext(
            grants: ComputerUseGrantSet([.domain("example.com", tier: tier)]),
            observation: { _ in nil },
            focusedApp: nil,
            focusedURL: url,
            sharedTarget: sharedTarget
        ))
    }

    @Test("A script runs in the focused page at full tier, gated as one interact action")
    func interact() {
        #expect(classify(tier: .full).actionClass == .interact)
        #expect(classify(tier: .full).domain == "app.example.com")
        #expect(classify(tier: .click).actionClass == .outOfGrant(reason: "app.example.com is granted at click; script needs full"))
        #expect(classify(tier: .full, url: "https://other.org/").actionClass == .outOfGrant(reason: "domain other.org is not granted"))
    }

    @Test("A script on a target someone uses is consequential, so the user reviews it")
    func shared() {
        let classification = classify(tier: .full, sharedTarget: true)
        #expect(classification.actionClass.isConsequential)
    }
}

@Suite("Computer use action classification")
struct ComputerUseActionClassifierTests {
    private let classifier = ComputerUseActionClassifier()

    private func classify(
        _ action: ComputerAction,
        grants: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .full)],
        observations: [DisplayObservation] = [ComputerUseFixtures.observation(id: "o_1")],
        focusedApp: AppIdentity? = ComputerUseFixtures.textEdit,
        safetySignals: [ComputerUseSafetySignal] = []
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

    @Test("A browser granted at click can be launched; at view it can't")
    func browserLaunch() {
        #expect(classify(.launch(app: "com.apple.Safari"), grants: [.app(bundleID: "com.apple.Safari", tier: .full)]).actionClass == .navigate)
        #expect(classify(.launch(app: "com.apple.Safari"), grants: [.app(bundleID: "com.apple.Safari", tier: .view)]).actionClass.isOutOfGrant)
    }

    @Test("On a desktop target, open-url needs a browser granted at click to open the page in")
    func openURLNeedsBrowser() {
        let page = ComputerAction.openURL("https://example.com/")
        let domain: ComputerUseGrant = .domain("example.com", tier: .click)
        #expect(classify(page, grants: [domain, .app(bundleID: "com.apple.TextEdit", tier: .full)]).actionClass.isOutOfGrant)
        #expect(classify(page, grants: [domain, .app(bundleID: "com.apple.Safari", tier: .view)]).actionClass.isOutOfGrant)
        #expect(classify(page, grants: [domain, .app(bundleID: "com.apple.Safari", tier: .click)]).actionClass == .navigate)
        #expect(classify(page, grants: [domain]).actionClass == .navigate, "a managed browser grants domains only")
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

    @Test("The stop key is never synthesized, in any spelling; Escape stays usable for dialogs")
    func stopKey() throws {
        func reserved(_ action: ComputerAction) -> Bool {
            if case .outOfGrant(let reason) = classify(action).actionClass { return reason.contains("stop key") }
            return false
        }
        #expect(reserved(.key(combo: try KeyCombo(parsing: "ctrl+alt+cmd+."))))
        #expect(reserved(.key(combo: try KeyCombo(parsing: "Command+Option+Control+."))))
        #expect(reserved(.hold(combo: .defaultStopKey, milliseconds: 100)))
        #expect(classify(.key(combo: try KeyCombo(parsing: "Esc"))).actionClass == .interact)
        #expect(classify(.type(text: "a\u{1b}b", into: .ref("e5", observation: "o_1"))).actionClass == .interact)
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
        #expect(classify(.click(at: .ref("e2", observation: "o_1")), safetySignals: [.maliciousInstructions]).actionClass.isConsequential)

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

@Suite("Computer use: Return is classified as the control it triggers")
struct ComputerUseReturnClassificationTests {
    private let classifier = ComputerUseActionClassifier()
    private let app = ComputerUseFixtures.textEdit

    private func observation(control label: String?, focused role: String = "AXTextField") -> DisplayObservation {
        var observation = ComputerUseFixtures.observation(id: "o_1")
        var elements = [
            "e1": ElementRef(id: "e1", role: role, label: "Amount", app: app, isFocused: true),
            "e2": ElementRef(id: "e2", role: "AXButton", label: label, app: app),
        ]
        if label == nil { elements["e2"] = nil }
        observation.tree = ObservationTree(text: "", elements: elements, capturedAt: ComputerUseFixtures.epoch, returnTarget: label == nil ? nil : "e2")
        return observation
    }

    private func classify(_ action: ComputerAction, _ observation: DisplayObservation) -> ComputerUseActionClass {
        classifier.classify(action, context: ComputerUseClassificationContext(
            grants: ComputerUseGrantSet([.app(bundleID: app.bundleID, tier: .full)]),
            observation: { $0 == observation.id ? observation : nil },
            focusedApp: app,
            latestObservation: observation
        )).actionClass
    }

    @Test("Return from a field whose form submits through a consequential control is consequential")
    func submits() throws {
        let enter = ComputerAction.key(combo: KeyCombo(modifiers: [], key: "return"))
        #expect(classify(enter, observation(control: "Pay now")).isConsequential)
        #expect(classify(.type(text: "42\n", into: .ref("e1", observation: "o_1")), observation(control: "Send")).isConsequential)
        #expect(classify(.key(combo: try KeyCombo(parsing: "shift+return")), observation(control: "Pay now")).isConsequential)
    }

    @Test("A harmless control, no control, a multi-line field, or another key stays Interact")
    func staysInteract() throws {
        let enter = ComputerAction.key(combo: KeyCombo(modifiers: [], key: "return"))
        #expect(classify(enter, observation(control: "Search")) == .interact)
        #expect(classify(enter, observation(control: nil)) == .interact)
        #expect(classify(enter, observation(control: "Pay now", focused: "AXTextArea")) == .interact)
        #expect(classify(.key(combo: KeyCombo(modifiers: [], key: "tab")), observation(control: "Pay now")) == .interact)
    }
}
