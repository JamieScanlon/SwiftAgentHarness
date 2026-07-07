import Testing
@testable import SwiftAgentHarness

@Suite("Sandbox exec escalation classification")
struct SandboxExecEscalationTests {
    @Test("exit 126 is a sandbox exec denial")
    func exit126IsDenial() {
        #expect(SandboxBackendError.nonZeroExit(126, "").isSandboxExecDenial)
    }

    @Test("other exit codes are not sandbox exec denials")
    func otherExitCodesAreNotDenial() {
        #expect(SandboxBackendError.nonZeroExit(1, "fail").isSandboxExecDenial == false)
        #expect(SandboxBackendError.nonZeroExit(127, "not found").isSandboxExecDenial == false)
        #expect(SandboxBackendError.commandFailed("denied").isSandboxExecDenial == false)
        #expect(SandboxBackendError.emptyCommand.isSandboxExecDenial == false)
    }
}
