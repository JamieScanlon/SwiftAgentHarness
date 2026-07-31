import Foundation

/// What a budget ledger covers.
///
/// Most-specific-wins decides which budget's ceiling and rung *govern* a source; every matching
/// ledger is still *charged*, so the global ledger sees every dollar and a per-source budget cannot
/// hide spend from it.
public enum TriggerBudgetScope: Sendable, Equatable, Hashable {
    case global
    case trustClass(CommEnvelopeOriginTrust)
    /// One webhook route, cron job, or channel peer.
    case source(String)

    /// Stable ledger key. Prefixed so a source literally named `global` cannot collide.
    public var key: String {
        switch self {
        case .global: return "global"
        case .trustClass(let trust): return "trust:\(trust.rawValue)"
        case .source(let id): return "source:\(id)"
        }
    }

    public var isSourceScoped: Bool {
        if case .source = self { return true }
        return false
    }

    /// Higher is more specific.
    public var specificity: Int {
        switch self {
        case .global: return 0
        case .trustClass: return 1
        case .source: return 2
        }
    }
}

public enum TriggerBudgetWindow: String, Sendable, Equatable {
    case day
    case month

    /// Calendar-aligned in local time, per the spec.
    public func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        switch self {
        case .day:
            return String(format: "%04d-%02d-%02d", year, month, parts.day ?? 0)
        case .month:
            return String(format: "%04d-%02d", year, month)
        }
    }
}

/// The rungs of the breach ladder that this build implements.
///
/// `degrade` (re-route to a cheaper pinned model, flip to lightweight context) is deliberately
/// absent: it needs per-task model pinning, which does not exist yet. Three rungs that work beat
/// four where one is decorative.
public enum TriggerBudgetRung: String, Sendable, Equatable, Comparable {
    /// Notify the owner through the origin channel captured at registration. Fires still run.
    case warn
    /// New fires are refused for the remainder of the window. Recurring fires collapse rather than
    /// replay, per the missed-fire semantics in scheduling.
    case deferFires = "defer"
    /// The source stops firing until a human re-enables it.
    case suspend

    private var order: Int {
        switch self {
        case .warn: return 0
        case .deferFires: return 1
        case .suspend: return 2
        }
    }

    public static func < (lhs: TriggerBudgetRung, rhs: TriggerBudgetRung) -> Bool {
        lhs.order < rhs.order
    }
}

public struct TriggerBudget: Sendable, Equatable {
    public var scope: TriggerBudgetScope
    public var window: TriggerBudgetWindow
    public var ceilingUSD: Double
    /// Fraction of the ceiling at which the owner is warned.
    public var warnFraction: Double
    /// Consecutive fully-breached windows before deferral escalates to sticky suspension. A source
    /// that exhausts its ceiling every window is misconfigured or hostile either way.
    public var suspendAfterBreachedWindows: Int

    public init(
        scope: TriggerBudgetScope,
        window: TriggerBudgetWindow = .day,
        ceilingUSD: Double,
        warnFraction: Double = 0.75,
        suspendAfterBreachedWindows: Int = 3
    ) {
        self.scope = scope
        self.window = window
        self.ceilingUSD = ceilingUSD
        self.warnFraction = max(0, min(1, warnFraction))
        self.suspendAfterBreachedWindows = max(1, suspendAfterBreachedWindows)
    }

    public func rung(forSpent spent: Double) -> TriggerBudgetRung? {
        guard ceilingUSD > 0 else { return nil }
        if spent >= ceilingUSD { return .deferFires }
        if spent >= ceilingUSD * warnFraction { return .warn }
        return nil
    }
}

/// Operator-owned budget configuration.
///
/// Deliberately **not** part of any agent-facing schema: per self-modification.md, an agent may
/// lower its own job's caps and may report ledger state, but raising a ceiling or widening a window
/// is a user/operator action. There is no tool parameter that reaches this type.
public struct TriggerBudgetConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var global: TriggerBudget?
    /// Every source inherits one of these the moment it is registered. A budget that exists only
    /// when someone remembers to configure it protects nobody.
    public var trustClassDefaults: [CommEnvelopeOriginTrust: TriggerBudget]
    public var perSource: [String: TriggerBudget]
    /// Ledger rows older than this many windows are pruned on write.
    public var retainedWindows: Int

    public init(
        enabled: Bool = true,
        global: TriggerBudget? = TriggerBudget(scope: .global, window: .day, ceilingUSD: 25),
        trustClassDefaults: [CommEnvelopeOriginTrust: TriggerBudget] = TriggerBudgetConfiguration.defaultTrustClassBudgets,
        perSource: [String: TriggerBudget] = [:],
        retainedWindows: Int = 90
    ) {
        self.enabled = enabled
        self.global = global
        self.trustClassDefaults = trustClassDefaults
        self.perSource = perSource
        self.retainedWindows = retainedWindows
    }

    /// Deliberately conservative for the levels whose payloads are attacker-reachable. A signed
    /// webhook clearing every other gate is exactly the case this page exists for.
    public static let defaultTrustClassBudgets: [CommEnvelopeOriginTrust: TriggerBudget] = [
        .system: TriggerBudget(scope: .trustClass(.system), ceilingUSD: 10),
        .userDirect: TriggerBudget(scope: .trustClass(.userDirect), ceilingUSD: 10),
        .userDeferred: TriggerBudget(scope: .trustClass(.userDeferred), ceilingUSD: 10),
        .knownParty: TriggerBudget(scope: .trustClass(.knownParty), ceilingUSD: 5),
        .unknownParty: TriggerBudget(scope: .trustClass(.unknownParty), ceilingUSD: 1),
    ]

    public static let disabled = TriggerBudgetConfiguration(enabled: false, global: nil, trustClassDefaults: [:])

    /// Every budget that applies, most specific first. All of them are charged; the first one
    /// breached governs the rung.
    public func applicable(sourceKey: String, trust: CommEnvelopeOriginTrust) -> [TriggerBudget] {
        var budgets: [TriggerBudget] = []
        if let perSource = perSource[sourceKey] {
            budgets.append(perSource)
        }
        if let trustDefault = trustClassDefaults[trust] {
            budgets.append(TriggerBudget(
                scope: .trustClass(trust),
                window: trustDefault.window,
                ceilingUSD: trustDefault.ceilingUSD,
                warnFraction: trustDefault.warnFraction,
                suspendAfterBreachedWindows: trustDefault.suspendAfterBreachedWindows
            ))
        }
        if let global {
            budgets.append(global)
        }
        return budgets.sorted { $0.scope.specificity > $1.scope.specificity }
    }
}
