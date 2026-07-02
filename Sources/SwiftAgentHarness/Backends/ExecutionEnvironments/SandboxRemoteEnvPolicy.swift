import Foundation

enum SandboxRemoteEnvPolicy {
    static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func sortedPairs(_ env: [String: String]) throws -> [(String, String)] {
        for key in env.keys where !isValidKey(key) {
            throw SandboxBackendError.commandFailed("invalid environment variable name: \(key)")
        }
        return env.sorted(by: { $0.key < $1.key })
    }

    static func sortedPairsForOpenShell(_ env: [String: String]) throws -> [(String, String)] {
        for key in env.keys where key.hasPrefix("OPENSHELL_") {
            throw SandboxBackendError.commandFailed("environment variable names starting with OPENSHELL_ are reserved")
        }
        return try sortedPairs(env)
    }
}

enum DockerSandboxEnvPolicy {
    static func execFlags(env: [String: String]) throws -> [String] {
        var argv: [String] = []
        for (key, value) in try SandboxRemoteEnvPolicy.sortedPairs(env) {
            argv += ["-e", "\(key)=\(value)"]
        }
        return argv
    }
}

enum OpenShellSandboxEnvPolicy {
    static func execFlags(env: [String: String]) throws -> [String] {
        var argv: [String] = []
        for (key, value) in try SandboxRemoteEnvPolicy.sortedPairsForOpenShell(env) {
            argv += ["--env", "\(key)=\(value)"]
        }
        return argv
    }
}
