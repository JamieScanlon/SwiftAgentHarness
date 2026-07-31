import Foundation
import Logging

public actor FileEventQueueService {
    private let eventsDirectory: URL
    private let enabled: Bool
    private let debounceMilliseconds: Int
    private let watcherRetryDelayMilliseconds: Int
    private let consume: FileEventConsumePipeline
    private let periodicSync: FileEventPeriodicSync
    private let scheduledSync: FileEventScheduledSync
    private let parser: FileEventPayloadParser
    private let logger: Logger
    private var debounce: FileEventDebounceCoordinator?
    private var watchSource: FileEventDirectoryWatchSource?
    private var harnessStartTime: Date?
    private var knownFiles: Set<String> = []

    init(
        eventsDirectory: URL,
        dispatch: TriggerDispatchService,
        registration: TriggerRegistrationService,
        logger: Logger,
        enabled: Bool = true,
        debounceMilliseconds: Int = FileEventQueueWatcher.debounceMilliseconds,
        watcherRetryDelayMilliseconds: Int = FileEventQueueWatcher.watcherRetryDelayMilliseconds
    ) {
        self.eventsDirectory = eventsDirectory
        self.enabled = enabled
        self.debounceMilliseconds = debounceMilliseconds
        self.watcherRetryDelayMilliseconds = watcherRetryDelayMilliseconds
        self.logger = logger
        let ingress = FileEventIngressAdapter()
        self.parser = FileEventPayloadParser(logger: logger)
        self.consume = FileEventConsumePipeline(
            eventsDirectory: eventsDirectory,
            parser: parser,
            ingress: ingress,
            dispatch: dispatch,
            logger: logger
        )
        self.periodicSync = FileEventPeriodicSync(eventsDirectory: eventsDirectory, registration: registration, logger: logger)
        self.scheduledSync = FileEventScheduledSync(eventsDirectory: eventsDirectory, registration: registration, logger: logger)
    }

    public func start() async {
        guard enabled else { return }
        harnessStartTime = Date()
        try? FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: FileEventQueueLayout.processingDirectory(eventsDirectory: eventsDirectory),
            withIntermediateDirectories: true
        )
        try? periodicSync.syncAllPeriodicFiles()
        await runStartupScan()
        let debounceCoordinator = FileEventDebounceCoordinator(debounceMilliseconds: debounceMilliseconds) { url in
            await self.handleDebouncedEvent(url)
        }
        debounce = debounceCoordinator
        let watch = FileEventDirectoryWatchSource(
            eventsDirectory: eventsDirectory,
            retryDelayMilliseconds: watcherRetryDelayMilliseconds
        ) { [weak self] url in
            Task { await self?.noteFilesystemEvent(url) }
        } onError: { [logger] error in
            logger.warning("file_event_watch_error error=\(String(describing: error))")
        }
        watchSource = watch
        watch.start()
    }

    func stop() {
        watchSource?.stop()
        watchSource = nil
        Task { await debounce?.cancelAll() }
        debounce = nil
    }

    private func runStartupScan() async {
        guard let harnessStartTime else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in urls where FileEventQueueLayout.isEventJSON(url) {
            knownFiles.insert(url.lastPathComponent)
            await handleStartupFile(url, harnessStartTime: harnessStartTime)
        }
    }

    private func handleStartupFile(_ url: URL, harnessStartTime: Date) async {
        guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return }
        switch await parser.parse(at: url) {
        case .skipped:
            return
        case .parsed(let payload):
            let action = FileEventStalenessPolicy.startupAction(
                payload: payload,
                fileModificationDate: mtime,
                harnessStartTime: harnessStartTime
            )
            await applyStartupAction(action, url: url, payload: payload)
        }
    }

    private func applyStartupAction(_ action: FileEventStartupAction, url: URL, payload: FileEventPayload) async {
        switch action {
        case .delete:
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: FileEventQueueLayout.trustSidecarURL(for: url))
        case .consume(let missed):
            if payload.type == .periodic {
                try? periodicSync.syncFromFile(at: url)
            } else if payload.type == .oneShot,
                      (try? scheduledSync.syncFutureOneShot(at: url, payload: payload)) == true {
                break
            } else {
                await consume.consume(eventURL: url, missed: missed)
            }
        case .registerPeriodic:
            try? periodicSync.syncFromFile(at: url)
        case .deferOneShot:
            _ = try? scheduledSync.syncFutureOneShot(at: url, payload: payload)
        }
    }

    private func noteFilesystemEvent(_ url: URL) async {
        await reconcileDeletedFiles()
        guard FileEventQueueLayout.isEventJSON(url) else { return }
        knownFiles.insert(url.lastPathComponent)
        await debounce?.noteEvent(eventURL: url)
    }

    private func reconcileDeletedFiles() async {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        let present = Set(urls.filter { FileEventQueueLayout.isEventJSON($0) }.map(\.lastPathComponent))
        let removed = knownFiles.subtracting(present)
        for name in removed {
            try? scheduledSync.removeForDeletedFile(named: name)
            try? periodicSync.removeForDeletedFile(named: name)
        }
        knownFiles = present
    }

    private func handleDebouncedEvent(_ url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? scheduledSync.removeForDeletedFile(named: url.lastPathComponent)
            try? periodicSync.removeForDeletedFile(named: url.lastPathComponent)
            return
        }
        switch await parser.parse(at: url) {
        case .skipped:
            return
        case .parsed(let payload):
            switch payload.type {
            case .periodic:
                try? periodicSync.syncFromFile(at: url)
            case .oneShot:
                if (try? scheduledSync.syncFutureOneShot(at: url, payload: payload)) == true {
                    return
                }
                let missed = false
                await consume.consume(eventURL: url, missed: missed)
            case .immediate:
                await consume.consume(eventURL: url, missed: false)
            }
        }
    }
}
