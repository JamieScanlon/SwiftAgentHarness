import Foundation
import Logging
import SwiftAgentKit

/// In-flight tool dispatch watchdog + outer wall-clock timeout for TurnLoop.
enum ToolDispatchWatchdog {
    struct Context: Sendable {
        let toolName: String
        let toolCallID: String?
        let runID: UUID?
        let conversationID: UUID
        let mcpServerName: String?
        /// `nil` for a tool that bounds its own run time: heartbeats are logged, and nothing times it out.
        let timeoutSeconds: TimeInterval?
        let watchdogIntervalSeconds: TimeInterval
    }

    /// The per-call timeout for a tool, or `nil` when its entry bounds its own run time.
    static func timeoutSeconds(
        forToolNamed name: String,
        entries: [ToolRegistryEntry],
        contract: AgentRuntimeToolDispatchContract
    ) -> TimeInterval? {
        let entry = entries.first { $0.name == name }
        return entry?.policyTags.contains(.boundsOwnRunTime) == true ? nil : contract.toolCallTimeoutSeconds
    }

    /// Runs `operation` bounded by `context.timeoutSeconds`, logging heartbeat warnings while waiting.
    static func withTimeoutAndWatchdog<T: Sendable>(
        context: Context,
        logger: Logger?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let startedAt = ContinuousClock.now
        let timeoutMs = context.timeoutSeconds.map { max(0, Int(($0 * 1_000).rounded(.towardZero))) } ?? 0
        let interval = max(1, context.watchdogIntervalSeconds)
        let halfTimeout = (context.timeoutSeconds ?? .infinity) * 0.5

        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    let elapsedMs = Self.elapsedMilliseconds(since: startedAt)
                    let line = watchdogLine(context: context, elapsedMs: elapsedMs, timeoutMs: timeoutMs)
                    let elapsedSeconds = Double(elapsedMs) / 1_000
                    if elapsedSeconds >= halfTimeout {
                        logger?.warning("\(line)")
                    } else {
                        logger?.info("\(line)")
                    }
                }
            }
            defer { group.cancelAll() }
            guard let timeoutSeconds = context.timeoutSeconds else {
                return try await operation()
            }
            do {
                return try await withToolCallTimeout(timeoutSeconds, toolName: context.toolName) {
                    try await operation()
                }
            } catch let timeout as ToolCallTimeoutError {
                let elapsedMs = Self.elapsedMilliseconds(since: startedAt)
                logger?.error(
                    "[ToolDispatchWatchdog] timed out tool=\(context.toolName) toolCallID=\(context.toolCallID ?? "") runID=\(context.runID?.uuidString ?? "") conversationID=\(context.conversationID.uuidString) mcpServer=\(context.mcpServerName ?? "") elapsedMs=\(elapsedMs) timeoutMs=\(timeoutMs)"
                )
                throw timeout
            } catch is CancellationError {
                // withToolCallTimeout may surface cooperative cancel ahead of ToolCallTimeoutError.
                let elapsedMs = Self.elapsedMilliseconds(since: startedAt)
                logger?.error(
                    "[ToolDispatchWatchdog] timed out tool=\(context.toolName) toolCallID=\(context.toolCallID ?? "") runID=\(context.runID?.uuidString ?? "") conversationID=\(context.conversationID.uuidString) mcpServer=\(context.mcpServerName ?? "") elapsedMs=\(elapsedMs) timeoutMs=\(timeoutMs)"
                )
                throw ToolCallTimeoutError(timeout: timeoutSeconds, toolName: context.toolName)
            }
        }
    }

    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now)
        return max(0, Int(elapsed / .milliseconds(1)))
    }

    static func watchdogLine(context: Context, elapsedMs: Int, timeoutMs: Int) -> String {
        "[ToolDispatchWatchdog] still waiting tool=\(context.toolName) toolCallID=\(context.toolCallID ?? "") runID=\(context.runID?.uuidString ?? "") conversationID=\(context.conversationID.uuidString) mcpServer=\(context.mcpServerName ?? "") elapsedMs=\(elapsedMs) timeoutMs=\(timeoutMs)"
    }

    /// Best-effort MCP server name from `mcp__<server>__*` tool naming.
    static func mcpServerName(fromToolName toolName: String) -> String? {
        let parts = toolName.split(separator: "__", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        let server = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return server.isEmpty ? nil : server
    }

    static func classifyToolFailure(message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") {
            return "timeout"
        }
        if lower.contains("cancel") {
            return "cancelled"
        }
        if lower.contains("mcp") {
            return "mcp_error"
        }
        return "dispatch_error"
    }
}
