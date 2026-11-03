import Foundation

/// Where to reach the user's own browser over the DevTools protocol.
public enum UserBrowserEndpoint: Sendable, Hashable {
    /// The `DevToolsActivePort` file a Chromium-family browser writes into its user data directory while it accepts
    /// a debugger: when the user allows remote debugging at `chrome://inspect/#remote-debugging`, or started it with
    /// `--remote-debugging-port`.
    case devToolsActivePort(directory: URL)
    /// A browser-level DevTools WebSocket URL.
    case webSocket(URL)

    /// Google Chrome's default profile directory.
    public static let chrome = UserBrowserEndpoint.devToolsActivePort(directory: chromeUserDataDirectory)

    public static var chromeUserDataDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        #else
        return home.appendingPathComponent(".config/google-chrome", isDirectory: true)
        #endif
    }

    /// The browser's DevTools WebSocket URL.
    public func resolve() throws -> URL {
        switch self {
        case .webSocket(let url):
            return url
        case .devToolsActivePort(let directory):
            let file = directory.appendingPathComponent("DevToolsActivePort")
            let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.count >= 2, let port = Int(lines[0]), (1...65_535).contains(port), lines[1].hasPrefix("/"),
                  let url = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") else {
                throw DisplayTargetError.driverFailure(
                    "the browser isn't accepting a debugger: allow remote debugging at chrome://inspect/#remote-debugging, "
                        + "or start it with --remote-debugging-port (no DevToolsActivePort in \(directory.path))"
                )
            }
            return url
        }
    }
}
