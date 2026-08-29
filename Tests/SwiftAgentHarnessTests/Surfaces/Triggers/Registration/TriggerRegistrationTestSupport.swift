import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

/// Fixture helpers for the trigger registration control plane.
///
/// Tests deliberately go through `TriggerRegistrationService` rather than reaching the store —
/// `ScheduledTaskStore.upsert` accepts only a `ValidatedScheduledTask`, and that is the point. These
/// helpers keep the fixture noise down without reopening the chokepoint.
enum TriggerRegistrationTestSupport {
    static func service(
        store: ScheduledTaskStore,
        sessionStore: SessionScopedScheduledTaskStore = SessionScopedScheduledTaskStore(),
        policy: RegistrationPolicy = .default,
        label: String = "test"
    ) -> TriggerRegistrationService {
        TriggerRegistrationService(
            store: store,
            sessionStore: sessionStore,
            auditLog: TriggerAuditLog(logger: Logger(label: label)),
            policy: policy,
            logger: Logger(label: label)
        )
    }

    /// Authority for a main-agent tool call from `conversation`.
    static func agentAuthority(conversation: UUID, owner: UUID? = nil) -> RegistrationAuthority {
        RegistrationAuthority(
            creator: .agent(conversationID: conversation, ownerAccountID: owner),
            surface: .tool,
            origin: TriggerOriginRef(conversationID: conversation)
        )
    }

    /// Round-trip an already-shaped fixture task through the real validator.
    ///
    /// Defaults to installer authority so fixtures may carry `permanent` / `system` trust; pass an
    /// explicit authority when the test cares about creator attribution.
    @discardableResult
    static func register(
        _ task: ScheduledTask,
        into store: ScheduledTaskStore,
        sessionStore: SessionScopedScheduledTaskStore = SessionScopedScheduledTaskStore(),
        authority: RegistrationAuthority = .installer,
        policy: RegistrationPolicy = .default
    ) throws -> ScheduledTask {
        try service(store: store, sessionStore: sessionStore, policy: policy)
            .registerSchedule(ScheduleRegistrationSpec(existing: task), authority: authority)
    }
}
