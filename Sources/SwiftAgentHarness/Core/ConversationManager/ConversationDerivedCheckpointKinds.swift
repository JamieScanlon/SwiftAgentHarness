import Foundation

enum ConversationDerivedCheckpointKinds {
    static let allInvalidationKinds: [String] = [
        HarnessCheckpointInvalidationKind.contextCompaction,
        HarnessCheckpointInvalidationKind.turnSummaryEvent,
        HarnessCheckpointInvalidationKind.memoryInjectionSnapshot,
        HarnessCheckpointInvalidationKind.toolResultTrim,
        HarnessCheckpointInvalidationKind.systemPromptAssembly,
        HarnessCheckpointInvalidationKind.attachmentProjection,
    ]
}
