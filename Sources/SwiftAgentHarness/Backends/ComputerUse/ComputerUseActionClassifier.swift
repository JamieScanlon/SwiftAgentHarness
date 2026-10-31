import Foundation

/// The effect class of one action, computed by the harness — never taken from the model's own claim.
public enum ComputerUseActionClass: Sendable, Hashable {
    /// Read-only.
    case observe
    case navigate
    case interact
    /// Irreversible or sensitive; always confirmed, even inside a batch.
    case consequential(reasons: [String])
    case outOfGrant(reason: String)
    /// A cited observation or element cannot be resolved; the model must observe again.
    case unresolvable(reason: String)

    public var label: String {
        switch self {
        case .observe: return "observe"
        case .navigate: return "navigate"
        case .interact: return "interact"
        case .consequential: return "consequential"
        case .outOfGrant: return "out-of-grant"
        case .unresolvable: return "unresolvable"
        }
    }
}

/// The proposed action described by harness-derived identifiers only: no screen text, labels, or titles, which are
/// the injection channel.
public struct ComputerUseProposedAction: Sendable, Codable, Hashable {
    public var kind: String
    public var app: String?
    public var domain: String?
    public var elementRole: String?

    public init(kind: String, app: String? = nil, domain: String? = nil, elementRole: String? = nil) {
        self.kind = kind
        self.app = app
        self.domain = domain
        self.elementRole = elementRole
    }

    /// One line for the prior-action history the intent check reads.
    public var summary: String {
        var parts = [kind]
        if let elementRole { parts.append(elementRole) }
        if let domain { parts.append("on \(domain)") } else if let app { parts.append("in \(app)") }
        return parts.joined(separator: " ")
    }
}

public struct ComputerUseClassification: Sendable, Hashable {
    public var kind: ComputerActionKind
    public var actionClass: ComputerUseActionClass
    public var app: AppIdentity?
    public var domain: String?
    public var elementRole: String?
    /// The element the action lands on, for the approval card. Its label is for the human, never for a gate.
    public var element: ElementRef?
    /// For an out-of-grant action, the grant that would have allowed it, when a task's grants can provide one.
    public var missingGrant: ComputerUseGrant?

    public var proposedAction: ComputerUseProposedAction {
        ComputerUseProposedAction(kind: kind.rawValue, app: app?.bundleID, domain: domain, elementRole: elementRole)
    }
}

public struct ComputerUseClassificationContext: Sendable {
    public var grants: ComputerUseGrantSet
    /// Retained observations the action may cite.
    public var observation: @Sendable (ObservationID) -> DisplayObservation?
    /// The app actions that carry no target land on: the target's focused app.
    public var focusedApp: AppIdentity?
    /// Vendor safety signals attached to this action.
    public var safetySignals: [String]

    public init(
        grants: ComputerUseGrantSet,
        observation: @escaping @Sendable (ObservationID) -> DisplayObservation?,
        focusedApp: AppIdentity?,
        safetySignals: [String] = []
    ) {
        self.grants = grants
        self.observation = observation
        self.focusedApp = focusedApp
        self.safetySignals = safetySignals
    }
}

/// Argument-level classification for the polymorphic computer-use tool. Inputs are the action, the resolved target
/// element (role, label, app, URL), and the grant. Screen-derived labels can only raise the class, never lower it.
public struct ComputerUseActionClassifier: Sendable {
    public var reviewer: ComputerUseGrantReviewer
    /// Reserved for the human; never synthesized while a session is active.
    public var stopKey: KeyCombo
    public var systemShortcuts: Set<KeyCombo>
    public var destructiveShortcuts: Set<KeyCombo>
    public var consequentialLabelWords: Set<String>
    public var secureInputPurposes: Set<String>
    public var secureInputPurposePrefixes: [String]
    /// Apps where every interaction changes system state.
    public var systemSettingsBundleIDs: Set<String>
    public var installerBundleIDs: Set<String>

