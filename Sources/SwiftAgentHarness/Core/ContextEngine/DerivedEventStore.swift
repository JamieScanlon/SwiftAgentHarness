import Foundation
import SwiftAgentKit
import SwiftData

/// Persistence seam for **derived** conversation artifacts (harness `derived_journal` transcript rows). Append-only;
/// raw ``message_appended`` markers use ``ConversationEventLogService``.
protocol DerivedEventStore: Sendable {
    func appendContextCompactionCheckpoint(
        conversationID: UUID,
        rawMiddleMessageIDs: [UUID],
        compactedMiddleMessages: [Message],
        kind: ContextCompactionCheckpointKind,
        config: ContextCompactionConfiguration,
        strategyRawValue: String?,
        cachePolicyFingerprint: String?,
        expectedDerivedSequence: Int?
    ) throws

    func appendTurnSummaryEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws

    func appendTurnFinalizedEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws

    func appendCompactionAppliedEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws

    func appendCheckpointInvalidation(
        conversationID: UUID,
        kinds: [String],
        expectedDerivedSequence: Int?
    ) throws

    func appendMemoryInjectionSnapshotCheckpoint(
        conversationID: UUID,
        wire: MemoryInjectionSnapshotCheckpointWire,
        expectedDerivedSequence: Int?
    ) throws

    func appendToolResultTrimCheckpoint(
        conversationID: UUID,
        wire: ToolResultTrimCheckpointWire,
        expectedDerivedSequence: Int?
    ) throws

    func appendSystemPromptAssemblyCheckpoint(
        conversationID: UUID,
        wire: SystemPromptAssemblyCheckpointWire,
        expectedDerivedSequence: Int?
    ) throws

    func appendAttachmentProjectionCheckpoint(
        conversationID: UUID,
        wire: AttachmentProjectionCheckpointWire,
        expectedDerivedSequence: Int?
    ) throws

    func appendRunLifecycleEvent(
        conversationID: UUID,
        runID: UUID,
        status: ConversationRunWireStatus,
        terminalReason: ConversationRunTerminalReason?,
        markerKind: String?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws

    func appendToolAuditLifecycleEvent(
        conversationID: UUID,
        payload: ToolAuditLifecycleEventPayload,
        expectedDerivedSequence: Int?
    ) throws

    func appendToolUsageSummaryEvent(
        conversationID: UUID,
        payload: ToolUsageSummaryEventPayload,
        expectedDerivedSequence: Int?
    ) throws

    func appendCompletionAnnounceEvent(
        conversationID: UUID,
        payload: CompletionAnnounceEventPayload,
        expectedDerivedSequence: Int?
    ) throws

    /// Tail of the derived stream before the next append (`0` when empty).
    func latestDerivedStreamSequence(conversationID: UUID) -> Int
}

/// Deprecated name; use ``RoutingDerivedEventStore``.
typealias SwiftDataDerivedEventStore = RoutingDerivedEventStore

extension ConversationEventLogService {
    init(container: ModelContainer) {
        self = Self.forTesting(container: container)
    }

    static func forTesting(container: ModelContainer) -> ConversationEventLogService {
        let manager = ConversationManager(container: container)
        manager.setHarnessSessionPersistenceOverride(InMemoryHarnessSessionPersistence())
        return ConversationEventLogService(harness: manager.harnessSessionPersistence)
    }
}

