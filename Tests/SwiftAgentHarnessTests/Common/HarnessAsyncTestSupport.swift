import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

enum HarnessAsyncTestSupport {
    static func collectPartialContent(
        from response: ChatStreamResponse,
        timeout: Duration = .seconds(5)
    ) async -> [ChatStreamingPartial] {
        await drain(response.partialContent, timeout: timeout)
    }

    static func drain<T: Sendable>(
        _ stream: AsyncStream<T>,
        timeout: Duration = .seconds(5)
    ) async -> [T] {
        await withTaskGroup(of: [T]?.self) { group in
            group.addTask {
                var values: [T] = []
                for await value in stream {
                    values.append(value)
                }
                return values
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    static func drainOrchestrationState(
        from response: ChatStreamResponse,
        timeout: Duration = .seconds(5)
    ) async {
        _ = await drain(response.orchestrationState, timeout: timeout)
    }

    static func waitUntil(
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(20),
        _ predicate: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }
}
