import Foundation

public enum ComputerUseGrantTier: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    /// The app appears in observations only.
    case view
    /// Pointer actions, but no typing or shortcuts.
    case click
    case full

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: ComputerUseGrantTier, rhs: ComputerUseGrantTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum ComputerUseGrantFlag: String, Sendable, Codable, Hashable {
    case clipboardRead = "clipboard-read"
    case clipboardWrite = "clipboard-write"
    case systemKeys = "system-keys"
}

/// One per-session grant. Grants expire with the session.
public enum ComputerUseGrant: Sendable, Codable, Hashable {
    case app(bundleID: String, tier: ComputerUseGrantTier, flags: Set<ComputerUseGrantFlag> = [])
    case domain(String, tier: ComputerUseGrantTier)

    public var tier: ComputerUseGrantTier {
        switch self {
        case .app(_, let tier, _), .domain(_, let tier): return tier
        }
    }

    func replacingTier(_ tier: ComputerUseGrantTier) -> ComputerUseGrant {
        switch self {
        case .app(let bundleID, _, let flags): return .app(bundleID: bundleID, tier: tier, flags: flags)
        case .domain(let domain, _): return .domain(domain, tier: tier)
        }
    }

    /// The grant with its subject normalized (domains lowercased and stripped of scheme, path, and wildcard).
    var normalized: ComputerUseGrant {
        switch self {
        case .app: return self
        case .domain(let raw, let tier): return .domain(ComputerUseDomain.normalize(raw), tier: tier)
        }
    }

    /// Same subject, ignoring tier and flags.
    func sameSubject(as other: ComputerUseGrant) -> Bool {
        switch (self.normalized, other.normalized) {
        case (.app(let a, _, _), .app(let b, _, _)): return a == b
        case (.domain(let a, _), .domain(let b, _)): return a == b
        default: return false
        }
    }
}

enum ComputerUseDomain {
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") {
            value = String(value[range.upperBound...])
        }
        if let slash = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            value = String(value[..<slash])
        }
        if let at = value.lastIndex(of: "@") {
            value = String(value[value.index(after: at)...])
        }
        if let colon = value.lastIndex(of: ":") {
            value = String(value[..<colon])
        }
        if value.hasPrefix("*.") { value.removeFirst(2) }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    static func host(ofURL raw: String) -> String? {
        guard let components = URLComponents(string: raw), let host = components.host, !host.isEmpty else { return nil }
        return normalize(host)
    }

    static func matches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}

/// The approved grants of one session, with lookups.
public struct ComputerUseGrantSet: Sendable, Hashable {
    public let grants: [ComputerUseGrant]

    public init(_ grants: [ComputerUseGrant]) {
        self.grants = grants.map(\.normalized)
    }

    public func tier(forApp bundleID: String) -> ComputerUseGrantTier? {
        grants.compactMap { grant -> ComputerUseGrantTier? in
            if case .app(let id, let tier, _) = grant, id == bundleID { return tier }
            return nil
        }.max()
    }

    public func flags(forApp bundleID: String) -> Set<ComputerUseGrantFlag> {
        grants.reduce(into: Set<ComputerUseGrantFlag>()) { result, grant in
            if case .app(let id, _, let flags) = grant, id == bundleID { result.formUnion(flags) }
        }
    }

    /// The tier of the most specific domain grant covering the URL's host.
    public func tier(forURL url: String) -> ComputerUseGrantTier? {
        guard let host = ComputerUseDomain.host(ofURL: url) else { return nil }
        let matching = grants.compactMap { grant -> (domain: String, tier: ComputerUseGrantTier)? in
            if case .domain(let domain, let tier) = grant, ComputerUseDomain.matches(host: host, domain: domain) {
                return (domain, tier)
            }
            return nil
        }
        return matching.max { $0.domain.count < $1.domain.count }?.tier
    }

    public var hasDomainGrants: Bool {
        grants.contains { if case .domain = $0 { return true } else { return false } }
    }
}

/// How the harness treats one app before any grant applies.
public struct ComputerUseAppRuling: Sendable, Hashable {
    /// Blocked unless the operator overrides it.
    public var blockedReason: String?
    public var tierCap: ComputerUseGrantTier?
    public var capReason: String?
    /// The app's real blast radius, stated in the grant dialog.
    public var blastRadiusWarning: String?
    /// Browser pages are reached through domain grants; the app itself is capped at view.
    public var isBrowser: Bool

