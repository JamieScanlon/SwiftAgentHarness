import Foundation

enum SandboxFsBridgeShellCommands {
    static func stat(rel: String) -> SandboxBackendCommandParams {
        SandboxBackendCommandParams(
            script: #"stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1""#,
            args: [rel]
        )
    }

    static func readFile(rel: String) -> SandboxBackendCommandParams {
        SandboxBackendCommandParams(script: #"cat "$1""#, args: [rel])
    }

    static func writeFile(rel: String, content: Data) -> SandboxBackendCommandParams {
        SandboxBackendCommandParams(script: #"cat > "$1""#, args: [rel], stdin: content)
    }

    static func mkdir(rel: String) -> SandboxBackendCommandParams {
        SandboxBackendCommandParams(script: #"mkdir -p "$1""#, args: [rel])
    }

    static func rename(relSrc: String, relDst: String) -> SandboxBackendCommandParams {
        SandboxBackendCommandParams(script: #"mv "$1" "$2""#, args: [relSrc, relDst])
    }

    static func remove(rel: String) -> SandboxBackendCommandParams {
        SandboxBackendCommandParams(script: #"rm -rf "$1""#, args: [rel])
    }

    static func exists(rel: String) -> SandboxBackendCommandParams {
        SandboxBackendCommandParams(script: #"test -e "$1" && echo yes || echo no"#, args: [rel])
    }
}

enum SSHRemoteShellCommand {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func build(params: SandboxBackendCommandParams) -> String {
        guard !params.args.isEmpty else { return params.script }
        let quotedScript = shellQuote(params.script)
        let quotedArgs = params.args.map(shellQuote).joined(separator: " ")
        return "bash -c \(quotedScript) -- \(quotedArgs)"
    }
}

enum DockerSandboxShellCommand {
    static func argv(containerName: String, workdir: String, params: SandboxBackendCommandParams) -> [String] {
        var argv = [
            "docker", "exec", "-i", "-w", params.workdir ?? workdir, containerName,
            "/bin/bash", "-c", params.script,
        ]
        if !params.args.isEmpty {
            argv += ["--"] + params.args
        }
        return argv
    }
}
