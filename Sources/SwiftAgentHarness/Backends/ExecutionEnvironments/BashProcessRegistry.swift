import Foundation

public struct ProcessSessionSnapshot: Sendable {
    public let output: String
    public let truncated: Bool
    public let exitCode: Int32?

    public init(output: String, truncated: Bool, exitCode: Int32?) {
        self.output = output
        self.truncated = truncated
        self.exitCode = exitCode
    }
}

public struct ProcessSession: Sendable, Identifiable, Equatable {
    public let id: String
    public let sessionSlug: String
    public var pendingStdout: Data
    public var pendingStderr: Data
    public var aggregated: Data
    public var aggregatedStderr: Data
    public var tail: Data
    public var exitCode: Int32?
    public var createdAt: Date
    public var lastPolledAt: Date
    public let ttlSeconds: TimeInterval
    public var surfacedStdoutBytes: Int
    public var surfacedStderrBytes: Int
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var totalStdoutBytes: Int
    public var totalStderrBytes: Int

    public var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > ttlSeconds
    }
}

public struct ForegroundBudgetRunResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case completed(stdout: String, stderr: String, exitCode: Int32)
        case backgrounded(taskID: String)
        case timedOut
    }

    public let outcome: Outcome

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

public actor BashProcessRegistry {
    public static let shared = BashProcessRegistry()
    public static let minTTL: TimeInterval = 60
    public static let maxTTL: TimeInterval = 3 * 3600
    public static let defaultTTL: TimeInterval = 30 * 60
    public static let maxLiveBufferBytes = 256 * 1024
    public static let maxSnapshotBytes = maxLiveBufferBytes

    private var sessions: [String: ProcessSession] = [:]
    private var handles: [String: SupervisedHandle] = [:]
    private var completionWaiters: [String: [CheckedContinuation<ShellProcessRunner.RunResult?, Never>]] = [:]

    public func register(
        sessionSlug: String,
        argv: [String],
        env: [String: String],
        cwd: String?,
        usePty: Bool = false,
        inheritHostEnvironment: Bool = true,
        maxLiveBufferBytes: Int = BashProcessRegistry.maxLiveBufferBytes
    ) async throws -> String {
        try await start(
            sessionSlug: sessionSlug,
            argv: argv,
            env: env,
            cwd: cwd,
            usePty: usePty,
            inheritHostEnvironment: inheritHostEnvironment,
            maxLiveBufferBytes: maxLiveBufferBytes
        ).taskID
    }

    public struct StartedProcess: Sendable {
        public let taskID: String
    }

    public func start(
        sessionSlug: String,
        argv: [String],
        env: [String: String],
        cwd: String?,
        usePty: Bool = false,
        inheritHostEnvironment: Bool = true,
        maxLiveBufferBytes: Int = BashProcessRegistry.maxLiveBufferBytes
    ) async throws -> StartedProcess {
        reapExpired()
        let id = UUID().uuidString
        let handle = try ShellProcessRunner.startSupervised(
            argv: argv,
            env: env,
            cwd: cwd,
            keepStdinOpen: true,
            usePty: usePty,
            inheritHostEnvironment: inheritHostEnvironment,
            maxLiveBufferBytes: maxLiveBufferBytes
        )
        handles[id] = handle
        Task {
            let result = try? await handle.wait(timeoutSeconds: nil)
            self.complete(id: id, result: result)
        }
        sessions[id] = ProcessSession(
            id: id,
            sessionSlug: sessionSlug,
            pendingStdout: Data(),
            pendingStderr: Data(),
            aggregated: Data(),
            aggregatedStderr: Data(),
            tail: Data(),
            exitCode: nil,
            createdAt: Date(),
            lastPolledAt: Date(),
            ttlSeconds: Self.defaultTTL,
            surfacedStdoutBytes: 0,
            surfacedStderrBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            totalStdoutBytes: 0,
            totalStderrBytes: 0
        )
        return StartedProcess(taskID: id)
    }

    /// Runs a foreground exec, returning inline output when it finishes within the budget or a
    /// background task ID when the budget elapses while the process is still running.
    public func runWithForegroundBudget(
        sessionSlug: String,
        argv: [String],
        env: [String: String],
        cwd: String?,
        budgetSeconds: TimeInterval,
        usePty: Bool = false,
        inheritHostEnvironment: Bool = true,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> ForegroundBudgetRunResult {
        let started = try await start(
            sessionSlug: sessionSlug,
            argv: argv,
            env: env,
            cwd: cwd,
            usePty: usePty,
            inheritHostEnvironment: inheritHostEnvironment
        )
        let id = started.taskID
        let deadline = Date().addingTimeInterval(budgetSeconds)
        let hardDeadline = timeoutSeconds.map { Date().addingTimeInterval($0) }
        while Date() < deadline {
            if let hardDeadline, Date() >= hardDeadline {
                killUnchecked(id: id)
                return ForegroundBudgetRunResult(outcome: .timedOut)
            }
            if let completed = completedResult(id: id) {
                removeSession(id: id)
                return ForegroundBudgetRunResult(outcome: .completed(
                    stdout: String(decoding: completed.stdout, as: UTF8.self),
                    stderr: String(decoding: completed.stderr, as: UTF8.self),
                    exitCode: completed.exitCode
                ))
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if let completed = completedResult(id: id) {
            removeSession(id: id)
            return ForegroundBudgetRunResult(outcome: .completed(
                stdout: String(decoding: completed.stdout, as: UTF8.self),
                stderr: String(decoding: completed.stderr, as: UTF8.self),
                exitCode: completed.exitCode
            ))
        }
        return ForegroundBudgetRunResult(outcome: .backgrounded(taskID: id))
    }

    public func waitForCompletion(id: String, sessionSlug: String, timeoutSeconds: TimeInterval?) async -> ShellProcessRunner.RunResult? {
        guard authorizedSession(id: id, sessionSlug: sessionSlug) != nil else { return nil }
        if let completed = completedResult(id: id) { return completed }
        guard handles[id] != nil else { return nil }
        let waitSeconds = timeoutSeconds ?? .infinity
        if waitSeconds <= 0 { return nil }
        return await withCheckedContinuation { continuation in
            completionWaiters[id, default: []].append(continuation)
            if waitSeconds.isFinite {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, waitSeconds) * 1_000_000_000))
                    self.resumeCompletionWaiters(id: id, result: nil)
                }
            }
        }
    }

    private func completedResult(id: String) -> ShellProcessRunner.RunResult? {
        guard handles[id] == nil, let session = sessions[id], let exitCode = session.exitCode else {
            return nil
        }
        return ShellProcessRunner.RunResult(
            stdout: session.aggregated,
            stderr: session.aggregatedStderr,
            exitCode: exitCode
        )
    }

    private func resumeCompletionWaiters(id: String, result: ShellProcessRunner.RunResult?) {
        let waiters = completionWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func removeSession(id: String) {
        handles.removeValue(forKey: id)
        sessions.removeValue(forKey: id)
        completionWaiters.removeValue(forKey: id)
    }

    /// Consuming poll: returns the output delta since the last poll and advances the surfaced
    /// offset. Used by the model `process` tool for incremental delivery.
    public func poll(id: String, sessionSlug: String) -> ProcessSession? {
        reapExpired()
        guard var session = authorizedSession(id: id, sessionSlug: sessionSlug) else { return nil }
        if let handle = handles[id] {
            let stdoutDelta = Self.pollDelta(buffer: handle.liveStdoutBuffer, surfacedBytes: &session.surfacedStdoutBytes)
            session.pendingStdout = stdoutDelta.data
            session.stdoutTruncated = stdoutDelta.truncated
            session.totalStdoutBytes = handle.liveStdoutBuffer.totalBytes

            let stderrDelta = Self.pollDelta(buffer: handle.liveStderrBuffer, surfacedBytes: &session.surfacedStderrBytes)
            session.pendingStderr = stderrDelta.data
            session.stderrTruncated = stderrDelta.truncated
            session.totalStderrBytes = handle.liveStderrBuffer.totalBytes

            session.tail = Data(handle.liveStdout.suffix(4096))
        } else {
            let stdoutDropped = max(0, session.totalStdoutBytes - session.aggregated.count)
            let stdoutStart = max(session.surfacedStdoutBytes, stdoutDropped)
            let stdoutLocalOffset = stdoutStart - stdoutDropped
            session.pendingStdout = stdoutLocalOffset < session.aggregated.count
                ? Data(session.aggregated.dropFirst(stdoutLocalOffset)) : Data()
            session.surfacedStdoutBytes = session.totalStdoutBytes

            let stderrDropped = max(0, session.totalStderrBytes - session.aggregatedStderr.count)
            let stderrStart = max(session.surfacedStderrBytes, stderrDropped)
            let stderrLocalOffset = stderrStart - stderrDropped
            session.pendingStderr = stderrLocalOffset < session.aggregatedStderr.count
                ? Data(session.aggregatedStderr.dropFirst(stderrLocalOffset)) : Data()
            session.surfacedStderrBytes = session.totalStderrBytes
        }
        session.lastPolledAt = Date()
        sessions[id] = session
        return session
    }

    /// Non-consuming snapshot: returns cumulative output (possibly truncated) without advancing
    /// the poll offset. Used by ACP terminalOutput so clients always see full accumulated output.
    public func snapshot(id: String, sessionSlug: String) -> ProcessSessionSnapshot? {
        guard let session = authorizedSession(id: id, sessionSlug: sessionSlug) else { return nil }
        if let handle = handles[id] {
            let output = handle.liveStdout
            return ProcessSessionSnapshot(
                output: String(decoding: output, as: UTF8.self),
                truncated: handle.liveStdoutBuffer.isTruncated,
                exitCode: session.exitCode
            )
        }
        return ProcessSessionSnapshot(
            output: String(decoding: session.aggregated, as: UTF8.self),
            truncated: session.stdoutTruncated,
            exitCode: session.exitCode
        )
    }

    @discardableResult
    public func kill(id: String, sessionSlug: String) -> Bool {
        guard authorizedSession(id: id, sessionSlug: sessionSlug) != nil else { return false }
        killUnchecked(id: id)
        return true
    }

    public func sendKeys(id: String, sessionSlug: String, data: Data) throws {
        guard authorizedSession(id: id, sessionSlug: sessionSlug) != nil else {
            throw SandboxBackendError.commandFailed("process not found: \(id)")
        }
        guard let handle = handles[id] else {
            throw SandboxBackendError.commandFailed("process not found: \(id)")
        }
        handle.sendKeys(data)
    }

    private func authorizedSession(id: String, sessionSlug: String) -> ProcessSession? {
        guard let session = sessions[id], session.sessionSlug == sessionSlug else { return nil }
        return session
    }

    private func killUnchecked(id: String) {
        handles.removeValue(forKey: id)?.terminate()
        sessions.removeValue(forKey: id)
        resumeCompletionWaiters(id: id, result: nil)
    }

    static func pollDelta(buffer: DataBuffer, surfacedBytes: inout Int) -> (data: Data, truncated: Bool) {
        let data = buffer.slice(fromLogicalOffset: surfacedBytes)
        surfacedBytes = buffer.totalBytes
        return (data, buffer.isTruncated)
    }

    private func complete(id: String, result: ShellProcessRunner.RunResult?) {
        let handle = handles.removeValue(forKey: id)
        guard var session = sessions[id], let result else {
            resumeCompletionWaiters(id: id, result: nil)
            return
        }
        if let handle {
            session.stdoutTruncated = handle.liveStdoutBuffer.isTruncated
            session.stderrTruncated = handle.liveStderrBuffer.isTruncated
            session.totalStdoutBytes = handle.liveStdoutBuffer.totalBytes
            session.totalStderrBytes = handle.liveStderrBuffer.totalBytes
        }
        session.aggregated = result.stdout
        session.aggregatedStderr = result.stderr
        session.tail = Data(result.stdout.suffix(4096))
        session.exitCode = result.exitCode
        sessions[id] = session
        resumeCompletionWaiters(id: id, result: result)
    }

    private func reapExpired() {
        let expired = sessions.filter { $0.value.isExpired }.keys
        for id in expired { handles.removeValue(forKey: id)?.terminate() }
        sessions = sessions.filter { !$0.value.isExpired }
        for id in expired { resumeCompletionWaiters(id: id, result: nil) }
    }

    func markSessionExpiredForTesting(id: String) {
        guard var session = sessions[id] else { return }
        session.createdAt = Date.distantPast
        sessions[id] = session
    }

    public func resetForTesting() {
        handles.values.forEach { $0.terminate() }
        handles = [:]
        sessions = [:]
        completionWaiters.values.forEach { waiters in
            waiters.forEach { $0.resume(returning: nil) }
        }
        completionWaiters = [:]
    }
}
