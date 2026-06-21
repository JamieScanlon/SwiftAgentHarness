import Foundation
import Dispatch

final class FileEventDirectoryWatchSource: @unchecked Sendable {
    private let eventsDirectory: URL
    private let retryDelayMilliseconds: Int
    private let onEvent: @Sendable (URL) -> Void
    private let onError: @Sendable (Error) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var watchTask: Task<Void, Never>?
    private let lock = NSLock()

    init(
        eventsDirectory: URL,
        retryDelayMilliseconds: Int = FileEventQueueWatcher.watcherRetryDelayMilliseconds,
        onEvent: @escaping @Sendable (URL) -> Void,
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.eventsDirectory = eventsDirectory
        self.retryDelayMilliseconds = retryDelayMilliseconds
        self.onEvent = onEvent
        self.onError = onError
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try self.attachWatch()
                    await self.waitUntilCancelled()
                    return
                } catch {
                    self.onError(error)
                    self.teardownWatch()
                    try? await Task.sleep(nanoseconds: UInt64(self.retryDelayMilliseconds) * 1_000_000)
                }
            }
        }
    }

    func stop() {
        lock.lock()
        watchTask?.cancel()
        watchTask = nil
        teardownWatch()
        lock.unlock()
    }

    private func attachWatch() throws {
        teardownWatch()
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        let path = eventsDirectory.path
        directoryFD = open(path, O_EVTONLY)
        guard directoryFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            self?.scanDirectory()
        }
        src.setCancelHandler { [weak self] in
            self?.teardownWatch()
        }
        source = src
        src.resume()
        scanDirectory()
    }

    private func waitUntilCancelled() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        stop()
    }

    private func teardownWatch() {
        source?.cancel()
        source = nil
        if directoryFD >= 0 {
            close(directoryFD)
            directoryFD = -1
        }
    }

    private func scanDirectory() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in urls where FileEventQueueLayout.isEventJSON(url) {
            onEvent(url)
        }
    }
}
