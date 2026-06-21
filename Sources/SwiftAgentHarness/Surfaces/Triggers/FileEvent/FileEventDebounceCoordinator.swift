import Foundation

actor FileEventDebounceCoordinator {
    private var pending: [String: Task<Void, Never>] = [:]
    private let debounceMilliseconds: Int
    private let onReady: @Sendable (URL) async -> Void

    init(
        debounceMilliseconds: Int = FileEventQueueWatcher.debounceMilliseconds,
        onReady: @escaping @Sendable (URL) async -> Void
    ) {
        self.debounceMilliseconds = debounceMilliseconds
        self.onReady = onReady
    }

    func noteEvent(eventURL: URL) {
        let key = eventURL.lastPathComponent
        pending[key]?.cancel()
        pending[key] = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounceMilliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            await onReady(eventURL)
            self.clear(key: key)
        }
    }

    func cancelAll() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    private func clear(key: String) {
        pending[key] = nil
    }
}
