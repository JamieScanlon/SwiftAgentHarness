import Foundation
import Testing
@testable import SwiftAgentHarness

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Docker sandbox run args")
struct DockerSandboxRunArgsTests {
    private let settings = DockerSandboxSettings()
    private let hostWorkspace = "/host/workspace"
    private let runUser: (uid: UInt32, gid: UInt32) = (501, 20)
    private let configHash = "deadbeef"

    private func buildArgv(
        containerName: String = "c",
        settings: DockerSandboxSettings? = nil,
        runUser: (uid: UInt32, gid: UInt32)? = nil
    ) -> [String] {
        DockerSandboxRunArgs.build(
            containerName: containerName,
            settings: settings ?? self.settings,
            hostWorkspace: hostWorkspace,
            runUser: runUser ?? self.runUser,
            configHash: configHash
        )
    }

    @Test("build includes config hash label")
    func configHashLabel() {
        let argv = buildArgv()
        #expect(argv.contains("--label"))
        #expect(argv.contains("sah.configHash=\(configHash)"))
    }

    @Test("build includes cap-drop ALL and no-new-privileges")
    func hardeningFlags() {
        let argv = buildArgv(containerName: "sah-sandbox-test")
        #expect(argv.contains("--cap-drop"))
        #expect(argv.contains("ALL"))
        #expect(argv.contains("--security-opt"))
        #expect(argv.contains("no-new-privileges:true"))
    }

    @Test("build includes resource limits with defaults")
    func resourceLimits() {
        let argv = buildArgv()
        #expect(argv.contains("--pids-limit"))
        #expect(argv.contains("512"))
        #expect(argv.contains("--memory"))
        #expect(argv.contains("4g"))
        #expect(argv.contains("--cpus"))
        #expect(argv.contains("2.0"))
    }

    @Test("build includes read-only and tmpfs mounts")
    func readOnlyRootfs() {
        let argv = buildArgv()
        #expect(argv.contains("--read-only"))
        #expect(argv.contains("--tmpfs"))
        #expect(argv.contains("/tmp:exec,mode=1777"))
        #expect(argv.contains("/run:exec,mode=755"))
    }

    @Test("build uses resolved run user uid:gid")
    func runUserFlag() {
        let argv = buildArgv(runUser: (1000, 1001))
        #expect(argv.contains("--user"))
        #expect(argv.contains("1000:1001"))
    }

    @Test("build includes workspace bind mount and network")
    func workspaceBindAndNetwork() {
        let argv = buildArgv()
        #expect(argv.contains("--network"))
        #expect(argv.contains("none"))
        #expect(argv.contains("-v"))
        #expect(argv.contains("\(hostWorkspace):\(settings.workdir)"))
        #expect(argv.contains("-w"))
        #expect(argv.contains(settings.workdir))
        #expect(argv.suffix(3) == [settings.image, "sleep", "infinity"])
    }

    @Test("resolveRunUser reads workspace owner from temp dir")
    func resolveRunUserFromTempDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docker-run-user-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = DockerSandboxRunArgs.resolveRunUser(hostWorkspace: dir.path)
        #expect(resolved.uid == UInt32(geteuid()))
        #expect(resolved.gid == UInt32(getegid()))
    }

    @Test("custom limit settings appear in argv")
    func customLimits() {
        let custom = DockerSandboxSettings(pidsLimit: 128, memoryLimit: "1g", cpus: 0.5)
        let argv = buildArgv(settings: custom)
        #expect(argv.contains("128"))
        #expect(argv.contains("1g"))
        #expect(argv.contains("0.5"))
    }
}
