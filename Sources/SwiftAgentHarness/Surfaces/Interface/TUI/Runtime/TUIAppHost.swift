import Foundation

/// The seam between the terminal surface and whatever is driving it.
///
/// ``TUIApp`` owns rendering and input; it deliberately knows nothing about transports,
/// conversations or approval stores. Everything that leaves the surface leaves through
/// this protocol, and the only thing that crosses it is the portable inbound envelope
/// (``ComposerSubmission``) plus a handful of intents.
///
/// Do **not** classify slash commands or directives before calling ``submit(_:)``.
/// `SlashCommandDispatchService.processControlInputBoundary` already runs inside the
/// send path with the conversation-scoped registry and real owner authorization;
/// classifying in the surface duplicates it with weaker authorization.
public protocol TUIAppHost: AnyObject, Sendable {
    /// Sends an inbound envelope. Returns a response when the control-input boundary
    /// short-circuited the turn (`/help`, `/model`, …) so the surface can render it.
    func submit(_ submission: ComposerSubmission) async throws -> ChatStreamResponse?

    /// Cancels the in-flight turn on the runtime, not merely the local stream.
    func cancelTurn() async

    /// The user asked to leave. Hosts typically call ``TUIApp/stop()`` and exit.
    func quit() async

    /// Reports an approval decision collected from an overlay. `actionID` is the button
    /// id, which is already an `ApprovalDecision` token.
    func resolveApproval(approvalID: String, actionID: String) async

    /// Conversation-scoped command registry for autocomplete. Returning `nil` falls back
    /// to the built-in set, which omits conversation-scoped commands and skills.
    func slashCommandRegistry() async -> SlashCommandRegistry?
}

public extension TUIAppHost {
    func cancelTurn() async {}
    func quit() async {}
    func resolveApproval(approvalID: String, actionID: String) async {}
    func slashCommandRegistry() async -> SlashCommandRegistry? { nil }
}

/// A host assembled from closures.
///
/// The zero-coupling option: an out-of-process client (or a test) supplies exactly the
/// behaviours it needs without binding to any runtime type.
public final class ClosureTUIAppHost: TUIAppHost {
    private let onSubmit: @Sendable (ComposerSubmission) async throws -> ChatStreamResponse?
    private let onCancel: @Sendable () async -> Void
    private let onQuit: @Sendable () async -> Void
    private let onResolveApproval: @Sendable (String, String) async -> Void
    private let onRegistry: @Sendable () async -> SlashCommandRegistry?

    public init(
        submit: @escaping @Sendable (ComposerSubmission) async throws -> ChatStreamResponse?,
        cancelTurn: @escaping @Sendable () async -> Void = {},
        quit: @escaping @Sendable () async -> Void = {},
        resolveApproval: @escaping @Sendable (String, String) async -> Void = { _, _ in },
        slashCommandRegistry: @escaping @Sendable () async -> SlashCommandRegistry? = { nil }
    ) {
        self.onSubmit = submit
        self.onCancel = cancelTurn
        self.onQuit = quit
        self.onResolveApproval = resolveApproval
        self.onRegistry = slashCommandRegistry
    }

    public func submit(_ submission: ComposerSubmission) async throws -> ChatStreamResponse? {
        try await onSubmit(submission)
    }

    public func cancelTurn() async { await onCancel() }
    public func quit() async { await onQuit() }

    public func resolveApproval(approvalID: String, actionID: String) async {
        await onResolveApproval(approvalID, actionID)
    }

    public func slashCommandRegistry() async -> SlashCommandRegistry? {
        await onRegistry()
    }
}

/// In-process host bound to the agent runtime.
///
/// Sends raw composer text — the control-input boundary runs inside
/// `sendMessageAndStreamResponse`, so the surface must not pre-classify — and resolves
/// approvals through the documented surface-side seam, ``ExecApprovalInbound``.
public final class RuntimeTUIHost: TUIAppHost {
    private let session: AgentRuntimeSessionService
    private let conversationID: UUID
    private let harness: AgentHarnessConfiguration
    private let approvalScope: ExecApprovalScope
    private let strictTenancy: Bool
    private let ownerScope: UUID?
    private let onQuitRequested: @Sendable () async -> Void

    /// - Parameters:
    ///   - ownerAccountID: Owner of `conversationID`. Required under strict tenancy;
    ///     `SlashCommandDispatchService.execApprovalResolverContext(conversationID:)`
    ///     computes the same triple if the host has that service to hand.
    public init(
        session: AgentRuntimeSessionService,
        conversationID: UUID,
        ownerAccountID: UUID? = nil,
        strictTenancy: Bool = false,
        ownerScope: UUID? = nil,
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.default,
        onQuitRequested: @escaping @Sendable () async -> Void = {}
    ) {
        self.session = session
        self.conversationID = conversationID
        self.harness = harness
        self.approvalScope = ExecApprovalScope(conversationID: conversationID, ownerAccountID: ownerAccountID)
        self.strictTenancy = strictTenancy
        self.ownerScope = ownerScope
        self.onQuitRequested = onQuitRequested
    }

    public func submit(_ submission: ComposerSubmission) async throws -> ChatStreamResponse? {
        let runtimeConfiguration = submission.runtimeTurnConfiguration(
            base: AgentRuntimeTurnConfiguration(),
            harness: harness
        )
        return try await session.sendMessageAndStreamResponse(
            submission.text,
            images: [],
            conversationID: conversationID,
            configuration: HarnessRuntimeSession.Configuration(runtimeConfiguration: runtimeConfiguration)
        )
    }

    public func cancelTurn() async {
        await session.cancelGeneration(for: conversationID)
    }

    public func quit() async {
        await onQuitRequested()
    }

    public func resolveApproval(approvalID: String, actionID: String) async {
        await ExecApprovalInbound.resolve(
            approvalID: approvalID,
            actionID: actionID,
            scope: approvalScope,
            strictTenancy: strictTenancy,
            ownerScope: ownerScope
        )
    }
}
