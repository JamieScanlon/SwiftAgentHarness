import Foundation

enum DockerSandboxNetwork {
    static func inspectArgv(name: String) -> [String] {
        ["docker", "network", "inspect", name]
    }

    static func createArgv(name: String) -> [String] {
        ["docker", "network", "create", name]
    }

    static func ensureExists(name: String) async throws {
        let inspect = try await ShellProcessRunner.run(argv: inspectArgv(name: name))
        if inspect.exitCode == 0 { return }

        let create = try await ShellProcessRunner.run(argv: createArgv(name: name))
        guard create.exitCode == 0 else {
            let stderr = String(data: create.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = stderr.isEmpty ? "exit code \(create.exitCode)" : stderr
            throw SandboxBackendError.commandFailed("Failed to create docker network '\(name)': \(detail)")
        }
    }
}