    public init(
        blockedReason: String? = nil,
        tierCap: ComputerUseGrantTier? = nil,
        capReason: String? = nil,
        blastRadiusWarning: String? = nil,
        isBrowser: Bool = false
    ) {
        self.blockedReason = blockedReason
        self.tierCap = tierCap
        self.capReason = capReason
        self.blastRadiusWarning = blastRadiusWarning
        self.isBrowser = isBrowser
    }
}

/// Bundle-id and category rules. Matching is by bundle id and declared category only, never by window title.
/// A pattern ending in `*` matches by prefix.
public struct ComputerUseAppPolicy: Sendable, Hashable {
    public struct Rule: Sendable, Hashable {
        public var bundleIDs: [String]
        public var categories: [String]
        public var reason: String

        public init(bundleIDs: [String] = [], categories: [String] = [], reason: String) {
            self.bundleIDs = bundleIDs
            self.categories = categories
            self.reason = reason
        }

        func matches(_ app: AppIdentity) -> Bool {
            if let category = app.category, categories.contains(category) { return true }
            return bundleIDs.contains { pattern in
                pattern.hasSuffix("*") ? app.bundleID.hasPrefix(String(pattern.dropLast())) : app.bundleID == pattern
            }
        }
    }

    public var blocked: [Rule]
    public var clickOnly: [Rule]
    public var browsers: [Rule]
    public var broadBlastRadius: [Rule]

    public init(blocked: [Rule], clickOnly: [Rule], browsers: [Rule], broadBlastRadius: [Rule]) {
        self.blocked = blocked
        self.clickOnly = clickOnly
        self.browsers = browsers
        self.broadBlastRadius = broadBlastRadius
    }

    public func ruling(for app: AppIdentity) -> ComputerUseAppRuling {
        var ruling = ComputerUseAppRuling()
        if let rule = blocked.first(where: { $0.matches(app) }) {
            ruling.blockedReason = rule.reason
        }
        if let rule = clickOnly.first(where: { $0.matches(app) }) {
            ruling.tierCap = .click
            ruling.capReason = rule.reason
            ruling.blastRadiusWarning = rule.reason
        }
        if let rule = browsers.first(where: { $0.matches(app) }) {
            ruling.isBrowser = true
            ruling.tierCap = .view
            ruling.capReason = rule.reason
        }
        if let rule = broadBlastRadius.first(where: { $0.matches(app) }) {
            ruling.blastRadiusWarning = rule.reason
        }
        return ruling
    }

    public static let `default` = ComputerUseAppPolicy(
        blocked: [
            Rule(
                bundleIDs: [
                    "com.1password.*", "com.agilebits.onepassword*", "com.bitwarden.desktop", "com.apple.Passwords",
                    "com.apple.keychainaccess", "com.lastpass.LastPass", "com.dashlane.*", "com.keepersecurity.*",
                    "org.keepassxc.keepassxc", "com.enpass.*", "in.sinew.Enpass-Desktop",
                ],
                reason: "Password manager: holds credentials for every other account."
            ),
            Rule(
                categories: ["public.app-category.finance"],
                reason: "Financial app: investment, trading, crypto, and banking actions are high-harm."
            ),
        ],
        clickOnly: [
            Rule(
                bundleIDs: [
                    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp*", "net.kovidgoyal.kitty",
                    "com.mitchellh.ghostty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm",
                    "com.microsoft.VSCode*", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed*", "com.apple.dt.Xcode",
                    "com.jetbrains.*", "com.google.android.studio", "com.sublimetext.*", "com.panic.Nova",
                    "com.apple.ScriptEditor2", "com.apple.Automator",
                ],
                categories: ["public.app-category.developer-tools"],
                reason: "Terminal or IDE: typing here is shell access."
            ),
        ],
        browsers: [
            Rule(
                bundleIDs: [
                    "com.apple.Safari*", "com.google.Chrome*", "org.chromium.Chromium", "org.mozilla.firefox*",
                    "com.microsoft.edgemac*", "company.thebrowser.Browser", "com.brave.Browser*",
                    "com.operasoftware.Opera*", "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS",
                ],
                reason: "Browser: pages are granted per domain."
            ),
        ],
        broadBlastRadius: [
            Rule(
                bundleIDs: ["com.apple.finder", "com.apple.systempreferences", "com.apple.Settings", "com.apple.shortcuts"],
                reason: "Its reach is far broader than the app: files, system settings, or automation across apps."
            ),
        ]
    )
}

