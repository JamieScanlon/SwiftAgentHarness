import Foundation

/// The four trigger kinds a registration can create.
///
/// Only `.schedule` has a spec today; the others land with their lifecycle phases. `TriggerSource`
/// remains the *fire-time* vocabulary (it also carries `api` and `delegate`, which are not
/// registerable) — this enum is deliberately the narrower registration-time one.
public enum TriggerKind: String, Codable, Sendable, Equatable, CaseIterable {
    case schedule
    case webhook
    case channel
    case fileEvent = "file-event"
}

/// A registration's identity across kinds. On-disk ids stay per-store; this is the cross-kind handle.
public struct TriggerRegistrationID: Codable, Sendable, Equatable, Hashable {
    public var kind: TriggerKind
    public var id: String

    public init(kind: TriggerKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public var description: String { "\(kind.rawValue):\(id)" }
}

/// What a registration request is asking to create.
///
/// Cases are added per phase rather than stubbed, so an unimplemented kind is a compile-time
/// absence rather than a runtime `notImplemented` that reads as supported.
enum TriggerRegistrationSpec: Sendable {
    case schedule(ScheduleRegistrationSpec)
    case webhook(WebhookRegistrationSpec)

    var kind: TriggerKind {
        switch self {
        case .schedule: return .schedule
        case .webhook: return .webhook
        }
    }
}

enum TriggerRegistrationError: Error, Equatable {
    /// This creator may not register this kind at all (sub-agent, or agent attempting a channel).
    case kindNotRegisterable(kind: TriggerKind, creator: String)
    /// Spec-level validation failed — bad schedule expression, or the create-time content scan.
    case validation(ScheduledTaskValidationError)
    case notFound
    /// A `system`/`permanent` entry may be listed by the agent tools but not mutated by them.
    case immutableSystemEntry(id: String)
    /// Rewriting the prompt of a task that fires into a *different* conversation than the caller's.
    /// The original create cleared an approval gate for a specific prompt; the rewrite has not.
    case crossConversationPayloadChange(id: String)
    case webhook(WebhookRegistrationError)
    /// The caller's owner account does not match the one recorded on the channel's config.
    case channelNotOwned(channel: String)
    /// This deployment has no channel lifecycle store or no channel config to check against.
    /// Distinct from `kindNotRegisterable` so an unconfigured deployment does not fill the audit log
    /// with rows that read exactly like a sub-agent trying to silence a channel.
    case channelLifecycleUnavailable
    /// `channels.json` did not decode, so there is no trustworthy ACL to authorize against. Refused
    /// rather than treated as "no owner recorded", which would be a permissive read of a broken file.
    case channelConfigUnreadable(channel: String)
    /// A runtime enable was asked for on a channel `channels.json` disables. Config is authoritative
    /// in that direction: turning a channel on is the decision that carries the credentials and the
    /// inbound socket, and it belongs in config, not in a runtime overlay.
    case channelDisabledInConfig(channel: String)
}

extension TriggerRegistrationError {
    /// Stable machine-readable code for tool results and audit rows.
    var code: String {
        switch self {
        case .kindNotRegisterable: return "kind_not_registerable"
        case .validation(let inner):
            switch inner {
            case .invalidSchedule: return "invalid_schedule"
            case .scanFailed: return "scan_failed"
            case .permanentNotAllowed: return "permanent_not_allowed"
            case .emptyPayload: return "empty_payload"
            case .unknownTimezone: return "unknown_timezone"
            }
        case .notFound: return "not_found"
        case .immutableSystemEntry: return "immutable_system_entry"
        case .crossConversationPayloadChange: return "cross_conversation_payload_change"
        case .webhook(let inner):
            switch inner {
            case .invalidName: return "invalid_route_name"
            case .nameCollidesWithStaticRoute: return "static_route_name_collision"
            case .templateScanFailed: return "template_scan_failed"
            case .invalidDeliveryTarget: return "invalid_delivery_target"
            case .tooManyRoutes: return "too_many_routes"
            case .alreadyExists: return "already_exists"
            case .staticRouteImmutable: return "static_route_immutable"
            case .notOwned: return "not_owned"
            }
        case .channelNotOwned: return "channel_not_owned"
        case .channelLifecycleUnavailable: return "channel_lifecycle_unavailable"
        case .channelConfigUnreadable: return "channel_config_unreadable"
        case .channelDisabledInConfig: return "channel_disabled_in_config"
        }
    }
}
