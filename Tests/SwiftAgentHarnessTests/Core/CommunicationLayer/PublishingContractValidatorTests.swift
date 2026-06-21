import Foundation
import Testing
@testable import SwiftAgentHarness

struct PublishingContractValidatorTests {
    private func runtimeLifecycleIssues(_ lifecycle: RuntimeLifecycleEventPayload) -> [String] {
        let payload = ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: lifecycle)
        return PublishingContractValidator.validateConversationEventPayload(payload)
    }

    @Test func conversationsRegistryPayloadAcceptsNilMetadata() {
        let id = UUID()
        let payload = ConversationsRegistryPayload(
            changes: [ConversationRegistryChange(kind: .updated, conversationID: id)],
            updatedAt: Date()
        )
        #expect(PublishingContractValidator.validateConversationsRegistryPayload(payload).isEmpty)
    }

    @Test func conversationsRegistryPayloadRequiresMetadataIdMatchesConversationID() {
        let cid = UUID()
        let wrong = UUID()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = iso.string(from: Date())
        let meta = ConversationMetadata(
            id: wrong.uuidString,
            modelName: "m",
            topic: nil,
            description: nil,
            messageCount: 0,
            createdAt: now,
            updatedAt: now
        )
        let payload = ConversationsRegistryPayload(
            changes: [ConversationRegistryChange(kind: .updated, conversationID: cid, metadata: meta)],
            updatedAt: Date()
        )
        let issues = PublishingContractValidator.validateConversationsRegistryPayload(payload)
        #expect(issues.contains { $0.contains("metadata.id must match") })
    }

    @Test func conversationsRegistryPayloadAcceptsAlignedMetadataWithModeFields() {
        let cid = UUID()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = iso.string(from: Date())
        let meta = ConversationMetadata(
            id: cid.uuidString,
            modelName: "m",
            topic: nil,
            description: nil,
            messageCount: 2,
            createdAt: now,
            updatedAt: now,
            interactionMode: .plan,
            parentConversationID: nil
        )
        let payload = ConversationsRegistryPayload(
            changes: [ConversationRegistryChange(kind: .updated, conversationID: cid, metadata: meta)],
            updatedAt: Date()
        )
        #expect(PublishingContractValidator.validateConversationsRegistryPayload(payload).isEmpty)
    }

    @Test func conversationStatePayloadRejectsAttachmentWithEmptyName() {
        let cid = UUID()
        let badAtt = ConversationAttachmentDescriptor(id: UUID(), kind: "file", name: "   ")
        let payload = ConversationStatePayload(
            conversationID: cid,
            exists: true,
            sessionSelected: false,
            attachmentsCatalog: [badAtt]
        )
        let issues = PublishingContractValidator.validateConversationStatePayload(payload)
        #expect(issues.contains { $0.contains("attachmentsCatalog") })
    }

    @Test func runtimeLifecycleToolCallStartedRequiresToolNameAndToolCallID() {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolCallStarted,
            conversationID: UUID(),
            runID: UUID(),
            toolName: "   ",
            toolCallID: "   ",
            source: "test.validator"
        )
        let issues = runtimeLifecycleIssues(payload)
        #expect(issues.contains { $0.contains("require non-empty toolName") })
        #expect(issues.contains { $0.contains("require non-empty toolCallID") })
    }

    @Test func runtimeLifecycleToolCallCompletedAcceptsProvenanceAndEnvironmentContract() {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolCallCompleted,
            conversationID: UUID(),
            runID: UUID(),
            toolName: "filesystem_write",
            toolCallID: "tool-123",
            argumentDigest: "arg-digest",
            argumentByteCount: 42,
            argumentRedaction: "digestOnly",
            resultDigest: "res-digest",
            resultByteCount: 81,
            resultRedaction: "digestOnly",
            resultTruncated: false,
            executionEnvironmentKind: "process",
            executionEnvironmentAdapterID: "default.process",
            executionIsolationLevel: "shared",
            source: "test.validator"
        )
        #expect(runtimeLifecycleIssues(payload).isEmpty)
    }

    @Test func runtimeLifecycleToolCallCompletedRejectsDigestWithoutRedaction() {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolCallCompleted,
            conversationID: UUID(),
            runID: UUID(),
            toolName: "filesystem_write",
            toolCallID: "tool-123",
            resultDigest: "res-digest",
            source: "test.validator"
        )
        let issues = runtimeLifecycleIssues(payload)
        #expect(issues.contains { $0.contains("resultDigest requires non-empty resultRedaction") })
    }

    @Test func runtimeLifecycleToolCallStartedAllowsMissingCompletionFields() {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolCallStarted,
            conversationID: UUID(),
            runID: UUID(),
            toolName: "filesystem_write",
            toolCallID: "tool-optional-completion",
            source: "test.validator"
        )
        #expect(runtimeLifecycleIssues(payload).isEmpty)
    }

    @Test func runtimeLifecycleTerminalEventsDoNotRequireToolCompletionMilestones() {
        let payload = RuntimeLifecycleEventPayload(
            name: .turnCompleted,
            conversationID: UUID(),
            runID: UUID(),
            terminalReason: ConversationRunTerminalReason(category: .naturalStop),
            source: "test.validator"
        )
        #expect(runtimeLifecycleIssues(payload).isEmpty)
    }

    @Test func runtimeLifecycleToolCompletionAnnouncedRequiresToolNameAndToolCallID() {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolCompletionAnnounced,
            conversationID: UUID(),
            runID: UUID(),
            toolName: nil,
            toolCallID: nil,
            source: "test.validator"
        )
        let issues = runtimeLifecycleIssues(payload)
        #expect(issues.contains { $0.contains("require non-empty toolName") })
        #expect(issues.contains { $0.contains("require non-empty toolCallID") })
    }

    @Test func runtimeLifecycleToolUsageSummaryRequiresCountAndNames() {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolUsageSummary,
            conversationID: UUID(),
            runID: UUID(),
            toolCount: 0,
            toolNames: [],
            source: "test.validator"
        )
        let issues = runtimeLifecycleIssues(payload)
        #expect(issues.contains { $0.contains("requires toolCount > 0") })
        #expect(issues.contains { $0.contains("requires non-empty toolNames") })
    }

    @Test func runtimeLifecycleRejectsEmptyOriginTrustLevelWhenPresent() {
        let payload = RuntimeLifecycleEventPayload(
            name: .turnStarted,
            conversationID: UUID(),
            runID: UUID(),
            originTrustLevel: "   ",
            source: "test.validator"
        )
        let issues = runtimeLifecycleIssues(payload)
        #expect(issues.contains { $0.contains("originTrustLevel must be non-empty") })
    }

    @Test func runtimeLifecycleRejectsNegativeUsageFields() {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolCompletionAnnounced,
            conversationID: UUID(),
            runID: UUID(),
            toolName: "delegate_test",
            toolCallID: "tool-usage-negative",
            usage: DelegateCompletionUsagePayload(promptTokens: -1, completionTokens: 2, totalTokens: 1, costUSD: -0.1),
            source: "test.validator"
        )
        let issues = runtimeLifecycleIssues(payload)
        #expect(issues.contains { $0.contains("usage.promptTokens must be >= 0") })
        #expect(issues.contains { $0.contains("usage.costUSD must be >= 0") })
    }

    @Test func subAgentLifecycleRejectsEmptyEventTrustLevelWhenPresent() {
        let parentID = UUID()
        let payload = SubAgentLifecycleTopicPayload(
            parentConversationID: parentID,
            entries: [
                SubAgentLifecycleEntryPayload(
                    lifecycleID: "lifecycle-1",
                    parentConversationID: parentID,
                    phase: .running,
                    eventTrustLevel: "   "
                )
            ]
        )
        let issues = PublishingContractValidator.validateSubAgentLifecycleTopicPayload(payload)
        #expect(issues.contains { $0.contains("eventTrustLevel must be non-empty") })
    }

    @Test func subAgentLifecycleRejectsNegativeCompletionUsageWhenPresent() {
        let parentID = UUID()
        let payload = SubAgentLifecycleTopicPayload(
            parentConversationID: parentID,
            entries: [
                SubAgentLifecycleEntryPayload(
                    lifecycleID: "lifecycle-usage-1",
                    parentConversationID: parentID,
                    phase: .done,
                    completionUsage: DelegateCompletionUsagePayload(promptTokens: 1, completionTokens: 1, totalTokens: 2, costUSD: -0.01)
                )
            ]
        )
        let issues = PublishingContractValidator.validateSubAgentLifecycleTopicPayload(payload)
        #expect(issues.contains { $0.contains("completionUsage.costUSD must be >= 0") })
    }
}
