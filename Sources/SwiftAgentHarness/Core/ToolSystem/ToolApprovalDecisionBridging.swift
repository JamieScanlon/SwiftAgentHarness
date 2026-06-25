import Foundation

extension ToolApprovalResolutionStatus {
    /// Maps a unified decision onto the tool-path resolution status. The richer
    /// `allowOnce` / `allowAlways` distinction collapses to `approved` here; the
    /// persistence side of `allowAlways` is handled separately by the permission
    /// rule store.
    init(decision: ApprovalDecision) {
        switch decision {
        case .allowOnce, .allowAlways:
            self = .approved
        case .deny, .timeout, .cancelled:
            self = .denied
        }
    }
}

extension ApprovalDecision {
    /// Best-effort projection of a tool-path status onto the unified vocabulary.
    /// `pending` has no decision equivalent and yields `nil`.
    init?(toolStatus: ToolApprovalResolutionStatus) {
        switch toolStatus {
        case .approved:
            self = .allowOnce
        case .denied:
            self = .deny
        case .pending:
            return nil
        }
    }
}
