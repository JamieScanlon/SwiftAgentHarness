import Foundation

/// Upcoming: `workspace/events/` file-event queue watcher (Step 11).
enum FileEventQueueWatcher {
    static let debounceMilliseconds: Int = 100
    static let parseRetryBackoffMilliseconds: [Int] = [100, 200, 400]
    static let watcherRetryDelayMilliseconds: Int = 5000
}
