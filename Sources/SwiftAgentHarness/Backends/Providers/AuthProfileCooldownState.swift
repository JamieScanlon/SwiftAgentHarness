import Foundation

/// Per-profile cooldown state owned by the Pool but keyed on provider auth profiles.
public struct AuthProfileCooldownState: Sendable, Equatable {
    public var lastStatus: AuthProfileStatus
    public var lastErrorResetAt: Date?

    public init(lastStatus: AuthProfileStatus = .ok, lastErrorResetAt: Date? = nil) {
        self.lastStatus = lastStatus
        self.lastErrorResetAt = lastErrorResetAt
    }

    public func isAvailable(at now: Date) -> Bool {
        guard lastStatus == .exhausted || lastStatus == .rateLimited else { return true }
        guard let resetAt = lastErrorResetAt else { return true }
        return now >= resetAt
    }

    public mutating func mark(
        classification: ProviderFailoverClassification,
        now: Date = Date(),
        billingCooldown: TimeInterval = 3600,
        rateLimitCooldown: TimeInterval = 900
    ) {
        switch classification {
        case .credentialExhausted:
            lastStatus = .exhausted
            lastErrorResetAt = now.addingTimeInterval(billingCooldown)
        case .rateLimited:
            lastStatus = .rateLimited
            lastErrorResetAt = now.addingTimeInterval(rateLimitCooldown)
        case .authError:
            lastStatus = .authError
            lastErrorResetAt = nil
        default:
            break
        }
    }
}

public actor AuthProfileCooldownRegistry {
    private var states: [String: AuthProfileCooldownState] = [:]

    public init() {}

    public func state(forKey key: String) -> AuthProfileCooldownState {
        states[key] ?? AuthProfileCooldownState()
    }

    public func isAvailable(key: String, at now: Date = Date()) -> Bool {
        state(forKey: key).isAvailable(at: now)
    }

    public func mark(
        key: String,
        classification: ProviderFailoverClassification,
        now: Date = Date(),
        billingCooldown: TimeInterval = 3600,
        rateLimitCooldown: TimeInterval = 900
    ) {
        var current = states[key] ?? AuthProfileCooldownState()
        current.mark(
            classification: classification,
            now: now,
            billingCooldown: billingCooldown,
            rateLimitCooldown: rateLimitCooldown
        )
        states[key] = current
    }

    public func resetForTesting() {
        states = [:]
    }
}
