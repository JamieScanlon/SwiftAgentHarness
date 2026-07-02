import CryptoKit
import Foundation

public struct SSHControlMaster: Sendable {
    public let socketPath: String
    public let target: String
    public let port: Int

    public init(settings: SSHSandboxSettings, fileManager: FileManager = .default) {
        let triple = "\(settings.user)@\(settings.host):\(settings.port)"
        let digest = Insecure.MD5.hash(data: Data(triple.utf8)).map { String(format: "%02x", $0) }.joined()
        let sshDir = fileManager.sahHomeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        try? fileManager.createDirectory(
            at: sshDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        socketPath = sshDir.appendingPathComponent("sah-control-\(digest.prefix(16)).sock").path
        target = triple
        port = settings.port
    }

    public var baseArgs: [String] {
        ["ssh", "-S", socketPath, "-o", "ControlMaster=auto", "-o", "ControlPersist=600", "-p", String(port)]
    }
}

public struct FileSyncManager: Sendable {
    public struct Pair: Sendable, Equatable {
        public let hostPath: String
        public let remotePath: String
        public var mtime: TimeInterval
        public var size: Int64
    }

    private var pairs: [Pair] = []

    public init() {}

    public var isEmpty: Bool { pairs.isEmpty }

    public mutating func track(hostPath: String, remotePath: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: hostPath)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        pairs.append(Pair(hostPath: hostPath, remotePath: remotePath, mtime: mtime, size: size))
    }

    public mutating func refresh(hostPath: String, remotePath: String) {
        guard let index = pairs.firstIndex(where: { $0.hostPath == hostPath && $0.remotePath == remotePath }) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: hostPath)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        pairs[index] = Pair(hostPath: hostPath, remotePath: remotePath, mtime: mtime, size: size)
    }

    public mutating func trackTree(hostRoot: String, remoteRoot: String, fileManager: FileManager = .default) {
        pairs = []
        let hostURL = URL(fileURLWithPath: hostRoot, isDirectory: true).standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: hostURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let prefixWithSlash = hostURL.path + "/"
        for case let fileURL as URL in enumerator {
            let standardized = fileURL.standardizedFileURL
            let isDirectory = (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? true
            guard !isDirectory else { continue }
            guard standardized.path.hasPrefix(prefixWithSlash) else { continue }
            let relative = String(standardized.path.dropFirst(prefixWithSlash.count))
            track(hostPath: standardized.path, remotePath: "\(remoteRoot)/\(relative)")
        }
    }

    public mutating func changedPairs(fileManager: FileManager = .default) -> [Pair] {
        pairs.filter { pair in
            guard let attrs = try? fileManager.attributesOfItem(atPath: pair.hostPath) else { return false }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return mtime != pair.mtime || size != pair.size
        }
    }
}

enum SSHSandboxRemoteRoot {
    static let baseRelative = ".sah/workspaces"

    static func runtimeId(scopeKey: String) -> String {
        "~/\(baseRelative)/\(scopeKey)"
    }

    static func shellPath(scopeKey: String) -> String {
        "\"$HOME/\(baseRelative)/\(scopeKey)\""
    }

    static func rsyncRelativeRoot(scopeKey: String) -> String {
        "\(baseRelative)/\(scopeKey)"
    }

    static func rsyncRelativePath(scopeKey: String) -> String {
        "\(rsyncRelativeRoot(scopeKey: scopeKey))/"
    }

    static func legacyPath(scopeKey: String) -> String {
        "/tmp/sah-\(scopeKey)"
    }

    static func securePrepareCommand(scopeKey: String) -> String {
        """
        set -e
        umask 077
        mkdir -p "$HOME/\(baseRelative)" && chmod 700 "$HOME/\(baseRelative)"
        target="$HOME/\(baseRelative)/\(scopeKey)"
        if [ -e "$target" ] && { [ -L "$target" ] || [ ! -d "$target" ]; }; then exit 1; fi
        mkdir -p "$target"
        """
    }
}

public struct SSHSandboxBackendHandle: SandboxBackendHandle {
    public let id: SandboxBackendID = "ssh"
    public let runtimeId: String
    public let runtimeLabel: String
    public let workdir: String
    public let env: [String: String]?
    public let configLabel: String?
    public let configLabelKind: String? = "Target"
    public let capabilities: SandboxBackendCapabilities? = SandboxBackendManifests.ssh.capabilities

    private let settings: SSHSandboxSettings
    private let hostWorkspace: String
    private let scopeKey: String
    private let control: SSHControlMaster

    init(params: CreateSandboxBackendParams) throws {
        guard let ssh = params.config.ssh else { throw SandboxBackendError.commandFailed("SSH settings missing") }
        self.settings = ssh
        self.hostWorkspace = FilesystemCanonicalPath.resolve(params.workspaceDir)
        self.scopeKey = params.scopeKey
        let runtimeId = SSHSandboxRemoteRoot.runtimeId(scopeKey: params.scopeKey)
        self.workdir = runtimeId
        self.runtimeId = runtimeId
        self.runtimeLabel = "\(ssh.user)@\(ssh.host)"
        self.configLabel = runtimeLabel
        self.control = SSHControlMaster(settings: ssh)
        self.env = nil
    }

