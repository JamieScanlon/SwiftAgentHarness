import Foundation

enum SandboxFsBridgeShellCommands {
    static func stat(rel: String) -> SandboxBackendCommandParams {
        SandboxBackendCommandParams(
            script: #"if ! test -e "$1"; then exit 1; fi; kind="$([ -d "$1" ] && echo 1 || echo 0)"; if size=$(stat -f '%z' "$1"); then :; elif size=$(stat -c '%s' "$1"); then :; else exit 1; fi; printf '%s\t%s\n' "$kind" "$size""#,
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

enum LocalSandboxShellCommand {
    static func argv(
        params: SandboxBackendCommandParams,
        workspaceRoot: String,
        memoryDirectory: String?,
        tmpDirectory: String,
        env: [String: String]
    ) -> [String] {
        var argv = LocalExecArgv.sandboxed(
            command: params.script,
            workspaceRoot: workspaceRoot,
            memoryDirectory: memoryDirectory,
            tmpDirectory: tmpDirectory,
            env: env
        )
        if !params.args.isEmpty {
            argv += ["--"] + params.args
        }
        return argv
    }
}
