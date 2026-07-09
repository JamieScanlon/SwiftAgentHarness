import Foundation

public protocol ExecApprovalDenialHygieneHandling: Sendable {
    func poisonPriorMatchingToolResults(
        conversationID: UUID,
        deniedCommand: String,
        excludingToolCallId: String?
    ) async
}

public struct NoOpExecApprovalDenialHygieneHandler: ExecApprovalDenialHygieneHandling {
    public static let shared = NoOpExecApprovalDenialHygieneHandler()

    public init() {}

    public func poisonPriorMatchingToolResults(
        conversationID: UUID,
        deniedCommand: String,
        excludingToolCallId: String?
    ) async {}
}
