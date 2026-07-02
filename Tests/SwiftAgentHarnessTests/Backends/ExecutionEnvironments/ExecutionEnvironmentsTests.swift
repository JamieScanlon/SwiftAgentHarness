import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Sandbox execution environment adapter")
struct SandboxToolExecutionEnvironmentAdapterTests {
    private let adapter = SandboxToolExecutionEnvironmentAdapter()

    private func entry(adapterID: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "test", parameters: [], type: .function),
            source: .local,
            executionEnvironment: .init(kind: .unknown, adapterID: adapterID, isolationLevel: .unknown)
        )
    }

    @Test("local backend maps to local in-process")
    func localKind() {
        let desc = adapter.descriptor(for: entry(adapterID: SandboxBackendManifests.local.adapterID))
        #expect(desc.kind == .local)
        #expect(desc.isolationLevel == .inProcess)
    }

    @Test("docker backend maps to docker remote-managed")
    func dockerKind() {
        let desc = adapter.descriptor(for: entry(adapterID: SandboxBackendManifests.docker.adapterID))
        #expect(desc.kind == .docker)
        #expect(desc.isolationLevel == .remoteManaged)
    }

    @Test("ssh backend maps to ssh remote-managed")
    func sshKind() {
        let desc = adapter.descriptor(for: entry(adapterID: SandboxBackendManifests.ssh.adapterID))
        #expect(desc.kind == .ssh)
        #expect(desc.isolationLevel == .remoteManaged)
    }

    @Test("docker-browser maps to local remote-managed")
    func dockerBrowserKind() {
        let desc = adapter.descriptor(for: entry(adapterID: SandboxBackendManifests.dockerBrowser.adapterID))
        #expect(desc.kind == .local)
        #expect(desc.isolationLevel == .remoteManaged)
    }

    @Test("openshell maps to docker remote-managed")
    func openshellKind() {
        let desc = adapter.descriptor(for: entry(adapterID: SandboxBackendManifests.openshell.adapterID))
        #expect(desc.kind == .docker)
        #expect(desc.isolationLevel == .remoteManaged)
    }
}

@Suite("Sandbox backend registry")
struct SandboxBackendRegistryTests {
    @Test("built-in backends register")
    func builtInBackends() throws {
        SandboxBackendRegistry.resetForTesting()
        SandboxBackendRegistry.bootstrapBuiltInsIfNeeded()
        let manifests = SandboxBackendRegistry.allManifests()
        #expect(manifests.map(\.id).contains("local"))
        #expect(manifests.map(\.id).contains("docker"))
        #expect(manifests.map(\.id).contains("ssh"))
        #expect(manifests.map(\.id).contains("docker-browser"))
        #expect(manifests.map(\.id).contains("openshell"))
    }

    @Test("missing backend throws")
    func missingBackend() throws {
        SandboxBackendRegistry.resetForTesting()
        SandboxBackendRegistry.bootstrapBuiltInsIfNeeded()
        #expect(throws: SandboxBackendError.self) {
            try SandboxBackendRegistry.registration(for: "missing")
        }
    }
}

@Suite("Sandbox config resolver")
struct SandboxConfigResolverTests {
    @Test("non-main mode disables sandbox on main session")
    func nonMainMainSession() {
        let global = SandboxGlobalSettings(mode: .nonMain, backend: "docker", enabled: true)
        let config = SandboxConfigResolver.resolve(
            global: global,
            agentID: "agent-1",
            sessionKey: "sess-1",
            isMainSession: true
        )
        #expect(config.sandboxingActive == false)
        #expect(config.backend == "local")
    }

    @Test("non-main mode enables sandbox on non-main session")
    func nonMainNonMainSession() {
        let global = SandboxGlobalSettings(mode: .nonMain, backend: "docker", enabled: true)
        let config = SandboxConfigResolver.resolve(
            global: global,
            agentID: "agent-1",
            sessionKey: "sess-1",
            isMainSession: false
        )
        #expect(config.sandboxingActive == true)
        #expect(config.backend == "docker")
    }

    @Test("scope key resolves per axis")
    func scopeKey() {
        #expect(SandboxConfigResolver.resolveScopeKey(scope: .agent, sessionKey: "s", agentID: "a") == "agent-a")
        #expect(SandboxConfigResolver.resolveScopeKey(scope: .session, sessionKey: "s", agentID: "a") == "session-s")
        #expect(SandboxConfigResolver.resolveScopeKey(scope: .shared, sessionKey: "s", agentID: "a") == "shared")
    }

