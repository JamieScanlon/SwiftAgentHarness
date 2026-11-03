import Foundation

public struct DisplayCommandResult: Sendable, Equatable {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32

    public init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public var errorText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a command where a desktop's driver tools live: on this machine, in a container, or on a VM over SSH.
public protocol DisplayCommandRunner: Sendable {
    func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult
}

public extension DisplayCommandRunner {
    func run(_ argv: [String], stdin: Data? = nil, timeout: Duration = .seconds(30)) async throws -> DisplayCommandResult {
        try await run(argv, stdin: stdin, timeout: timeout)
    }

    /// Runs `argv` and returns its output, throwing on a nonzero exit.
    func output(_ argv: [String], stdin: Data? = nil, timeout: Duration = .seconds(30)) async throws -> DisplayCommandResult {
        let result = try await run(argv, stdin: stdin, timeout: timeout)
        guard result.exitCode == 0 else {
            let detail = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw DisplayTargetError.driverFailure("\(argv.first ?? "command") exited \(result.exitCode)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return result
    }
}

#if os(macOS) || os(Linux)
/// Runs commands on this machine.
public struct LocalDisplayCommandRunner: DisplayCommandRunner {
    public var environment: [String: String]

    public init(environment: [String: String] = [:]) {
        self.environment = environment
    }

    public func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult {
        let result = try await ShellProcessRunner.run(argv: argv, env: environment, stdin: stdin, timeoutSeconds: timeout.timeInterval)
        return DisplayCommandResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }
}
#endif

/// Runs commands inside a container with `docker exec`, through another runner (normally this machine's).
public struct DockerExecDisplayCommandRunner: DisplayCommandRunner {
    public var container: String
    public var docker: String
    public var environment: [String: String]
    public var host: any DisplayCommandRunner

    public init(container: String, docker: String = "docker", environment: [String: String] = ["DISPLAY": ":99"], host: any DisplayCommandRunner) {
        self.container = container
        self.docker = docker
        self.environment = environment
        self.host = host
    }

    public func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult {
        var command = [docker, "exec"]
        if stdin != nil { command.append("-i") }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { command += ["-e", "\(key)=\(value)"] }
        return try await host.run(command + [container] + argv, stdin: stdin, timeout: timeout)
    }
}

/// Runs commands on another machine over SSH. Each argument is quoted for the remote shell, so none is reinterpreted
/// there.
public struct SSHDisplayCommandRunner: DisplayCommandRunner {
    public var destination: String
    public var port: Int?
    public var identityFile: String?
    public var options: [String]
    public var environment: [String: String]
    public var host: any DisplayCommandRunner

    public init(
        destination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        options: [String] = ["BatchMode=yes", "StrictHostKeyChecking=accept-new", "ConnectTimeout=10"],
        environment: [String: String] = ["DISPLAY": ":0"],
        host: any DisplayCommandRunner
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.options = options
        self.environment = environment
        self.host = host
    }

    public func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult {
        var command = ["ssh"]
        if let port { command += ["-p", String(port)] }
        if let identityFile { command += ["-i", identityFile] }
        for option in options { command += ["-o", option] }
        let assignments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.quote($0.value))" }
        let remote = (assignments.isEmpty ? [] : ["env"] + assignments) + argv.map(Self.quote)
        return try await host.run(command + [destination, "--", remote.joined(separator: " ")], stdin: stdin, timeout: timeout)
    }

    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
