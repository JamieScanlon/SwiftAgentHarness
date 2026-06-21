import Foundation

extension SlashCommandDispatchService {
    func runSlashApproveCommand(conversationID: UUID, args: String) async throws -> ChatStreamResponse {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Usage: /approve <approval-id> [durable]"
            )
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let approvalID = String(parts[0])
        let durable = parts.count > 1 && parts[1].lowercased().contains("durable")
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
                ? "Exec approval \(approvalID) granted (durable)."
                : "Exec approval \(approvalID) granted."
        case .denied(let reason):
            message = "Exec approval \(approvalID) denied: \(reason)"
        }
        return try await deliverSyntheticSlashAssistantResponse(
            conversationID: conversationID,
            content: message
        )
    }
}
