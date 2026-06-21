import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Sandbox child environment")
struct SandboxChildEnvironmentTests {
    private let host: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/test",
        "TERM": "xterm",
        "LANG": "en_US.UTF-8",
        "OPENAI_API_KEY": "sk-secret",
        "AWS_SECRET_ACCESS_KEY": "aws-secret",
    ]

    @Test("strips non-allowlisted host keys")
    func stripsSecrets() {
        let env = SandboxChildEnvironment.build(overlay: [:], cwd: "/workspace", host: host)
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/test")
    }

    @Test("sets PWD to cwd")
    func setsPWD() {
        let env = SandboxChildEnvironment.build(overlay: [:], cwd: "/workspace", host: host)
        #expect(env["PWD"] == "/workspace")
    }

    @Test("overlay keys are merged last")
    func overlayWins() {
        let env = SandboxChildEnvironment.build(
            overlay: ["CUSTOM_VAR": "visible", "PATH": "/custom/bin"],
            cwd: "/workspace",
            host: host
        )
        #expect(env["CUSTOM_VAR"] == "visible")
        #expect(env["PATH"] == "/custom/bin")
    }

    @Test("defaults when allowlisted keys missing")
    func defaults() {
        let env = SandboxChildEnvironment.build(overlay: [:], cwd: "/workspace", host: [:])
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["SHELL"] == "/bin/bash")
        #expect(env["HOME"] == "/workspace")
    }
}
