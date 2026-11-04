#if os(macOS)
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// When process-routed (background) events are known not to work, so a lease that allows the foreground uses it.
enum MacForegroundPolicy {
    /// Chromium browsers, whose web content takes a process-routed right-click as a left-click.
    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// Games and canvas apps (graphics and design), which ignore process-routed events.
    static func isCanvasOrGame(_ app: AppIdentity) -> Bool {
        guard let category = app.category?.lowercased() else { return false }
        return category.hasSuffix("games") || category == "public.app-category.graphics-design"
    }

    /// Whether `action` in `app` goes to the foreground from its first delivery.
    static func upFront(_ app: AppIdentity, for action: ComputerAction?) -> Bool {
        if isCanvasOrGame(app) { return true }
        if chromiumBundleIDs.contains(app.bundleID), case .click(_, .right, _, _)? = action { return true }
        return false
    }
}

/// A digest of what an app shows, compared before and after a background delivery to tell whether it landed.
protocol MacDeliveryProbing: Sendable {
    /// `nil` when the app's state can't be read.
    func state(of pid: pid_t, app: AppIdentity) async -> String?
}

/// The app's focused-window tree and the pixels of its front window.
struct LiveMacDeliveryProbe: MacDeliveryProbing {
    let accessibility: MacAccessibilityReader
    let capture: MacScreenCapture
    let workspace: any MacWorkspaceReading
    let grantedBundleIDs: @Sendable () async -> Set<String>
    let excludedBundleIDs: Set<String>

    func state(of pid: pid_t, app: AppIdentity) async -> String? {
        var hasher = Hasher()
        var read = false
        if let snapshot = await accessibility.snapshotFocusedWindow(pid: pid, app: app, observationID: "probe", budget: .default) {
            hasher.combine(snapshot.rendering.text)
            read = true
        }
        if let window = await workspace.windows().first(where: { $0.pid == pid && $0.layer == 0 }),
           let shot = try? await capture.captureRegion(window.bounds, grantedBundleIDs: await grantedBundleIDs(), excludedBundleIDs: excludedBundleIDs) {
            hasher.combine(shot.data)
            read = true
        }
        return read ? String(hasher.finalize()) : nil
    }
}
#endif
