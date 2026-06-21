import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Linux bwrap mount policy")
struct LinuxBwrapTests {
    @Test("hostReadOnlyMounts includes paths that exist")
    func includesExistingPaths() {
        let mounts = LinuxBwrapMountPolicy.hostReadOnlyMounts()
        let paths = Set(mounts.map(\.0))
        if FileManager.default.fileExists(atPath: "/usr") { #expect(paths.contains("/usr")) }
        if FileManager.default.fileExists(atPath: "/bin") { #expect(paths.contains("/bin")) }
        if FileManager.default.fileExists(atPath: "/etc") { #expect(paths.contains("/etc")) }
    }

    @Test("hostReadOnlyMounts omits paths that do not exist")
    func omitsMissingPaths() {
        let mounts = LinuxBwrapMountPolicy.hostReadOnlyMounts(
            fileManager: MissingPathFileManager(missing: ["/lib64", "/nope"])
        )
        let paths = Set(mounts.map(\.0))
        #expect(!paths.contains("/lib64"))
        #expect(!paths.contains("/nope"))
        #expect(paths.contains("/usr"))
        #expect(paths.contains("/etc"))
    }

    @Test("candidate paths cover lib and etc")
    func candidatePathsIncludeLibAndEtc() {
        #expect(LinuxBwrapMountPolicy.candidatePaths.contains("/lib"))
        #expect(LinuxBwrapMountPolicy.candidatePaths.contains("/lib64"))
        #expect(LinuxBwrapMountPolicy.candidatePaths.contains("/etc"))
    }

    @Test("setenvFlags emits clearenv and setenv pairs")
    func setenvFlags() {
        let flags = LinuxBwrapEnvPolicy.setenvFlags(env: ["PATH": "/bin", "HOME": "/tmp"])
        #expect(flags.first == "--clearenv")
        #expect(flags.contains("--setenv"))
        #expect(flags.contains("PATH"))
        #expect(flags.contains("/bin"))
        #expect(flags.contains("HOME"))
        #expect(flags.contains("/tmp"))
    }
}

private final class MissingPathFileManager: FileManager, @unchecked Sendable {
    private let missing: Set<String>

    init(missing: [String]) {
        self.missing = Set(missing)
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        !missing.contains(path) && super.fileExists(atPath: path)
    }
}
