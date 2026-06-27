import Foundation

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
