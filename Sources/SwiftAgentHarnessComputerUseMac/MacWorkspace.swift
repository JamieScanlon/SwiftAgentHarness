#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// An on-screen window as the window server lists it.
struct MacWindowEntry: Sendable, Equatable {
    var pid: pid_t
    /// 0 for normal app windows; higher for the Dock, menus, panels, and other floating windows.
    var layer: Int
    var bounds: CGRect
}

/// The installed apps that open web pages.
struct MacBrowsers: Sendable, Equatable {
    var installed: [String]
    var defaultBundleID: String?
}

/// What the target reads about the desktop: running apps, the frontmost one, and window stacking.
protocol MacWorkspaceReading: Sendable {
    func frontmostApp() async -> MacRunningApp?
    func runningApp(pid: pid_t) async -> MacRunningApp?
    /// On-screen windows, front to back.
    func windows() async -> [MacWindowEntry]
    func browsers() async -> MacBrowsers
}

struct LiveMacWorkspace: MacWorkspaceReading {
    func frontmostApp() async -> MacRunningApp? {
        await MacAppControl.frontmostApp()
    }

    func runningApp(pid: pid_t) async -> MacRunningApp? {
        await MacAppControl.runningApp(pid: pid)
    }

    /// Owner, layer, and bounds are readable without Screen Recording; window titles are not, and aren't needed.
    func windows() async -> [MacWindowEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] else {
            return []
        }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer] as? NSNumber)?.intValue,
                  let bounds = (info[kCGWindowBounds] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else {
                return nil
            }
            return MacWindowEntry(pid: pid, layer: layer, bounds: bounds)
        }
    }

    func browsers() async -> MacBrowsers {
        await MacAppControl.browsers()
    }
}

/// Where input lands on a shared desktop, where the harness's own app is usually in front while an agent works.
enum MacAppFocus {
    /// Apps owning normal windows, front to back, each once.
    static func appsByWindowOrder(_ windows: [MacWindowEntry]) -> [pid_t] {
        var seen: Set<pid_t> = []
        return windows.filter { $0.layer == 0 && seen.insert($0.pid).inserted }.map(\.pid)
    }

    /// Whether input at `point` reaches the app `pid`: the point is over one of its windows and no other app's
    /// floating window covers it there. Other apps' normal windows don't count: events posted to the process go
    /// past them, and a foreground delivery activates the app first. `ownPID`'s windows let clicks through.
    static func point(_ point: CGPoint, landsOn pid: pid_t, windows: [MacWindowEntry], ignoring ownPID: pid_t) -> Bool {
        for window in windows where window.bounds.contains(point) && window.pid != ownPID {
            if window.pid == pid { return true }
            if window.layer != 0 { return false }
        }
        return false
    }

    /// The browser to open pages in: the default one when granted, else the first granted one installed.
    static func browser(granted: Set<String>, _ browsers: MacBrowsers) -> String? {
        if let preferred = browsers.defaultBundleID, granted.contains(preferred) { return preferred }
        return browsers.installed.first(where: granted.contains)
    }
}
#endif
