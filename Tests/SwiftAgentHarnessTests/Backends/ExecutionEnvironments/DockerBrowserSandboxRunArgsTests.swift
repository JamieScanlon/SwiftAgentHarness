import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Docker browser sandbox run args")
struct DockerBrowserSandboxRunArgsTests {
    private let settings = BrowserSandboxSettings()
    private let runUser: (uid: UInt32, gid: UInt32) = (501, 20)
    private let configHash = "deadbeef"
    private let workdir = "/home/browser"

    private func buildArgv(
        containerName: String = "sah-browser-test",
        settings: BrowserSandboxSettings? = nil,
        runUser: (uid: UInt32, gid: UInt32)? = nil
    ) -> [String] {
        DockerSandboxRunArgs.buildBrowser(
            containerName: containerName,
            settings: settings ?? self.settings,
            runUser: runUser ?? self.runUser,
            configHash: configHash,
            workdir: workdir
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
        let argv = buildArgv()
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
        #expect(argv.contains("/home/browser:exec,mode=700,uid=501,gid=20"))
    }

    @Test("build uses resolved run user uid:gid")
    func runUserFlag() {
        let argv = buildArgv(runUser: (1000, 1001))
        #expect(argv.contains("--user"))
        #expect(argv.contains("1000:1001"))
        #expect(argv.contains("/home/browser:exec,mode=700,uid=1000,gid=1001"))
    }

    @Test("build includes browser network and workdir without workspace bind")
    func networkAndWorkdir() {
        let argv = buildArgv()
        #expect(argv.contains("--network"))
        #expect(argv.contains("sah-sandbox-browser"))
        #expect(argv.contains("-w"))
        #expect(argv.contains(workdir))
        #expect(!argv.contains("-v"))
        #expect(argv.suffix(3) == [settings.image, "sleep", "infinity"])
    }

    @Test("custom limit settings appear in argv")
    func customLimits() {
        let custom = BrowserSandboxSettings(
            network: "custom-browser-net",
            pidsLimit: 128,
            memoryLimit: "1g",
            cpus: 0.5
        )
        let argv = buildArgv(settings: custom)
        #expect(argv.contains("custom-browser-net"))
        #expect(argv.contains("128"))
        #expect(argv.contains("1g"))
        #expect(argv.contains("0.5"))
    }
}