    @Test("scope key sanitizes shell metacharacters")
    func scopeKeySanitizesMetacharacters() {
        let malicious = "x; rm -rf / #"
        let scopeKey = SandboxConfigResolver.resolveScopeKey(scope: .session, sessionKey: malicious, agentID: "a")
        #expect(scopeKey == "session-x__rm_-rf____")
        #expect(!scopeKey.contains(";"))
        #expect(!scopeKey.contains(" "))
    }

    @Test("scope key empty component falls back to unknown")
    func scopeKeyEmptyComponent() {
        #expect(SandboxConfigResolver.resolveScopeKey(scope: .agent, sessionKey: "s", agentID: "") == "agent-unknown")
        #expect(SandboxConfigResolver.sanitizeScopeComponent("") == "unknown")
    }
}

@Suite("Path policy")
struct PathPolicyTests {
    private func makeBindFixture() throws -> (workspace: URL, sibling: URL, child: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-policy-bind-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let sibling = base.appendingPathComponent("workspace-secrets", isDirectory: true)
        let child = workspace.appendingPathComponent("subdir", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (workspace, sibling, child, outside)
    }

    private func cleanupBindFixture(_ workspace: URL) {
        try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent())
    }

    @Test("toRelativeWorkspacePath rejects escape")
    func relativeRejectsEscape() throws {
        let root = FileManager.default.temporaryDirectory.path
        #expect(throws: SandboxBackendError.self) {
            try PathPolicy.toRelativeWorkspacePath(root: root, candidate: "/etc/passwd")
        }
    }

    @Test("validateBindSource accepts allowlisted workspace root")
    func validateBindSourceAcceptsWorkspaceRoot() throws {
        let fixture = try makeBindFixture()
        defer { cleanupBindFixture(fixture.workspace) }
        let resolved = try PathPolicy.validateBindSource(fixture.workspace.path, allowlist: [fixture.workspace.path])
        #expect(resolved == FilesystemCanonicalPath.resolve(fixture.workspace.path))
    }

    @Test("validateBindSource accepts path inside workspace")
    func validateBindSourceAcceptsChildPath() throws {
        let fixture = try makeBindFixture()
        defer { cleanupBindFixture(fixture.workspace) }
        let resolved = try PathPolicy.validateBindSource(fixture.child.path, allowlist: [fixture.workspace.path])
        #expect(resolved == FilesystemCanonicalPath.resolve(fixture.child.path))
    }

    @Test("validateBindSource rejects sibling prefix collision")
    func validateBindSourceRejectsSiblingPrefixCollision() throws {
        let fixture = try makeBindFixture()
        defer { cleanupBindFixture(fixture.workspace) }
        #expect(throws: SandboxBackendError.pathEscapes(fixture.sibling.path)) {
            try PathPolicy.validateBindSource(fixture.sibling.path, allowlist: [fixture.workspace.path])
        }
    }

    @Test("validateBindSource rejects path outside allowlist")
    func validateBindSourceRejectsOutsidePath() throws {
        let fixture = try makeBindFixture()
        defer { cleanupBindFixture(fixture.workspace) }
        #expect(throws: SandboxBackendError.pathEscapes(fixture.outside.path)) {
            try PathPolicy.validateBindSource(fixture.outside.path, allowlist: [fixture.workspace.path])
        }
    }
}

@Suite("NoVNC auth")
struct NoVNCAuthTests {
    @Test("token is valid before expiry")
    func validToken() {
        let token = NoVNCAuth.issue(expirySeconds: 60)
        #expect(NoVNCAuth.isValid(token))
    }
}

