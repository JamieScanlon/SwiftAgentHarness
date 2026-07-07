import Foundation

enum ChannelRetryPolicy {
    static func backoffDelay(attempt: Int, baseMs: Int = 500, jitterMs: Int = 250) -> UInt64 {
        let capped = min(attempt, 8)
        let exponential = baseMs * (1 << capped)
        let jitter = Int.random(in: 0...jitterMs)
        return UInt64(exponential + jitter) * 1_000_000
    }
}

public struct ChannelRetryingSender: Sendable {
    public let maxAttempts: Int

    public init(maxAttempts: Int = 4) {
        self.maxAttempts = maxAttempts
    }

    public func send(
        _ operation: @Sendable () async -> ChannelSendResult
    ) async -> ChannelSendResult {
        var attempt = 0
        var last: ChannelSendResult = .failed(code: "not_attempted", message: "not attempted")
        while attempt < maxAttempts {
            last = await operation()
            switch last {
            case .sent:
                return last
            case .failed(let code, _):
                if code == "fatal" { return last }
            }
            attempt += 1
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: ChannelRetryPolicy.backoffDelay(attempt: attempt))
            }
        }
        return last
    }
}
