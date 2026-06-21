import Foundation
import SwiftAgentKit
import SwiftAgentKitACP

/// Stable forwarding delegate installed at ACP client boot; inner delegate swaps per pool invocation.
final class SubAgentACPClientDelegateBox: ACPClientDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var current: any ACPClientDelegate

    init(defaultDelegate: any ACPClientDelegate = DefaultACPClientDelegate(autoApprovePermissions: false)) {
        self.current = defaultDelegate
    }

    func setDelegate(_ delegate: any ACPClientDelegate) {
        lock.lock()
        current = delegate
        lock.unlock()
    }

    func restoreDefault(_ delegate: any ACPClientDelegate) {
        setDelegate(delegate)
    }

    private func lockedCurrent() -> any ACPClientDelegate {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func readTextFile(_ request: ACPReadTextFileRequest) async throws -> ACPReadTextFileResponse {
        try await lockedCurrent().readTextFile(request)
    }

    func writeTextFile(_ request: ACPWriteTextFileRequest) async throws -> ACPWriteTextFileResponse {
        try await lockedCurrent().writeTextFile(request)
    }

    func requestPermission(_ request: ACPRequestPermissionRequest) async throws -> ACPRequestPermissionResponse {
        try await lockedCurrent().requestPermission(request)
    }

    func createTerminal(_ request: ACPCreateTerminalRequest) async throws -> ACPCreateTerminalResponse {
        try await lockedCurrent().createTerminal(request)
    }

    func terminalOutput(_ request: ACPTerminalOutputRequest) async throws -> ACPTerminalOutputResponse {
        try await lockedCurrent().terminalOutput(request)
    }

    func waitForTerminalExit(_ request: ACPWaitForExitRequest) async throws -> ACPWaitForExitResponse {
        try await lockedCurrent().waitForTerminalExit(request)
    }

    func killTerminal(_ request: ACPKillTerminalRequest) async throws -> ACPKillTerminalResponse {
        try await lockedCurrent().killTerminal(request)
    }

    func releaseTerminal(_ request: ACPReleaseTerminalRequest) async throws -> ACPReleaseTerminalResponse {
        try await lockedCurrent().releaseTerminal(request)
    }
}
