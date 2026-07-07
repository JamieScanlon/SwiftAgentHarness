import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Docker sandbox network")
struct DockerSandboxNetworkTests {
    @Test("inspect argv targets docker network inspect")
    func inspectArgv() {
        #expect(DockerSandboxNetwork.inspectArgv(name: "sah-sandbox-browser") == [
            "docker", "network", "inspect", "sah-sandbox-browser",
        ])
    }

    @Test("create argv targets docker network create")
    func createArgv() {
        #expect(DockerSandboxNetwork.createArgv(name: "sah-sandbox-browser") == [
            "docker", "network", "create", "sah-sandbox-browser",
        ])
    }
}