@Suite("Sandbox config hash")
struct SandboxConfigHashTests {
    @Test("hash is stable for same config")
    func stableHash() {
        let config = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "docker",
            sandboxingActive: true
        )
        #expect(SandboxConfigHash.compute(config: config) == SandboxConfigHash.compute(config: config))
    }

    @Test("hash changes when docker limit fields change")
    func hashChangesWithDockerLimits() {
        let base = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "docker",
            sandboxingActive: true
        )
        let modified = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "docker",
            sandboxingActive: true,
            docker: DockerSandboxSettings(pidsLimit: 256, memoryLimit: "2g", cpus: 1.0)
        )
        #expect(SandboxConfigHash.compute(config: base) != SandboxConfigHash.compute(config: modified))
    }

    @Test("browser hash is stable for same config")
    func stableBrowserHash() {
        let config = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "docker-browser",
            sandboxingActive: true
        )
        #expect(SandboxConfigHash.compute(config: config) == SandboxConfigHash.compute(config: config))
    }

    @Test("browser hash changes when browser limit fields change")
    func hashChangesWithBrowserLimits() {
        let base = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "docker-browser",
            sandboxingActive: true
        )
        let modified = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "docker-browser",
            sandboxingActive: true,
            browser: BrowserSandboxSettings(pidsLimit: 256, memoryLimit: "2g", cpus: 1.0)
        )
        #expect(SandboxConfigHash.compute(config: base) != SandboxConfigHash.compute(config: modified))
    }

    @Test("browser hash differs from docker hash for equivalent limits")
    func browserHashDistinctFromDocker() {
        let docker = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "docker",
            sandboxingActive: true
        )
        let browser = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "docker-browser",
            sandboxingActive: true
        )
        #expect(SandboxConfigHash.compute(config: docker) != SandboxConfigHash.compute(config: browser))
    }
}

@Suite("Workspace mirror sync and OpenShell")
struct WorkspaceMirrorOpenShellTests {
    @Test("mirror workspace routes FS bridge to host")
    func mirrorFsRouting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = SandboxGlobalSettings(
            mode: .all,
            scope: .session,
            backend: "openshell",
            enabled: true,
            openshell: OpenShellSandboxSettings()
        )
        let mirrorService = ExecRuntimeService(
            workspaceRoot: root.path,
            globalSettings: global
        )
        let context = ExecRuntimeContext(sessionKey: "sess", agentID: "agent", isMainSession: false)
        let bridge = try await mirrorService.fsBridge(context: context)
        #expect(bridge is LocalHostFsBridge)
    }

    @Test("openshell exec argv includes sandbox exec subcommand and command")
    func openshellArgv() throws {
        let argv = try OpenShellSandboxArgv.exec(
            cliPath: "/usr/local/bin/openshell",
            sandboxName: "test-sandbox",
            workdir: "/workspace",
            command: "npm test",
            usePty: true
        )
        #expect(argv.first == "/usr/local/bin/openshell")
        #expect(argv.contains("sandbox"))
        #expect(argv.contains("exec"))
        #expect(argv.contains("-n"))
        #expect(argv.contains("test-sandbox"))
        #expect(argv.contains("--tty"))
        #expect(argv.contains("npm test"))
    }

    @Test("openshell backend rejects exec when CLI missing")
    func openshellCLIGating() async throws {
        let params = CreateSandboxBackendParams(
            sessionKey: "sess",
            scopeKey: "agent-1",
            workspaceDir: "/tmp",
            agentWorkspaceDir: "/tmp",
            config: SandboxConfig(
                mode: .all,
                scope: .agent,
                backend: "openshell",
                sandboxingActive: true,
                openshell: OpenShellSandboxSettings()
            ),
            memoryDirectory: nil
        )
        let handle = try OpenShellSandboxBackendHandle(params: params)
        guard OpenShellHostTools.cliPath() == nil else { return }
        await #expect(throws: SandboxBackendError.self) {
            _ = try await handle.buildExecSpec(params: SandboxBuildExecSpecParams(command: "echo hi"))
        }
    }

    @Test("finalizeExec syncs mirror workspace after completed exec")
    func finalizeExecSyncAfter() async throws {
        await WorkspaceMirrorSync.shared.resetForTesting()
        let host = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-host-\(UUID().uuidString)", isDirectory: true)
        let mirror = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: host)
            try? FileManager.default.removeItem(at: mirror)
        }
        try "host".write(to: host.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        final class RecordingRunner: WorkspaceMirrorSyncRunning, @unchecked Sendable {
            private let lock = NSLock()
            private var _calls: [String] = []
            var calls: [String] {
                lock.withLock { _calls }
            }
            func run(argv: [String]) async throws -> ShellProcessRunner.RunResult {
                lock.withLock { _calls.append(argv.joined(separator: " ")) }
                return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: 0)
            }
        }
        let runner = RecordingRunner()
        await WorkspaceMirrorSync.shared.setRunnerForTesting(runner)
        try await WorkspaceMirrorSync.shared.syncBefore(hostRoot: host.path, mirrorRoot: mirror.path)
        try await WorkspaceMirrorSync.shared.syncAfter(hostRoot: host.path, mirrorRoot: mirror.path)
        #expect(runner.calls.count == 2)
        #expect(runner.calls[0].contains("rsync"))
        #expect(runner.calls[1].contains("rsync"))
    }
}
