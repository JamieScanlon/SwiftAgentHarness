import Foundation

extension SandboxBackendError {
    /// True when the sandbox refused to execute the command (bash exit 126).
    public var isSandboxExecDenial: Bool {
        if case .nonZeroExit(126, _) = self { return true }
        return false
    }
}