    public init(
        reviewer: ComputerUseGrantReviewer = ComputerUseGrantReviewer(),
        stopKey: KeyCombo = KeyCombo(modifiers: [], key: "escape"),
        systemShortcuts: Set<KeyCombo> = Self.defaultSystemShortcuts,
        destructiveShortcuts: Set<KeyCombo> = Self.defaultDestructiveShortcuts,
        consequentialLabelWords: Set<String> = Self.defaultConsequentialLabelWords,
        secureInputPurposes: Set<String> = ["current-password", "new-password", "one-time-code"],
        secureInputPurposePrefixes: [String] = ["cc-"],
        systemSettingsBundleIDs: Set<String> = ["com.apple.systempreferences", "com.apple.Settings"],
        installerBundleIDs: Set<String> = ["com.apple.installer"]
    ) {
        self.reviewer = reviewer
        self.stopKey = stopKey
        self.systemShortcuts = systemShortcuts
        self.destructiveShortcuts = destructiveShortcuts
        self.consequentialLabelWords = consequentialLabelWords
        self.secureInputPurposes = secureInputPurposes
        self.secureInputPurposePrefixes = secureInputPurposePrefixes
        self.systemSettingsBundleIDs = systemSettingsBundleIDs
        self.installerBundleIDs = installerBundleIDs
    }

    public static let defaultSystemShortcuts: Set<KeyCombo> = Set([
        "cmd+tab", "shift+cmd+tab", "cmd+space", "ctrl+space", "option+cmd+escape", "ctrl+cmd+q", "shift+cmd+q",
        "option+shift+cmd+q", "ctrl+up", "ctrl+down", "ctrl+left", "ctrl+right", "option+cmd+d", "shift+cmd+3",
        "shift+cmd+4", "shift+cmd+5", "ctrl+shift+cmd+3", "ctrl+shift+cmd+4", "ctrl+cmd+space",
    ].compactMap { try? KeyCombo(parsing: $0) })

    public static let defaultDestructiveShortcuts: Set<KeyCombo> = Set([
        "cmd+delete", "shift+cmd+delete", "option+shift+cmd+delete", "option+cmd+delete",
    ].compactMap { try? KeyCombo(parsing: $0) })

    public static let defaultConsequentialLabelWords: Set<String> = [
        "submit", "send", "buy", "purchase", "pay", "checkout", "order", "delete", "remove", "erase", "install",
        "uninstall", "confirm", "accept", "agree", "sign", "transfer", "publish", "post", "deploy", "trash",
        "subscribe", "unsubscribe", "book", "reserve", "donate", "withdraw", "authorize", "approve", "grant",
    ]

    public func classify(_ action: ComputerAction, context: ComputerUseClassificationContext) -> ComputerUseClassification {
        var result = ComputerUseClassification(kind: action.kind, actionClass: .observe)

        if let reason = stopKeyViolation(action) {
            result.actionClass = .outOfGrant(reason: reason)
            return result
        }

        switch action {
        case .observe, .wait, .waitFor:
            return result
        case .zoom(_, let observation):
            if context.observation(observation) == nil {
                result.actionClass = .unresolvable(reason: "observation \(observation) is not retained; observe again")
            }
            return result
        case .openURL(let url):
            return classifyOpenURL(url, context: context, into: result)
        case .launch(let app, _):
            let identity = AppIdentity(bundleID: app)
            result.app = identity
            return finish(result, app: identity, url: nil, required: .click, base: .navigate, context: context, action: action)
        default:
            break
        }

        // Resolve every cited target; the most specific element wins for the description.
        var resolvedApp: AppIdentity?
        var resolvedURL: String?
        for target in action.citedTargets {
            guard let observation = context.observation(target.observation) else {
                result.actionClass = .unresolvable(reason: "observation \(target.observation) is not retained; observe again")
                return result
            }
            switch target {
            case .ref(let ref, _):
                guard let element = observation.element(ref) else {
                    result.actionClass = .unresolvable(reason: "element \(ref) is not in observation \(observation.id)")
                    return result
                }
                result.element = result.element ?? element
                result.elementRole = result.elementRole ?? element.role
                let app = element.app ?? observation.target.app
                if let resolvedApp, let app, resolvedApp != app {
                    result.actionClass = .outOfGrant(reason: "one action may not span apps")
                    return result
                }
                resolvedApp = resolvedApp ?? app
                resolvedURL = resolvedURL ?? element.url ?? observation.target.url
            case .point(let point, _):
                guard observation.target.bounds.contains(point) else {
                    result.actionClass = .unresolvable(reason: "point lies outside observation \(observation.id)")
                    return result
                }
                if let resolvedApp, let app = observation.target.app, resolvedApp != app {
                    result.actionClass = .outOfGrant(reason: "one action may not span apps")
                    return result
                }
                resolvedApp = resolvedApp ?? observation.target.app
                resolvedURL = resolvedURL ?? observation.target.url
            }
        }

        if action.citedTargets.isEmpty {
            if case .menu(_, let app?) = action {
                resolvedApp = AppIdentity(bundleID: app)
                if let focused = context.focusedApp, focused.bundleID == app { resolvedApp = focused }
            } else {
                resolvedApp = context.focusedApp
            }
        }
        guard resolvedApp != nil || resolvedURL != nil else {
            result.actionClass = .unresolvable(reason: "the target app is unknown; observe first")
            return result
        }
        result.app = resolvedApp

        let (required, base) = requirement(for: action)
        return finish(result, app: resolvedApp, url: resolvedURL, required: required, base: base, context: context, action: action)
    }

