import Foundation

enum DockerSandboxConfigMatch {
    static func matches(running: Bool, labelHash: String?, currentHash: String) -> Bool {
        !running || labelHash == currentHash
    }
}

enum DockerSandboxInspect {
    static func isRunning(containerName: String) async throws -> Bool {
        let result = try await ShellProcessRunner.run(argv: ["docker", "inspect", "-f", "{{.State.Running}}", containerName])
        return String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func configHash(containerName: String) async throws -> String? {
        let result = try await ShellProcessRunner.run(argv: [
            "docker", "inspect", "-f", "{{index .Config.Labels \"sah.configHash\"}}", containerName,
        ])
        let value = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, value != "<no value>" else { return nil }
        return value
    }
}
