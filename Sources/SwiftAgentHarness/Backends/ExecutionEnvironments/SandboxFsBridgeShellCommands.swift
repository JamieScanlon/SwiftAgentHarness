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

    static func wrapWithEnv(_ env: [String: String], remoteCommand: String) throws -> String {
        let pairs = try SandboxRemoteEnvPolicy.sortedPairs(env)
        guard !pairs.isEmpty else { return remoteCommand }
        let exports = pairs.map { key, value in
            "export \(key)=\(shellQuote(value))"
        }.joined(separator: "; ")
        return "\(exports); \(remoteCommand)"
    }
}

enum DockerSandboxShellCommand {
    static func execArgv(
        containerName: String,
        workdir: String,
        command: String,
        env: [String: String] = [:],
        args: [String] = [],
        stdin: Bool = false,
        usePty: Bool = false
    ) throws -> [String] {
        var argv = ["docker", "exec"]
        if usePty {
            argv.append("-it")
        } else if stdin {
            argv.append("-i")
        }
        argv += try DockerSandboxEnvPolicy.execFlags(env: env)
        argv += ["-w", workdir, containerName, "/bin/bash", "-c", command]
        if !args.isEmpty {
            argv += ["--"] + args
        }
        return argv
    }

    static func argv(containerName: String, workdir: String, params: SandboxBackendCommandParams) throws -> [String] {
        try execArgv(
            containerName: containerName,
            workdir: params.workdir ?? workdir,
            command: params.script,
            env: params.env,
            args: params.args,
            stdin: true
        )
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