    private func requirement(for action: ComputerAction) -> (ComputerUseGrantTier, ComputerUseActionClass) {
        switch action {
        case .scroll, .move: return (.click, .navigate)
        case .click, .drag, .pointer, .press: return (.click, .interact)
        case .type, .key, .hold, .setValue, .menu: return (.full, .interact)
        case .launch, .openURL: return (.click, .navigate)
        case .observe, .zoom, .wait, .waitFor: return (.view, .observe)
        }
    }

    private func stopKeyViolation(_ action: ComputerAction) -> String? {
        switch action {
        case .key(let combo, _), .hold(let combo, _):
            return combo == stopKey ? "\(stopKey) is the reserved stop key" : nil
        case .type(let text, _, _), .setValue(_, let text):
            if stopKey.modifiers.isEmpty, stopKey.key == "escape", text.unicodeScalars.contains("\u{1b}") {
                return "text contains the reserved stop key"
            }
            return nil
        default:
            return nil
        }
    }

    private func classifyOpenURL(
        _ url: String,
        context: ComputerUseClassificationContext,
        into result: ComputerUseClassification
    ) -> ComputerUseClassification {
        var result = result
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = ComputerUseDomain.host(ofURL: url) else {
            result.actionClass = .outOfGrant(reason: "open-url accepts only http(s) URLs")
            return result
        }
        result.domain = host
        if let reason = ComputerUseSecrets.secretInURL(url) {
            result.actionClass = .outOfGrant(reason: "the URL can't be opened because \(reason); secrets must not travel in URLs")
            return result
        }
        guard let tier = context.grants.tier(forURL: url) else {
            result.actionClass = .outOfGrant(reason: "domain \(host) is not granted")
            result.missingGrant = .domain(host, tier: .click)
            return result
        }
        guard tier >= .click else {
            result.actionClass = .outOfGrant(reason: "domain \(host) is granted at \(tier.rawValue); navigation needs click")
            result.missingGrant = .domain(host, tier: .click)
            return result
        }
        result.actionClass = .navigate
        return result
    }

