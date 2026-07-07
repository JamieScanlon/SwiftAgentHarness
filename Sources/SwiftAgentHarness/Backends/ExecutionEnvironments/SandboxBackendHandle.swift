import Foundation

public typealias SandboxBackendID = String

public enum SandboxStdinMode: String, Sendable, Codable, Equatable {
    case none
    case pipe
    case inherit
}

public struct SandboxBackendExecSpec: Sendable, Equatable {
    public let argv: [String]
    public let env: [String: String]
    public let cwd: String?
    public let usePty: Bool
    public let stdinMode: SandboxStdinMode
    public let inheritHostEnvironment: Bool

    public init(
        argv: [String],
        env: [String: String] = [:],
        cwd: String? = nil,
        usePty: Bool = false,
        stdinMode: SandboxStdinMode = .none,
        inheritHostEnvironment: Bool = true
    ) {
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.usePty = usePty
        self.stdinMode = stdinMode
        self.inheritHostEnvironment = inheritHostEnvironment
    }
}

public struct SandboxBuildExecSpecParams: Sendable {
    public let command: String
    public let workdir: String?
    public let env: [String: String]
    public let usePty: Bool

    public init(command: String, workdir: String? = nil, env: [String: String] = [:], usePty: Bool = false) {
        self.command = command
        self.workdir = workdir
        self.env = env
        self.usePty = usePty
    }
}

public struct SandboxFinalizeExecParams: Sendable {
    public let status: SandboxExecStatus
    public let exitCode: Int32?
    public let timedOut: Bool
    public let token: SendableValueBox?

    public init(status: SandboxExecStatus, exitCode: Int32?, timedOut: Bool, token: SendableValueBox? = nil) {
        self.status = status
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.token = token
    }
}

public enum SandboxExecStatus: String, Sendable, Codable, Equatable {
    case completed
    case failed
}

public struct SandboxBackendCommandParams: Sendable {
    public let script: String
    public let args: [String]
    public let env: [String: String]
    public let workdir: String?
    public let stdin: Data?

    public init(
        script: String,
        args: [String] = [],
        env: [String: String] = [:],
        workdir: String? = nil,
        stdin: Data? = nil
    ) {
        self.script = script
        self.args = args
        self.env = env
        self.workdir = workdir
        self.stdin = stdin
    }
}

public struct SandboxBackendCommandResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let code: Int32

    public init(stdout: Data, stderr: Data, code: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.code = code
    }
}

public struct SandboxBackendCapabilities: Sendable, Equatable, Codable {
    public var browser: Bool
    public var bindMounts: Bool
    public var persistentRuntime: Bool

    public init(browser: Bool = false, bindMounts: Bool = false, persistentRuntime: Bool = false) {
        self.browser = browser
        self.bindMounts = bindMounts
        self.persistentRuntime = persistentRuntime
    }
}

public struct SandboxFsBridgeContext: Sendable {
    public let workspaceRoot: String
    public let agentWorkspaceDir: String
    public let memoryDirectory: String?

    public init(workspaceRoot: String, agentWorkspaceDir: String, memoryDirectory: String? = nil) {
        self.workspaceRoot = workspaceRoot
        self.agentWorkspaceDir = agentWorkspaceDir
        self.memoryDirectory = memoryDirectory
    }
}

public struct SandboxFsStat: Sendable, Equatable {
    public let isDirectory: Bool
    public let size: Int64
    public let exists: Bool

    public init(isDirectory: Bool, size: Int64, exists: Bool) {
        self.isDirectory = isDirectory
        self.size = size
        self.exists = exists
    }

    static func parse(from result: SandboxBackendCommandResult) -> SandboxFsStat {
        guard result.code == 0,
              let text = String(data: result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return SandboxFsStat(isDirectory: false, size: 0, exists: false)
        }
        let parts = text.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let kind = Int(parts[0]),
              let size = Int64(parts[1])
        else {
            return SandboxFsStat(isDirectory: false, size: 0, exists: false)
        }
        return SandboxFsStat(isDirectory: kind == 1, size: size, exists: true)
    }
}

public struct SandboxFsBridgeParams: Sendable {
    public let context: SandboxFsBridgeContext
    public let memoryWriteOnly: Bool

    public init(context: SandboxFsBridgeContext, memoryWriteOnly: Bool = false) {
        self.context = context
        self.memoryWriteOnly = memoryWriteOnly
    }
}

public protocol SandboxFsBridge: Sendable {
    func stat(path: String) async throws -> SandboxFsStat
    func readFile(path: String) async throws -> Data
    func writeFile(path: String, content: Data) async throws
    func mkdir(path: String) async throws
    func rename(from: String, to: String) async throws
    func remove(path: String) async throws
}

public protocol SandboxBackendHandle: Sendable {
    var id: SandboxBackendID { get }
    var runtimeId: String { get }
    var runtimeLabel: String { get }
    var workdir: String { get }
    var env: [String: String]? { get }
    var configLabel: String? { get }
    var configLabelKind: String? { get }
    var capabilities: SandboxBackendCapabilities? { get }

    func buildExecSpec(params: SandboxBuildExecSpecParams) async throws -> SandboxBackendExecSpec
    func finalizeExec(params: SandboxFinalizeExecParams) async throws
    func runShellCommand(params: SandboxBackendCommandParams) async throws -> SandboxBackendCommandResult
    func createFsBridge(params: SandboxFsBridgeParams) -> (any SandboxFsBridge)?
}

public extension SandboxBackendHandle {
    func finalizeExec(params: SandboxFinalizeExecParams) async throws {}
    func createFsBridge(params: SandboxFsBridgeParams) -> (any SandboxFsBridge)? { nil }
}

public struct SendableValueBox: @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
}

public enum SandboxBackendError: Error, Equatable, Sendable {
    case notRegistered(String)
    case duplicateRegistration(String)
    case emptyCommand
    case sandboxUnavailable
    case nonZeroExit(Int32, String)
    case pathEscapes(String)
    case runtimeNotFound(String)
    case commandFailed(String)
    case hostToolMissing(tool: String, location: String)
}
