import Foundation

extension SlashCommandDispatchService {
    func runSlashApproveCommand(conversationID: UUID, args: String) async throws -> ChatStreamResponse {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Usage: /approve <approval-id> [always]"
            )
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let approvalID = String(parts[0])
        // Accept the unified `allow-always` aliases (`always`, `durable`, ...).
        let durable = parts.count > 1 && ApprovalDecision.fromToken(String(parts[1])) == .allowAlways
        let store = ExecApprovalStore.shared
        guard let resolution = await store.resolve(id: approvalID, approved: true, durable: durable) else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "No pending exec approval found for id \(approvalID)."
            )
        }
        let message: String
        switch resolution {
        case .approved(let isDurable):
            message = isDurable
                ? "Exec approval \(approvalID) granted (always)."
                : "Exec approval \(approvalID) granted."
        case .denied(let reason):
            message = "Exec approval \(approvalID) denied: \(reason)"
        }
        return try await deliverSyntheticSlashAssistantResponse(
            conversationID: conversationID,
            content: message
        )
    }

    func runSlashDenyCommand(conversationID: UUID, args: String) async throws -> ChatStreamResponse {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Usage: /deny <approval-id> [reason]"
            )
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let approvalID = String(parts[0])
        let reason = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : "denied via slash command"
        let store = ExecApprovalStore.shared
        guard let resolution = await store.resolve(id: approvalID, approved: false, reason: reason) else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "No pending exec approval found for id \(approvalID)."
            )
        }
        let message: String
        switch resolution {
        case .denied(let denyReason):
            message = "Exec approval \(approvalID) denied: \(denyReason)"
        case .approved:
            message = "Exec approval \(approvalID) was already approved."
        }
        return try await deliverSyntheticSlashAssistantResponse(
            conversationID: conversationID,
            content: message
        )
    }
}