    public func buildExecSpec(params: SandboxBuildExecSpecParams) async throws -> SandboxBackendExecSpec {
        let trimmed = params.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SandboxBackendError.emptyCommand }
        try await seedRemoteWorkspaceIfNeeded()
        let shellPath = SSHSandboxRemoteRoot.shellPath(scopeKey: scopeKey)
        let remoteCommand = try SSHRemoteShellCommand.wrapWithEnv(
            params.env,
            remoteCommand: "cd \(shellPath) && \(trimmed)"
        )
        let argv = SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: remoteCommand,
            usePty: params.usePty
        )
        return SandboxBackendExecSpec(argv: argv, cwd: nil, usePty: params.usePty)
    }

    public func runShellCommand(params: SandboxBackendCommandParams) async throws -> SandboxBackendCommandResult {
        try await seedRemoteWorkspaceIfNeeded()
        let remoteScript = SSHRemoteShellCommand.build(params: params)
        let shellPath = SSHSandboxRemoteRoot.shellPath(scopeKey: scopeKey)
        let remoteCommand = try SSHRemoteShellCommand.wrapWithEnv(
            params.env,
            remoteCommand: "cd \(shellPath) && \(remoteScript)"
        )
        let argv = SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: remoteCommand
        )
        let result = try await ShellProcessRunner.run(argv: argv, stdin: params.stdin)
        return SandboxBackendCommandResult(stdout: result.stdout, stderr: result.stderr, code: result.exitCode)
    }

    public func createFsBridge(params: SandboxFsBridgeParams) -> (any SandboxFsBridge)? {
        RemoteFsBridge(handle: self, context: params.context, memoryWriteOnly: params.memoryWriteOnly)
    }

    private func seedRemoteWorkspaceIfNeeded() async throws {
        try await SSHWorkspaceSyncCache.shared.prepare(
            control: control,
            settings: settings,
            hostWorkspace: hostWorkspace,
            scopeKey: scopeKey
        )
    }
}

public struct RemoteFsBridge: SandboxFsBridge {
    private let handle: SSHSandboxBackendHandle
    private let context: SandboxFsBridgeContext
    private let memoryWriteOnly: Bool

    init(handle: SSHSandboxBackendHandle, context: SandboxFsBridgeContext, memoryWriteOnly: Bool) {
        self.handle = handle
        self.context = context
        self.memoryWriteOnly = memoryWriteOnly
    }

    public func stat(path: String) async throws -> SandboxFsStat {
        let rel = try relativePath(path)
        let result = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.stat(rel: rel))
        return SandboxFsStat.parse(from: result)
    }

    public func readFile(path: String) async throws -> Data {
        let rel = try relativePath(path)
        let result = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.readFile(rel: rel))
        guard result.code == 0 else { throw SandboxBackendError.commandFailed("read failed") }
        return result.stdout
    }

    public func writeFile(path: String, content: Data) async throws {
        let rel = try relativePath(path)
        let result = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.writeFile(rel: rel, content: content))
        guard result.code == 0 else { throw SandboxBackendError.commandFailed("write failed") }
    }

    public func mkdir(path: String) async throws {
        let rel = try relativePath(path)
        _ = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.mkdir(rel: rel))
    }

    public func rename(from: String, to: String) async throws {
        let src = try relativePath(from)
        let dst = try relativePath(to)
        _ = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.rename(relSrc: src, relDst: dst))
    }

    public func remove(path: String) async throws {
        let rel = try relativePath(path)
        _ = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.remove(rel: rel))
    }

    private func relativePath(_ path: String) throws -> String {
        let resolved = try PathPolicy.resolveWritablePath(
            raw: path,
            workspaceRoot: context.workspaceRoot,
            memoryDirectory: context.memoryDirectory.map { URL(fileURLWithPath: $0) },
            memoryWriteOnly: memoryWriteOnly
        )
        return try PathPolicy.toRelativeWorkspacePath(root: context.workspaceRoot, candidate: resolved)
    }
}

public struct SSHSandboxBackendManager: SandboxBackendManager {
    private let syncRunner: any SSHWorkspaceSyncRunning

    public init() {
        self.syncRunner = DefaultSSHWorkspaceSyncRunner()
    }

    init(syncRunner: any SSHWorkspaceSyncRunning) {
        self.syncRunner = syncRunner
    }

    public func describeRuntime(params: SandboxBackendDescribeRuntimeParams) async throws -> SandboxBackendRuntimeInfo {
        guard let ssh = params.config.ssh else { throw SandboxBackendError.commandFailed("SSH settings missing") }
        try SSHHostTools.requireLocalRsync()
        let control = SSHControlMaster(settings: ssh)
        try await SSHHostTools.requireRemoteRsync(control: control, settings: ssh, runner: syncRunner)
        let runtimeId = SSHSandboxRemoteRoot.runtimeId(scopeKey: params.scopeKey)
        return SandboxBackendRuntimeInfo(runtimeId: runtimeId, running: true, configMatches: true, runtimeLabel: runtimeId)
    }

    public func removeRuntime(params: SandboxBackendRemoveRuntimeParams) async throws {
        guard let ssh = params.config.ssh else { return }
        let control = SSHControlMaster(settings: ssh)
        let shellPath = SSHSandboxRemoteRoot.shellPath(scopeKey: params.scopeKey)
        let legacyQuoted = SSHRemoteShellCommand.shellQuote(SSHSandboxRemoteRoot.legacyPath(scopeKey: params.scopeKey))
        let argv = SSHSandboxArgv.exec(
            control: control,
            settings: ssh,
            remoteCommand: "rm -rf \(shellPath) \(legacyQuoted)"
        )
        _ = try await ShellProcessRunner.run(argv: argv)
        await SSHWorkspaceSyncCache.shared.remove(scopeKey: params.scopeKey)
    }
}

public enum SSHSandboxBackendRegistration {
    public static func register() {
        SandboxBackendRegistry.register(
            SandboxBackendRegistration(
                manifest: SandboxBackendManifests.ssh,
                factory: { params in try SSHSandboxBackendHandle(params: params) },
                manager: SSHSandboxBackendManager()
            )
        )
    }
}
