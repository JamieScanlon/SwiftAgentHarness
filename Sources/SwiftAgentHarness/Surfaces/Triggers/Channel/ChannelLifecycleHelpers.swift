import Foundation

enum ChannelRetryPolicy {
    static func backoffDelay(attempt: Int, baseMs: Int = 500, jitterMs: Int = 250) -> UInt64 {
        let capped = min(attempt, 8)
        let exponential = baseMs * (1 << capped)
        let jitter = Int.random(in: 0...jitterMs)
        return UInt64(exponential + jitter) * 1_000_000
    }
}

struct ChannelRetryingSender: Sendable {
    let maxAttempts: Int

    init(maxAttempts: Int = 4) {
        self.maxAttempts = maxAttempts
    }

    func send(
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

actor ChannelTypingKeepalive {
    private var task: Task<Void, Never>?
    private let intervalNs: UInt64

    init(intervalSeconds: TimeInterval = 4) {
        self.intervalNs = UInt64(intervalSeconds * 1_000_000_000)
    }

    func start(chatId: String, sendTyping: @escaping @Sendable (String) async -> Void) {
        stop()
        task = Task {
            while !Task.isCancelled {
                await sendTyping(chatId)
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

enum ChannelLifecycleDrain {
    static func drain(tasks: [Task<Void, Never>]) async {
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.value
        }
    }
}

enum ChannelFatalErrorSurfacer {
    static func surface(_ error: ChannelFatalError, statusWriter: ChannelRuntimeStatusWriter) async {
        await statusWriter.recordFatal(error)
    }
}

struct ChannelRuntimeStatusWriter: Sendable {
    let channel: ChannelId
    let dataDirectory: URL

    func recordFatal(_ error: ChannelFatalError) async {
        ChannelRuntimeStatus.recordFatal(
            channel: channel,
            error: error,
            dataDirectory: dataDirectory
        )
    }
}
