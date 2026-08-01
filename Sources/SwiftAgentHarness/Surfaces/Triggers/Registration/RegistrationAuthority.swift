import Foundation

/// Where a registration request entered the harness.
///
/// Recorded for attribution only — the surface never grants authority. Authority comes from
/// ``RegistrationCreator``, which the client resolves from ambient session state it cannot forge.
public enum RegistrationSurfaceKind: String, Codable, Sendable, Equatable {
    case tool
    case slash
    case cli
    case http
    case fileDrop = "file-drop"
    case installer
}

/// Who registered a trigger.
///
/// Resolved server-side from the calling session — a model never supplies its own identity.
/// This is the attribution key for listing, cleanup, delivery routing, and cost attribution.
public enum RegistrationCreator: Codable, Sendable, Equatable {
    /// The harness installer. The only creator permitted to write `system` trust / `permanent` rows.
    case installer
    /// A human acting through a control surface (slash command, CLI, HTTP, local file drop).
    case owner(accountID: UUID?)
    /// The main agent acting through a tool call.
    case agent(conversationID: UUID, ownerAccountID: UUID?)
    /// A sub-agent acting through a tool call. Denied registration by default.
    case subAgent(conversationID: UUID, lineageRoot: UUID, ownerAccountID: UUID?)
}

public extension RegistrationCreator {
    var ownerAccountID: UUID? {
        switch self {
        case .installer: return nil
        case .owner(let accountID): return accountID
        case .agent(_, let ownerAccountID): return ownerAccountID
        case .subAgent(_, _, let ownerAccountID): return ownerAccountID
        }
    }

    /// The conversation that registered this trigger, when one exists. `nil` for installer and
    /// non-conversational owner surfaces.
    var conversationID: UUID? {
        switch self {
        case .installer, .owner: return nil
        case .agent(let conversationID, _): return conversationID
        case .subAgent(let conversationID, _, _): return conversationID
        }
    }

    var isInstaller: Bool {
        if case .installer = self { return true }
        return false
    }

    var isModelDriven: Bool {
        switch self {
        case .agent, .subAgent: return true
        case .installer, .owner: return false
        }
    }

    /// Stable short label for audit rows and log lines.
    var auditLabel: String {
        switch self {
        case .installer: return "installer"
        case .owner: return "owner"
        case .agent: return "agent"
        case .subAgent: return "sub-agent"
        }
    }
}

/// The authority under which a registration request is evaluated.
///
/// Passed explicitly rather than read from ambient state inside the registration path, so that
/// non-conversational clients (operator slash surfaces, CLI, HTTP admin, the installer) can register
/// triggers at all. The client resolves the creator from session state it cannot forge; the
/// registration *spec* carries no identity fields.
public struct RegistrationAuthority: Sendable, Equatable {
    public var creator: RegistrationCreator
    public var surface: RegistrationSurfaceKind
    /// Where a fire should announce back to, captured at create time from the session environment.
    /// A fired trigger has no live session, so this is the only way delivery finds the right human.
    public var origin: TriggerOriginRef?

    public init(
        creator: RegistrationCreator,
        surface: RegistrationSurfaceKind,
        origin: TriggerOriginRef? = nil
    ) {
        self.creator = creator
        self.surface = surface
        self.origin = origin
    }

    /// The installer authority. Constructed only by harness boot code.
    public static let installer = RegistrationAuthority(creator: .installer, surface: .installer)

    /// A local trusted process (the file-event drop directory) acting on the machine owner's behalf.
    public static func localFileDrop(ownerAccountID: UUID? = nil) -> RegistrationAuthority {
        RegistrationAuthority(creator: .owner(accountID: ownerAccountID), surface: .fileDrop)
    }

    /// The operator CLI. Authority comes from being able to run the binary against the data
    /// directory at all — the same trust basis as `localFileDrop`, and the reason neither carries a
    /// conversation. A deployment that does not want this must not hand out shell access to that
    /// directory; there is no in-band check that would add anything.
    public static func localCLI(ownerAccountID: UUID? = nil) -> RegistrationAuthority {
        RegistrationAuthority(creator: .owner(accountID: ownerAccountID), surface: .cli)
    }
}

// MARK: - Policy

/// Privilege ordering for the trust enum. Lower rank == more privileged.
///
/// Used to clamp a requested trust level down to the ceiling the creator is entitled to; a
/// self-registered trigger can never be *more* trusted than its author.
enum RegistrationTrustRank {
    static func rank(_ trust: CommEnvelopeOriginTrust) -> Int {
        switch trust {
        case .system: return 0
        case .userDirect: return 1
        case .userDeferred: return 2
        case .knownParty: return 3
        case .unknownParty: return 4
        }
    }

    /// Returns whichever of the two is *less* privileged.
    static func clamp(_ requested: CommEnvelopeOriginTrust, ceiling: CommEnvelopeOriginTrust) -> CommEnvelopeOriginTrust {
        rank(requested) >= rank(ceiling) ? requested : ceiling
    }
}

/// Registration-time policy: what each creator may register, at what trust, with what durability.
///
/// Nothing here is settable from a registration spec — these are derived from the authority alone.
struct RegistrationPolicy: Sendable, Equatable {
    /// Sub-agents get no registration capability by default. Flip only for a workflow that needs it;
    /// the grant is deployment-wide, so prefer a per-spawn tool grant where possible.
    var allowSubAgentRegistration: Bool = false
    /// Global cap on runtime-registered webhook routes. Per-route rate limits alone do not bound an
    /// agent that registers many routes, so the count itself needs a ceiling.
    var maxDynamicWebhookRoutes: Int? = 32

    static let `default` = RegistrationPolicy()

    func allowsRegistration(_ creator: RegistrationCreator, kind: TriggerKind) -> Bool {
        switch creator {
        case .installer, .owner:
            return true
        case .agent:
            // Channel registration carries credentials and opens a persistent inbound socket.
            // Owner-only, deliberately stricter than the trust ceiling alone would require.
            return kind != .channel
        case .subAgent:
            return allowSubAgentRegistration && kind != .channel
        }
    }

    func maxTrust(for creator: RegistrationCreator, kind: TriggerKind) -> CommEnvelopeOriginTrust {
        switch creator {
        case .installer:
            return .system
        case .owner, .agent, .subAgent:
            switch kind {
            case .schedule:
                // A scheduled prompt earns "treat as user-authored at fire time" by paying for the
                // create-time scan. It never earns `system`.
                return .userDeferred
            case .webhook, .channel, .fileEvent:
                // The payloads these admit are external content regardless of who registered them.
                return .knownParty
            }
        }
    }

    func allowsPermanent(_ creator: RegistrationCreator) -> Bool {
        creator.isInstaller
    }

    /// Session-scoped unless the user asked for persistence. A model-driven registration defaults to
    /// non-durable; a human standing instruction defaults to durable.
    func defaultDurable(for creator: RegistrationCreator) -> Bool {
        !creator.isModelDriven
    }

    /// System entries are visible from the agent-facing tools but not mutable by them. A human may
    /// still delete one — and that deletion is the last word (see the installer tombstone).
    func allowsMutationOfSystemEntry(_ creator: RegistrationCreator) -> Bool {
        switch creator {
        case .installer, .owner: return true
        case .agent, .subAgent: return false
        }
    }
}
