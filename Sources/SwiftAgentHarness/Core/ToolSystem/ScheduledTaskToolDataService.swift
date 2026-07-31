import EasyJSON
import Foundation
import SwiftAgentKit

enum ScheduledTaskAccessError: Error, Equatable {
    case notFound
}

/// Owner and lineage-scoped data access for model-invoked schedule tools (DEF-133).
actor ScheduledTaskToolDataService {
    private let scheduler: TriggerSchedulerService
    private let registration: TriggerRegistrationService
    private let catalog: any ConversationCatalogServicing
    private let tenancyPolicy: TenancyPolicySettings

    init(
        scheduler: TriggerSchedulerService,
        registration: TriggerRegistrationService,
        catalog: any ConversationCatalogServicing,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) {
        self.scheduler = scheduler
        self.registration = registration
        self.catalog = catalog
        self.tenancyPolicy = tenancyPolicy
    }

    func listAccessibleTasks() async throws -> [ScheduledTask] {
        let all = try await scheduler.listTasks()
        var accessible: [ScheduledTask] = []
        for task in all where await isTaskAccessible(task) {
            accessible.append(task)
        }
        return accessible
    }

    /// Resolve the caller's registration authority from ambient session state.
    ///
    /// The identity is resolved here, at the client boundary, from state a model cannot forge — the
    /// registration spec carries no identity fields at all. A tool call from a sub-agent resolves to
    /// `.subAgent`, which the registration policy denies by default regardless of tool visibility.
    func currentToolAuthority() async throws -> RegistrationAuthority {
        guard let scope = ConversationScope.current else {
            throw ScheduledTaskAccessError.notFound
        }
        let callerConversation = try await assertToolAccessible(conversationID: scope.selfID)
        let ownerScope = ToolConversationAccessPolicy.resolveOwnerScope(
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations,
            authenticatedOwnerAccountID: APISessionContext.authenticatedOwnerAccountID,
            callerConversation: callerConversation,
            registryOwnerAccountID: await catalog.registryOwnerAccountID()
        )
        let creator: RegistrationCreator = scope.parentID == nil
            ? .agent(conversationID: scope.selfID, ownerAccountID: ownerScope)
            : .subAgent(conversationID: scope.selfID, lineageRoot: scope.rootID, ownerAccountID: ownerScope)
        return RegistrationAuthority(
            creator: creator,
            surface: .tool,
            origin: Self.originRef(for: callerConversation)
        )
    }

    /// Where a fire should announce back to.
    ///
    /// When the caller's conversation is itself hosting a channel trigger, the original chat is
    /// recoverable from the host fingerprint — so a task registered from a Telegram thread can
    /// answer into that thread months later, with no live session at fire time. Otherwise the origin
    /// is the in-harness conversation, and threaded routing delivers the answer by construction.
    private static func originRef(for conversation: ModelConversation) -> TriggerOriginRef {
        guard let hostTrigger = TriggerHostConversationMetadata.triggerFromFingerprint(conversation.metadata),
              hostTrigger.source == .channel else {
            return TriggerOriginRef(conversationID: conversation.id)
        }
        return TriggerOriginRef(
            channel: hostTrigger.sourceMetadata["channel"],
            chatID: hostTrigger.sourceMetadata["chatId"],
            threadID: hostTrigger.sourceMetadata["threadId"],
            accountID: hostTrigger.sourceMetadata["accountId"],
            conversationID: conversation.id
        )
    }

    func createTask(_ spec: ScheduleRegistrationSpec) async throws -> ScheduledTask {
        guard let scope = ConversationScope.current else {
            throw ScheduledTaskAccessError.notFound
        }
        let authority = try await currentToolAuthority()
        var scoped = spec
        if let rawTarget = scoped.conversationID {
            // A malformed target must not silently retarget the task at the caller's own
            // conversation — that reads as success while doing something the caller did not ask for.
            guard let targetID = UUID(uuidString: rawTarget) else {
                throw ScheduledTaskAccessError.notFound
            }
            _ = try await assertToolAccessible(conversationID: targetID)
        } else {
            scoped.conversationID = scope.selfID.uuidString
        }
        return try registration.registerSchedule(scoped, authority: authority)
    }

    func updateTask(id: String, _ mutate: @Sendable (inout ScheduleRegistrationSpec) -> Void) async throws -> ScheduledTask {
        guard try await assertTaskAccessible(id: id) != nil else {
            throw ScheduledTaskAccessError.notFound
        }
        let authority = try await currentToolAuthority()
        return try registration.updateSchedule(id: id, authority: authority, mutate)
    }

    func setTaskEnabled(id: String, enabled: Bool) async throws -> ScheduledTask {
        guard try await assertTaskAccessible(id: id) != nil else {
            throw ScheduledTaskAccessError.notFound
        }
        let authority = try await currentToolAuthority()
        return try registration.setScheduleEnabled(id: id, enabled: enabled, authority: authority)
    }

    // MARK: - Webhook routes
    //
    // Webhook operations live here rather than in a second data service so there is exactly one
    // authority-resolution and tenancy path for every trigger tool. (The type name is now narrower
    // than its job — `TriggerToolDataService` would be accurate; the rename is deferred.)

    func subscribeWebhook(_ spec: WebhookRegistrationSpec) async throws -> TriggerRegistrationService.WebhookRegistrationResult {
        let authority = try await currentToolAuthority()
        // `subscribe` never overwrites; use `update` to change a live route.
        return try registration.registerWebhook(spec, authority: authority, allowOverwrite: false)
    }

    func updateWebhook(name: String, _ mutate: @Sendable (inout WebhookRegistrationSpec) -> Void) async throws -> WebhookRoute {
        let authority = try await currentToolAuthority()
        return try registration.updateWebhook(name: name, authority: authority, mutate).route
    }

    func setWebhookEnabled(name: String, enabled: Bool) async throws -> WebhookRoute {
        let authority = try await currentToolAuthority()
        return try registration.setWebhookEnabled(name: name, enabled: enabled, authority: authority)
    }

    func deleteWebhook(name: String) async throws -> Bool {
        let authority = try await currentToolAuthority()
        return try registration.deleteWebhook(name: name, authority: authority)
    }

    func listWebhooks() async throws -> [WebhookRoute] {
        let authority = try await currentToolAuthority()
        return try registration.listWebhooks(authority: authority)
    }

    func webhookRoute(named name: String) async throws -> WebhookRoute? {
        let normalized = WebhookRouteNaming.normalize(name)
        return try await listWebhooks().first { $0.name == normalized }
    }

    func deleteTask(id: String) async throws -> Bool {
        guard try await assertTaskAccessible(id: id) != nil else {
            return false
        }
        let authority = try await currentToolAuthority()
        return try registration.deleteSchedule(id: id, authority: authority)
    }

    func fireNow(id: String) async throws -> TriggerActivationResult {
        guard try await assertTaskAccessible(id: id) != nil else {
            throw ScheduledTaskAccessError.notFound
        }
        // Lineage visibility is not authority to fire. A `system` entry is listable but not
        // invokable from the tools, and a creator denied registration is denied on-demand fires too.
        let authority = try await currentToolAuthority()
        try registration.assertMayFire(id: id, authority: authority)
        return try await scheduler.fireNow(id: id)
    }

    private struct CallerAccessContext: Sendable {
        let scope: ConversationScope?
        let ownerScope: UUID?
        let callerLineageRoot: UUID?
    }

    private func unscopedConversation(id: UUID) async -> ModelConversation? {
        await catalog.getConversation(id: id)
    }

    private func callerAccessContext() async -> CallerAccessContext {
        let scope = ConversationScope.current
        let callerConversation: ModelConversation?
        if let callerID = scope?.selfID {
            callerConversation = await unscopedConversation(id: callerID)
        } else {
            callerConversation = nil
        }
        let ownerScope = ToolConversationAccessPolicy.resolveOwnerScope(
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations,
            authenticatedOwnerAccountID: APISessionContext.authenticatedOwnerAccountID,
            callerConversation: callerConversation,
            registryOwnerAccountID: await catalog.registryOwnerAccountID()
        )
        let callerLineageRoot: UUID?
        if let callerConversation {
            callerLineageRoot = await lineageRoot(for: callerConversation)
        } else {
            callerLineageRoot = nil
        }
        return CallerAccessContext(
            scope: scope,
            ownerScope: ownerScope,
            callerLineageRoot: callerLineageRoot
        )
    }

    private func lineageRoot(for conversation: ModelConversation) async -> UUID {
        await ToolConversationAccessPolicy.lineageRoot(for: conversation) { id in
            await self.unscopedConversation(id: id)
        }
    }

    private func isTaskAccessible(_ task: ScheduledTask) async -> Bool {
        // Rows registered by a non-conversational owner surface — the installer, a local file drop,
        // a CLI/HTTP client — have no creating conversation to run the lineage check against. They
        // are scoped by owner alone. Before the registration layer these fell through the
        // `createdByConversationID == nil` guard below and became invisible *and* undeletable;
        // system entries are meant to be listed but immutable from the tool, which the registration
        // service enforces on the mutation side.
        guard let originID = task.createdByConversationID else {
            let context = await callerAccessContext()
            return ToolConversationAccessPolicy.isOwnerAccessible(
                targetOwner: task.ownerAccountID,
                ownerScope: context.ownerScope,
                strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations
            )
        }
        guard let originConversation = await unscopedConversation(id: originID) else {
            return false
        }
        let context = await callerAccessContext()
        guard ToolConversationAccessPolicy.isOwnerAccessible(
            targetOwner: task.ownerAccountID,
            ownerScope: context.ownerScope,
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations
        ) else {
            return false
        }
        let originLineageRoot = await lineageRoot(for: originConversation)
        guard ToolConversationAccessPolicy.isConversationAccessible(
            target: originConversation,
            callerScope: context.scope,
            ownerScope: context.ownerScope,
            callerLineageRoot: context.callerLineageRoot,
            targetLineageRoot: originLineageRoot,
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations
        ) else {
            return false
        }
        if let rawTarget = task.conversationID, let targetID = UUID(uuidString: rawTarget),
           let targetConversation = await unscopedConversation(id: targetID) {
            let targetLineageRoot = await lineageRoot(for: targetConversation)
            return ToolConversationAccessPolicy.isConversationAccessible(
                target: targetConversation,
                callerScope: context.scope,
                ownerScope: context.ownerScope,
                callerLineageRoot: context.callerLineageRoot,
                targetLineageRoot: targetLineageRoot,
                strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations
            )
        }
        return true
    }

    @discardableResult
    private func assertTaskAccessible(id: String) async throws -> ScheduledTask? {
        guard let task = try await scheduler.listTasks().first(where: { $0.id == id }) else {
            return nil
        }
        guard await isTaskAccessible(task) else {
            return nil
        }
        return task
    }

    private func assertToolAccessible(conversationID: UUID) async throws -> ModelConversation {
        guard let conversation = await unscopedConversation(id: conversationID) else {
            throw ScheduledTaskAccessError.notFound
        }
        let context = await callerAccessContext()
        let targetLineageRoot = await lineageRoot(for: conversation)
        guard ToolConversationAccessPolicy.isConversationAccessible(
            target: conversation,
            callerScope: context.scope,
            ownerScope: context.ownerScope,
            callerLineageRoot: context.callerLineageRoot,
            targetLineageRoot: targetLineageRoot,
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations
        ) else {
            throw ScheduledTaskAccessError.notFound
        }
        return conversation
    }
}
