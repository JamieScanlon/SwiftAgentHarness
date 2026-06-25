import Foundation

/// The single decision vocabulary every approval surface normalizes its input to.
/// `allowAlways` is the only outcome that persists a permission rule; `allowOnce`
/// permits just the pending call. `timeout` and `cancelled` are produced by core's
/// lifecycle rather than by a user choice.
public enum ApprovalDecision: String, Codable, Sendable, Equatable, CaseIterable {
    case allowOnce
    case allowAlways
    case deny
    case timeout
    case cancelled

    /// Whether the decision permits the call to proceed.
    public var isAllowed: Bool {
        switch self {
        case .allowOnce, .allowAlways:
            return true
        case .deny, .timeout, .cancelled:
            return false
        }
    }

    /// Whether the decision should persist an `allow-always` permission rule.
    public var persistsRule: Bool {
        self == .allowAlways
    }

    /// Parses a surface button id (or slash token) into a decision. Accepts the
    /// canonical raw values plus common aliases used by channel cards and slash
    /// commands (`approve`, `allow`, `always`, `reject`).
    public static func fromToken(_ token: String) -> ApprovalDecision? {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "allowonce", "allow-once", "allow_once", "approve", "allow", "once", "yes":
            return .allowOnce
        case "allowalways", "allow-always", "allow_always", "always", "durable":
            return .allowAlways
        case "deny", "reject", "no":
            return .deny
        case "timeout":
            return .timeout
        case "cancelled", "canceled", "cancel":
            return .cancelled
        default:
            return nil
        }
    }
}

extension ExecApprovalResolution {
    /// Bridges the legacy exec resolution enum onto the unified decision vocabulary.
    public var approvalDecision: ApprovalDecision {
        switch self {
        case .approved(let durable):
            return durable ? .allowAlways : .allowOnce
        case .denied:
            return .deny
        }
    }
}