public struct ComputerUseOperatorOverrides: Sendable, Hashable {
    /// Blocked apps the operator explicitly allows.
    public var allowBlockedBundleIDs: Set<String>
    /// Apps whose tier cap the operator lifts.
    public var uncappedBundleIDs: Set<String>
    /// Explicit opt-out of confirming interact actions on shared targets when no intent checker is bound.
    public var skipInteractConfirmationWithoutIntentCheck: Bool

    public init(
        allowBlockedBundleIDs: Set<String> = [],
        uncappedBundleIDs: Set<String> = [],
        skipInteractConfirmationWithoutIntentCheck: Bool = false
    ) {
        self.allowBlockedBundleIDs = allowBlockedBundleIDs
        self.uncappedBundleIDs = uncappedBundleIDs
        self.skipInteractConfirmationWithoutIntentCheck = skipInteractConfirmationWithoutIntentCheck
    }

    public static let none = ComputerUseOperatorOverrides()
}

public struct ComputerUseReviewedGrant: Sendable, Hashable {
    /// The grant as it may be approved, with its tier capped.
    public var grant: ComputerUseGrant
    public var requestedTier: ComputerUseGrantTier
    public var capReason: String?
    public var warning: String?
}

public struct ComputerUseBlockedGrant: Sendable, Hashable {
    public var grant: ComputerUseGrant
    public var reason: String
}

/// What the one start-of-session grant dialog presents.
public struct ComputerUseGrantReview: Sendable, Hashable {
    public var grantable: [ComputerUseReviewedGrant]
    public var blocked: [ComputerUseBlockedGrant]
}

public struct ComputerUseGrantReviewer: Sendable {
    public var policy: ComputerUseAppPolicy
    public var overrides: ComputerUseOperatorOverrides

    public init(policy: ComputerUseAppPolicy = .default, overrides: ComputerUseOperatorOverrides = .none) {
        self.policy = policy
        self.overrides = overrides
    }

    /// Category rules need the app's declared category, which is known only once the target reports it, so they
    /// are applied again at action time.
    public func ruling(for app: AppIdentity) -> ComputerUseAppRuling {
        var ruling = policy.ruling(for: app)
        if overrides.allowBlockedBundleIDs.contains(app.bundleID) { ruling.blockedReason = nil }
        if overrides.uncappedBundleIDs.contains(app.bundleID) {
            ruling.tierCap = nil
            ruling.capReason = nil
        }
        return ruling
    }

    public func review(_ requested: [ComputerUseGrant]) -> ComputerUseGrantReview {
        var grantable: [ComputerUseReviewedGrant] = []
        var blocked: [ComputerUseBlockedGrant] = []
        for grant in requested.map(\.normalized) {
            switch grant {
            case .domain(let domain, let tier):
                guard !domain.isEmpty else {
                    blocked.append(ComputerUseBlockedGrant(grant: grant, reason: "Empty domain."))
                    continue
                }
                grantable.append(ComputerUseReviewedGrant(grant: grant, requestedTier: tier))
            case .app(let bundleID, let tier, _):
                let ruling = ruling(for: AppIdentity(bundleID: bundleID))
                if let reason = ruling.blockedReason {
                    blocked.append(ComputerUseBlockedGrant(grant: grant, reason: reason))
                    continue
                }
                let capped = ruling.tierCap.map { min($0, tier) } ?? tier
                grantable.append(ComputerUseReviewedGrant(
                    grant: grant.replacingTier(capped),
                    requestedTier: tier,
                    capReason: capped < tier ? ruling.capReason : nil,
                    warning: ruling.blastRadiusWarning
                ))
            }
        }
        return ComputerUseGrantReview(grantable: grantable, blocked: blocked)
    }

    /// The approver's answer clamped to the review: only grantable subjects, never above their capped tier.
    public func clamp(_ approved: [ComputerUseGrant], to review: ComputerUseGrantReview) -> [ComputerUseGrant] {
        approved.map(\.normalized).compactMap { grant in
            guard let reviewed = review.grantable.first(where: { $0.grant.sameSubject(as: grant) }) else { return nil }
            let tier = min(grant.tier, reviewed.grant.tier)
            if case .app(let bundleID, _, let flags) = grant, case .app(_, _, let requestedFlags) = reviewed.grant {
                return .app(bundleID: bundleID, tier: tier, flags: flags.intersection(requestedFlags))
            }
            return grant.replacingTier(tier)
        }
    }
}
