import Foundation

public enum ExecApprovalResolution: Sendable, Equatable {
    case approved(durable: Bool)
    case denied(String)
}

/// Owning conversation and tenant for a pending exec approval (DEF-125).
public struct ExecApprovalScope: Sendable, Equatable {
    public let conversationID: UUID
    public let ownerAccountID: UUID?

    public init(conversationID: UUID, ownerAccountID: UUID?) {
        self.conversationID = conversationID
        self.ownerAccountID = ownerAccountID
    }
}

/// Thin exec-approval façade over the core-owned `ApprovalCoordinator`. Owns only
/// the exec-specific concerns (command text + durable grant store); the pending
/// registry, dedupe, waiter resume, and timeout live in the coordinator.
public actor ExecApprovalStore {
    public static let shared = ExecApprovalStore()

    private let coordinator: ApprovalCoordinator
    private var commands: [String: String] = [:]
    private var scopesByID: [String: ExecApprovalScope] = [:]
    private var allowsDurableBypassByID: [String: Bool] = [:]
    private var grantStore: any ExecApprovalGrantStore

    public init(
        grantStore: any ExecApprovalGrantStore = InMemoryExecApprovalGrantStore(),
        coordinator: ApprovalCoordinator = ApprovalCoordinator()
    ) {
        self.grantStore = grantStore
        self.coordinator = coordinator
    }

    /// Swaps the backing grant store. Intended to be called once at host startup
    /// (e.g. on `ExecApprovalStore.shared`) before any approvals are processed.
    public func configure(grantStore: any ExecApprovalGrantStore) {
        self.grantStore = grantStore
    }

    /// Resets pending exec approvals and grant state. Test-only isolation seam for `shared`.
    public func resetForTesting() async {
        commands.removeAll()
        scopesByID.removeAll()
        allowsDurableBypassByID.removeAll()
        grantStore = InMemoryExecApprovalGrantStore()
        await coordinator.resetForTesting()
    }

    public func registerPending(
        id: String,
        command: String,
        scope: ExecApprovalScope,
        allowsDurableBypass: Bool = true,
        presentation: ApprovalPresentation? = nil
    ) async {
        commands[id] = command
        scopesByID[id] = scope
        allowsDurableBypassByID[id] = allowsDurableBypass
        // Exec uses a caller-supplied wait timeout, so the registration timeout is a
        // large placeholder; the deny default only applies if a tool-style wait is used.
        _ = await coordinator.register(
            id: id,
            presentation: presentation,
            timeoutMs: Int.max / 2,
            timeoutResolution: .deny,
            timeoutSource: "exec.timeout"
        )
    }

    public func pendingScope(id: String) -> ExecApprovalScope? {
        scopesByID[id]
    }

    public func isDurableApproved(command: String) async -> Bool {
        guard let name = ExecApprovalGrantCommandName.durableGrantCommandName(from: command) else { return false }
        return await grantStore.isGranted(commandName: name)
    }

    public func addDurableApproval(command: String) async {
        guard let name = ExecApprovalGrantCommandName.durableGrantCommandName(from: command) else { return }
        await grantStore.add(commandName: name)
    }

    /// Lists all durable grants (command names) from the configured grant store,
    /// sorted ascending.
    public func listDurableGrants() async -> [String] {
        await grantStore.list()
    }

    /// Revokes a durable grant by command name. Returns `true` when an existing
    /// grant was removed, `false` when the name is blank or no grant exists.
    @discardableResult
    public func revokeDurableGrant(commandName: String) async -> Bool {
        let trimmed = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard await grantStore.isGranted(commandName: trimmed) else { return false }
        await grantStore.remove(commandName: trimmed)
        return true
    }

    /// When `durable` is true, a persisted grant is stored only when a safe grant key
    /// can be derived (interpreter/wrapper prefixes are peeled) and the pending request
    /// allowed durable bypass (elevated/host exec does not persist grants). Unpeelable
    /// interpreter commands still resolve as allow-always for the pending request but leave no grant.
    @discardableResult
    public func resolve(
        id: String,
        scope: ExecApprovalScope,
        strictTenancy: Bool,
        ownerScope: UUID?,
        approved: Bool,
        durable: Bool = false,
        reason: String? = nil
    ) async -> ExecApprovalResolution? {
        guard await coordinator.isPending(id: id) else { return nil }
        guard let pendingScope = scopesByID[id],
              Self.scopeMatches(
                  pending: pendingScope,
                  resolver: scope,
                  ownerScope: ownerScope,
                  strictTenancy: strictTenancy
              ) else {
            return nil
        }
        let command = commands.removeValue(forKey: id)
        scopesByID.removeValue(forKey: id)
        let allowsDurableBypass = allowsDurableBypassByID.removeValue(forKey: id) ?? true
        if approved, durable, allowsDurableBypass, let command {
            await addDurableApproval(command: command)
        }
        let decision: ApprovalDecision = approved ? (durable ? .allowAlways : .allowOnce) : .deny
        guard let outcome = await coordinator.resolve(
            id: id,
            decision: decision,
            source: "exec.resolve",
            reason: approved ? nil : (reason ?? "denied")
        ) else { return nil }
        return Self.execResolution(from: outcome)
    }

    public func waitForResolution(id: String, timeoutSeconds: TimeInterval?) async -> ExecApprovalResolution? {
        guard let outcome = await coordinator.waitForResolution(id: id, timeoutSeconds: timeoutSeconds) else {
            return nil
        }
        return Self.execResolution(from: outcome)
    }

    static func scopeMatches(
        pending: ExecApprovalScope,
        resolver: ExecApprovalScope,
        ownerScope: UUID?,
        strictTenancy: Bool
    ) -> Bool {
        guard pending.conversationID == resolver.conversationID else { return false }
        return ToolConversationAccessPolicy.isOwnerAccessible(
            targetOwner: pending.ownerAccountID,
            ownerScope: ownerScope,
            strictTenancy: strictTenancy
        )
    }

    private static func execResolution(from outcome: ApprovalOutcome) -> ExecApprovalResolution {
        switch outcome.decision {
        case .allowAlways:
            return .approved(durable: true)
        case .allowOnce:
            return .approved(durable: false)
        case .deny, .timeout, .cancelled:
            return .denied(outcome.reason ?? "denied")
        }
    }

    /// Legacy first-token extraction without interpreter peeling.
    static func commandName(from command: String) -> String? {
        ExecApprovalGrantCommandName.commandName(from: command)
    }
}
