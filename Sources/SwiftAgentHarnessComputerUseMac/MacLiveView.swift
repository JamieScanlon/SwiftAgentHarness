#if os(macOS)
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// A live view of the user's own Mac that shows, and takes input for, granted apps only. Pure, so what is blanked
/// and what passes is testable without capturing or posting anything.
enum MacLiveView {
    /// The parts of granted windows that an ungranted window covers, in display points. A frame filtered to granted
    /// apps leaves the covering window out and draws the granted one as if it were in front, where a viewer's click
    /// would then be refused; blanking those parts shows where input won't land. Granted windows in front of the
    /// covering one stay visible. Fully transparent windows are ignored.
    static func occluders(windows: [MacWindowEntry], grantedPIDs: Set<pid_t>) -> [CGRect] {
        let visible = windows.filter { $0.alpha > 0 }
        var blanked: [CGRect] = []
        for (index, window) in visible.enumerated() where !grantedPIDs.contains(window.pid) {
            let inFront = visible[..<index].filter { grantedPIDs.contains($0.pid) }.map(\.bounds)
            for below in visible[(index + 1)...] where grantedPIDs.contains(below.pid) {
                let covered = window.bounds.intersection(below.bounds)
                guard !covered.isNull, !covered.isEmpty else { continue }
                blanked += inFront.reduce([covered]) { pieces, front in pieces.flatMap { subtract(front, from: $0) } }
            }
        }
        return blanked
    }

    /// `rect` without `hole`, as up to four rects.
    static func subtract(_ hole: CGRect, from rect: CGRect) -> [CGRect] {
        let cut = rect.intersection(hole)
        guard !cut.isNull, !cut.isEmpty else { return [rect] }
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
            CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
            CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    /// The window under `point`, front to back, ignoring fully transparent ones: where a foreground event lands.
    static func owner(at point: CGPoint, windows: [MacWindowEntry]) -> pid_t? {
        windows.first { $0.alpha > 0 && $0.bounds.contains(point) }?.pid
    }

    /// `image` with the blanked areas, given in display points, painted over.
    static func painting(_ image: CGImage, occluders: [CGRect], space: MacLiveFrameSpace) -> CGImage? {
        guard !occluders.isEmpty else { return image }
        guard let context = context(width: image.width, height: image.height) else { return nil }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: full)
        context.setFillColor(gray: 0.35, alpha: 1)
        for rect in occluders {
            let pixels = space.pixelRect(for: rect).intersection(full)
            guard !pixels.isNull, !pixels.isEmpty else { continue }
            // Core Graphics counts rows from the bottom; the display counts them from the top.
            context.fill(CGRect(x: pixels.minX, y: CGFloat(image.height) - pixels.maxY, width: pixels.width, height: pixels.height))
        }
        return context.makeImage()
    }

    /// A plain frame, for when no granted app has a window on screen.
    static func blank(size: ImagePixelSize, gray: CGFloat = 0.35) -> CGImage? {
        guard let context = context(width: max(size.width, 1), height: max(size.height, 1)) else { return nil }
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage()
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }
}

/// Where a viewer's input may go on the user's own Mac during a takeover: granted apps only.
struct MacLiveInputGate {
    /// Processes of granted apps, other than this one and the excluded apps.
    var grantedPIDs: Set<pid_t>
    /// On-screen windows, front to back.
    var windows: [MacWindowEntry]
    var frontmost: pid_t?
    /// The frontmost app's grant flags, for global shortcuts.
    var frontmostFlags: Set<ComputerUseGrantFlag>
    var systemShortcuts: Set<KeyCombo>

    /// A pointer event at `point` reaches the window on top there, which must be a granted app's. The harness's own
    /// windows count as ungranted: a viewer's click doesn't bring the target app forward first, as the agent's
    /// foreground delivery does, so it would land on them.
    func allows(point: CGPoint) -> Bool {
        MacLiveView.owner(at: point, windows: windows).map(grantedPIDs.contains) ?? false
    }

    /// Keys and text go to the frontmost app, which must be granted.
    var allowsKeys: Bool {
        frontmost.map(grantedPIDs.contains) ?? false
    }

    /// The system handles global shortcuts whatever app is in front, so they need the grant's system-keys flag.
    func allows(_ combos: [KeyCombo]) -> Bool {
        let global = combos.contains { systemShortcuts.contains($0) || $0.modifiers.contains(.fn) }
        return !global || frontmostFlags.contains(.systemKeys)
    }
}
#endif
