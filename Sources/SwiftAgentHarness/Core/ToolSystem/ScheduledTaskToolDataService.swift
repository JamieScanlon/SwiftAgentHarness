import EasyJSON
import Foundation
import SwiftAgentKit

enum ScheduledTaskAccessError: Error, Equatable {
    case notFound
}

/// Owner and lineage-scoped data access for model-invoked schedule tools (DEF-133).
actor ScheduledTaskToolDataService {
    private let scheduler: TriggerSchedulerService
    private let catalog: any ConversationCatalogServicing
    private let tenancyPolicy: TenancyPolicySettings

    init(
        scheduler: TriggerSchedulerService,
        catalog: any ConversationCatalogServicing,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) {
        self.scheduler = scheduler
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

    func createTask(_ task: ScheduledTask) async throws -> ScheduledTask {
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
        var stamped = task
        stamped.ownerAccountID = ownerScope
        stamped.createdByConversationID = scope.selfID
        if let rawTarget = stamped.conversationID, let targetID = UUID(uuidString: rawTarget) {
            _ = try await assertToolAccessible(conversationID: targetID)
        } else {
            stamped.conversationID = scope.selfID.uuidString
        }
        return try await scheduler.createTask(stamped)
    }

    func deleteTask(id: String) async throws -> Bool {
        guard try await assertTaskAccessible(id: id) != nil else {
            return false
        }
        return try await scheduler.deleteTask(id: id)
    }

    func fireNow(id: String) async throws -> TriggerActivationResult {
        guard try await assertTaskAccessible(id: id) != nil else {
            throw ScheduledTaskAccessError.notFound
        }
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
        guard let originID = task.createdByConversationID,
              let originConversation = await unscopedConversation(id: originID) else {
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
