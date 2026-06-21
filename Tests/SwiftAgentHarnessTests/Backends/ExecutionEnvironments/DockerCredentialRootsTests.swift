import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Docker credential roots")
struct DockerCredentialRootsTests {
    @Test("blocks credential root path segments")
    func blocksCredentialRoots() {
        #expect(DockerCredentialRoots.violatesBindSource("/home/user/.aws/credentials"))
        #expect(DockerCredentialRoots.violatesBindSource("/home/user/.ssh/id_rsa"))
        #expect(DockerCredentialRoots.violatesBindSource("/home/user/.docker/config.json"))
    }

    @Test("allows innocuous paths with similar substrings")
    func allowsInnocuousPaths() {
        #expect(!DockerCredentialRoots.violatesBindSource("/proj/.dockerized/tools"))
        #expect(!DockerCredentialRoots.violatesBindSource("/home/user/.ssh-backup"))
        #expect(!DockerCredentialRoots.violatesBindSource("/workspace/data"))
    }
}
