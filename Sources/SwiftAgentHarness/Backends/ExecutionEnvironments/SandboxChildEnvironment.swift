import Foundation

public enum SandboxChildEnvironment {
    public static let allowlist: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL",
        "TERM", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
        "TMPDIR",
    ]

    public static func build(
        overlay: [String: String],
        cwd: String,
        host: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in allowlist {
            if let value = host[key] {
                env[key] = value
            }
        }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin" }
        if env["SHELL"] == nil { env["SHELL"] = "/bin/bash" }
        if env["HOME"] == nil { env["HOME"] = cwd }
        env["PWD"] = cwd
        overlay.forEach { env[$0.key] = $0.value }
        return env
    }
}