    private func finish(
        _ result: ComputerUseClassification,
        app: AppIdentity?,
        url: String?,
        required: ComputerUseGrantTier,
        base: ComputerUseActionClass,
        context: ComputerUseClassificationContext,
        action: ComputerAction
    ) -> ComputerUseClassification {
        var result = result
        let ruling = app.map { reviewer.ruling(for: $0) } ?? ComputerUseAppRuling()
        if let reason = ruling.blockedReason {
            result.actionClass = .outOfGrant(reason: reason)
            return result
        }

        var tier: ComputerUseGrantTier?
        var subject = app?.bundleID ?? ""
        if let url, ruling.isBrowser || app == nil {
            result.domain = ComputerUseDomain.host(ofURL: url)
            if let domainTier = context.grants.tier(forURL: url) {
                tier = domainTier
                subject = result.domain ?? url
            }
        }
        if tier == nil, let app {
            tier = context.grants.tier(forApp: app.bundleID).map { granted in
                ruling.tierCap.map { min($0, granted) } ?? granted
            }
        }
        let flags = app.map { context.grants.flags(forApp: $0.bundleID) } ?? []
        guard let tier else {
            result.actionClass = .outOfGrant(reason: "\(subject.isEmpty ? "target" : subject) is not granted")
            result.missingGrant = Self.grant(covering: result.domain, app: app, ruling: ruling, flags: flags, tier: required)
            return result
        }
        guard tier >= required else {
            if ruling.isBrowser, action.kind == .launch {
                result.actionClass = .outOfGrant(reason: "\(subject) is a browser, which stays at view; open a page on a granted domain with open-url instead")
                return result
            }
            result.actionClass = .outOfGrant(
                reason: "\(subject) is granted at \(tier.rawValue); \(action.kind.rawValue) needs \(required.rawValue)"
            )
            result.missingGrant = Self.grant(covering: result.domain, app: app, ruling: ruling, flags: flags, tier: required)
            return result
        }

        switch action {
        case .key(let combo, _), .hold(let combo, _):
            if (systemShortcuts.contains(combo) || combo.modifiers.contains(.fn)), !flags.contains(.systemKeys) {
                result.actionClass = .outOfGrant(reason: "\(combo) is a global shortcut; it needs the system-keys flag")
                result.missingGrant = app.map { .app(bundleID: $0.bundleID, tier: tier, flags: flags.union([.systemKeys])) }
                return result
            }
        case .type(_, _, .paste?):
            if !flags.contains(.clipboardWrite) {
                result.actionClass = .outOfGrant(reason: "pasting needs the clipboard-write flag")
                result.missingGrant = app.map { .app(bundleID: $0.bundleID, tier: tier, flags: flags.union([.clipboardWrite])) }
                return result
            }
        default:
            break
        }

        let reasons = consequentialReasons(action: action, element: result.element, app: app, context: context)
        result.actionClass = reasons.isEmpty ? base : .consequential(reasons: reasons)
        return result
    }

    /// The grant a task could add to allow the action: the page's domain in a browser, otherwise the app. `nil` when
    /// no grant helps, such as a browser launch, browser chrome with no page, or a tier above the app's cap.
    private static func grant(
        covering domain: String?,
        app: AppIdentity?,
        ruling: ComputerUseAppRuling,
        flags: Set<ComputerUseGrantFlag>,
        tier: ComputerUseGrantTier
    ) -> ComputerUseGrant? {
        if let domain, ruling.isBrowser || app == nil {
            return .domain(domain, tier: tier)
        }
        guard let app, !ruling.isBrowser else { return nil }
        if let cap = ruling.tierCap, tier > cap { return nil }
        return .app(bundleID: app.bundleID, tier: tier, flags: flags)
    }

    private func consequentialReasons(
        action: ComputerAction,
        element: ElementRef?,
        app: AppIdentity?,
        context: ComputerUseClassificationContext
    ) -> [String] {
        var reasons: [String] = context.safetySignals.map { "vendor safety signal: \($0)" }
        switch action {
        case .type, .setValue:
            if let element {
                if element.isSecureInput {
                    reasons.append("typing into a secure field")
                } else if let purpose = element.inputPurpose?.lowercased(),
                          secureInputPurposes.contains(purpose) || secureInputPurposePrefixes.contains(where: purpose.hasPrefix) {
                    reasons.append("typing into a \(purpose) field")
                }
            }
        case .key(let combo, _), .hold(let combo, _):
            if destructiveShortcuts.contains(combo) { reasons.append("\(combo) is destructive") }
        default:
            break
        }
        switch action {
        case .click, .press, .key, .menu:
            if let word = consequentialWord(in: element?.label) {
                reasons.append("target is labeled as a \(word) action")
            }
            if case .menu(let path, _) = action, let word = path.lazy.compactMap({ consequentialWord(in: $0) }).first {
                reasons.append("menu item is a \(word) action")
            }
        default:
            break
        }
        if let app {
            if systemSettingsBundleIDs.contains(app.bundleID), action.kind != .scroll, action.kind != .move {
                reasons.append("system settings change")
            }
            if installerBundleIDs.contains(app.bundleID) {
                reasons.append("software installation")
            }
        }
        return reasons
    }

    private func consequentialWord(in label: String?) -> String? {
        guard let label else { return nil }
        let words = label.lowercased().split { !$0.isLetter }.map(String.init)
        return words.first { consequentialLabelWords.contains($0) }
    }
}
