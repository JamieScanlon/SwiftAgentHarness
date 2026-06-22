import Foundation

extension FileManager {
    /// iOS-safe home directory.
    ///
    /// `homeDirectoryForCurrentUser` is unavailable on iOS/tvOS/watchOS/visionOS. On those
    /// platforms `NSHomeDirectory()` returns the app's sandbox container; on macOS/Linux it
    /// matches `homeDirectoryForCurrentUser` for non-sandboxed processes, so behavior there is
    /// preserved.
    var sahHomeDirectory: URL {
        #if os(macOS) || os(Linux)
        return homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}
