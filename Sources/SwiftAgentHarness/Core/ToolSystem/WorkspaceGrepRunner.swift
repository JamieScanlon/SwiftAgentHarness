import Foundation

enum WorkspaceGrepError: Error, Equatable, Sendable {
    case invalidRegex(String)
    case timedOut
    case executionFailed(String)
}

enum WorkspaceGrepRunner {
    static let maxMatchingLines = 50
    static let maxWallClockSeconds: TimeInterval = 5
    static let maxLineBytes = 100 * 1024

    static func run(
        pattern: String,
        searchRoot: String,
        workspaceRoot: String,
        execRuntime: ExecRuntimeService,
        runtimeContext: ExecRuntimeContext,
        forceInProcess: Bool = false
    ) async -> Result<String, WorkspaceGrepError> {
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            return .failure(.invalidRegex(error.localizedDescription))
        }
        if !forceInProcess && LocalExecArgv.isSandboxAvailable {
            switch await runSandboxBacked(
                pattern: pattern,
                searchRoot: searchRoot,
                workspaceRoot: workspaceRoot,
                execRuntime: execRuntime,
                runtimeContext: runtimeContext
            ) {
            case .success(let output):
                return .success(output)
            case .failure(let error):
                return .failure(error)
            }
        }
        return await runInProcessWithTimeout(pattern: pattern, searchRoot: searchRoot)
    }

    static func sandboxPipelineResult(exitCode: Int32, output: String) -> Result<String, WorkspaceGrepError> {
        if exitCode == 2 || looksLikeGrepRegexError(output) {
            return .failure(.invalidRegex(sandboxRegexError(from: output)))
        }
        if exitCode == 0 || exitCode == 1 || exitCode == 141 {
            return .success(trimTrailingNewline(output))
        }
        return .failure(.executionFailed("grep pipeline exited with status \(exitCode)"))
    }

    private static func looksLikeGrepRegexError(_ output: String) -> Bool {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("grep:") else { continue }
            let lower = trimmed.lowercased()
            if lower.contains("invalid")
                || lower.contains("repetition-operator")
                || lower.contains("backreference") {
                return true
            }
        }
        return false
    }

    private static func runSandboxBacked(
        pattern: String,
        searchRoot: String,
        workspaceRoot: String,
        execRuntime: ExecRuntimeService,
        runtimeContext: ExecRuntimeContext
    ) async -> Result<String, WorkspaceGrepError> {
        let encoded = Data(pattern.utf8).base64EncodedString()
        let searchArg = shellSingleQuote(relativeSearchPath(searchRoot: searchRoot, workspaceRoot: workspaceRoot))
        #if os(macOS)
        let decodeFlag = "base64 -D"
        #else
        let decodeFlag = "base64 -d"
        #endif
        let command = """
        set -o pipefail
        pat=$(printf '%s' '\(encoded)' | \(decodeFlag))
        grep -E -e "$pat" /dev/null
        ec=$?
        if [ $ec -eq 2 ]; then exit 2; fi
        grep -rHn -E -e "$pat" --binary-files=without-match \(searchArg) | LC_ALL=C sort | head -n \(maxMatchingLines)
        """
        do {
            let result = try await withWallClockTimeout(seconds: maxWallClockSeconds) {
                try await execRuntime.runShell(command: command, context: runtimeContext)
            }
            return await classifySandboxExecResult(
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
                pattern: pattern,
                searchRoot: searchRoot
            )
        } catch let error as WorkspaceGrepError {
            return .failure(error)
        } catch let error as SandboxBackendError {
            switch error {
            case .nonZeroExit(let code, let output):
                return await classifySandboxExecResult(
                    exitCode: code,
                    stdout: output,
                    stderr: "",
                    pattern: pattern,
                    searchRoot: searchRoot
                )
            case .emptyCommand, .sandboxUnavailable:
                return await runInProcessWithTimeout(pattern: pattern, searchRoot: searchRoot)
            default:
                return await runInProcessWithTimeout(pattern: pattern, searchRoot: searchRoot)
            }
        } catch {
            return await runInProcessWithTimeout(pattern: pattern, searchRoot: searchRoot)
        }
    }

    private static func classifySandboxExecResult(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        pattern: String,
        searchRoot: String
    ) async -> Result<String, WorkspaceGrepError> {
        let pipeline = sandboxPipelineResult(exitCode: exitCode, output: stdout + stderr)
        if case .failure(.executionFailed) = pipeline {
            return await runInProcessWithTimeout(pattern: pattern, searchRoot: searchRoot)
        }
        return pipeline
    }

    private static func sandboxRegexError(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "pattern rejected by grep" }
        if let line = trimmed.split(separator: "\n").first {
            return String(line)
        }
        return trimmed
    }

    private static func runInProcessWithTimeout(
        pattern: String,
        searchRoot: String
    ) async -> Result<String, WorkspaceGrepError> {
        do {
            return try await withWallClockTimeout(seconds: maxWallClockSeconds) {
                await runInProcess(pattern: pattern, searchRoot: searchRoot)
            }
        } catch let error as WorkspaceGrepError {
            return .failure(error)
        } catch {
            return .failure(.executionFailed(error.localizedDescription))
        }
    }

    private static func runInProcess(
        pattern: String,
        searchRoot: String
    ) async -> Result<String, WorkspaceGrepError> {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            return .failure(.invalidRegex(error.localizedDescription))
        }
        let started = Date()
        var hits: [String] = []
        let relativePaths = WorkspacePathEnumerator.sortedRegularFileRelativePaths(under: searchRoot)
        for rel in relativePaths {
            if shouldStopInProcess(started: started) {
                return .failure(.timedOut)
            }
            let full = (searchRoot as NSString).appendingPathComponent(rel)
            guard WorkspaceTextFileReader.isTextReadableFile(at: full),
                  let text = WorkspaceTextFileReader.readUTF8(at: full) else {
                continue
            }
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            for (index, lineSub) in lines.enumerated() {
                if shouldStopInProcess(started: started) {
                    return .failure(.timedOut)
                }
                if lineSub.utf8.count > maxLineBytes {
                    continue
                }
                let line = String(lineSub)
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard regex.firstMatch(in: line, options: [], range: range) != nil else {
                    continue
                }
                hits.append("\(full):\(index + 1):\(line)")
                if hits.count >= maxMatchingLines { break }
            }
            if hits.count >= maxMatchingLines { break }
        }
        return .success(hits.joined(separator: "\n"))
    }

    private static func shouldStopInProcess(started: Date) -> Bool {
        Task.isCancelled || Date().timeIntervalSince(started) >= maxWallClockSeconds
    }

    private static func relativeSearchPath(searchRoot: String, workspaceRoot: String) -> String {
        let root = (workspaceRoot as NSString).standardizingPath
        let search = (searchRoot as NSString).standardizingPath
        if search == root { return "." }
        let prefix = root + "/"
        if search.hasPrefix(prefix) {
            return String(search.dropFirst(prefix.count))
        }
        return search
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func trimTrailingNewline(_ value: String) -> String {
        value.hasSuffix("\n") ? String(value.dropLast()) : value
    }

    private static func withWallClockTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WorkspaceGrepError.timedOut
            }
            guard let result = try await group.next() else {
                throw WorkspaceGrepError.timedOut
            }
            group.cancelAll()
            return result
        }
    }
}
