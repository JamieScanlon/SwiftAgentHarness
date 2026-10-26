#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import SwiftAgentHarness
import UniformTypeIdentifiers

enum MacCaptureSizing {
    /// Pixels to capture for a rect in points: native resolution at most, scaled down to the long-edge and
    /// pixel-area caps.
    static func pixelSize(for rect: CGRect, nativeScale: CGFloat, maxLongEdge: Int?, maxPixels: Int? = nil) -> ImagePixelSize {
        let longEdge = max(rect.width, rect.height)
        guard longEdge > 0 else { return ImagePixelSize(width: 0, height: 0) }
        var scale = max(nativeScale, 1)
        if let maxLongEdge, maxLongEdge > 0 {
            scale = min(scale, CGFloat(maxLongEdge) / longEdge)
        }
        var areaBound = false
        if let maxPixels, maxPixels > 0, rect.width * rect.height * scale * scale > CGFloat(maxPixels) {
            scale = (CGFloat(maxPixels) / (rect.width * rect.height)).squareRoot()
            areaBound = true
        }
        // Rounding up could cross a vendor's hard pixel limit, so an area-bound size rounds down.
        let round: (CGFloat) -> Int = areaBound ? { Int($0.rounded(.down)) } : { Int($0.rounded()) }
        return ImagePixelSize(width: max(1, round(rect.width * scale)), height: max(1, round(rect.height * scale)))
    }

    static func geometry(capturedRect: CGRect, nativeScale: CGFloat, maxLongEdge: Int?, maxPixels: Int? = nil) -> ScreenshotGeometry {
        ScreenshotGeometry(
            capturedRect: DisplayRect(capturedRect),
            imageSize: pixelSize(for: capturedRect, nativeScale: nativeScale, maxLongEdge: maxLongEdge, maxPixels: maxPixels),
            scaleFactor: Double(nativeScale)
        )
    }

    static func capturedBundleIDs(granted: Set<String>, excluded: Set<String>) -> [String] {
        granted.subtracting(excluded).sorted()
    }
}

public enum MacCaptureError: Error, Sendable, Equatable {
    case noDisplay
    case windowGone(String)
    case nothingGrantedOnScreen
    case encodingFailed
}

/// The one owner of ScreenCaptureKit for the agent. Captures only granted apps' windows, never the harness's own,
/// and sizes each image to the model in the capture pipeline rather than in this process.
actor MacScreenCapture {
    struct Capture: Sendable {
        var data: Data
        var mediaType: String
        var geometry: ScreenshotGeometry
        var capturedAt: Date
    }

    private var cachedContent: SCShareableContent?
    private var cachedAt: Date?
    private let contentTTL: TimeInterval

    init(contentTTL: TimeInterval = 2) {
        self.contentTTL = contentTTL
    }

    /// Enumerating shareable content is the expensive call; it is cached briefly.
    func content() async throws -> SCShareableContent {
        if let cachedContent, let cachedAt, Date().timeIntervalSince(cachedAt) < contentTTL {
            return cachedContent
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        cachedContent = content
        cachedAt = Date()
        return content
    }

    func invalidate() {
        cachedContent = nil
    }

    /// A display, showing only the granted apps.
    func captureDisplay(
        displayID: CGDirectDisplayID?,
        grantedBundleIDs: Set<String>,
        excludedBundleIDs: Set<String>,
        maxLongEdge: Int?,
        maxPixels: Int? = nil
    ) async throws -> Capture {
        let content = try await content()
        guard let display = content.displays.first(where: { displayID == nil ? CGDisplayIsMain($0.displayID) != 0 : $0.displayID == displayID })
            ?? content.displays.first else { throw MacCaptureError.noDisplay }
        let included = Set(MacCaptureSizing.capturedBundleIDs(granted: grantedBundleIDs, excluded: excludedBundleIDs))
        let apps = content.applications.filter { included.contains($0.bundleIdentifier) }
        guard !apps.isEmpty else { throw MacCaptureError.nothingGrantedOnScreen }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        return try await capture(filter: filter, rect: display.frame, scale: CGFloat(filter.pointPixelScale), maxLongEdge: maxLongEdge, maxPixels: maxPixels)
    }

    /// One window, including when it is occluded or not frontmost.
    func captureWindow(windowID: CGWindowID, maxLongEdge: Int?, maxPixels: Int? = nil) async throws -> Capture {
        let content = try await content()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw MacCaptureError.windowGone(String(windowID))
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await capture(filter: filter, rect: window.frame, scale: CGFloat(filter.pointPixelScale), maxLongEdge: maxLongEdge, maxPixels: maxPixels)
    }

    /// A region of a display at full resolution, for zoom. Coordinates stay in the global space.
    func captureRegion(
        _ region: CGRect,
        grantedBundleIDs: Set<String>,
        excludedBundleIDs: Set<String>
    ) async throws -> Capture {
        let content = try await content()
        guard let display = content.displays.first(where: { $0.frame.intersects(region) }) else { throw MacCaptureError.noDisplay }
        let included = Set(MacCaptureSizing.capturedBundleIDs(granted: grantedBundleIDs, excluded: excludedBundleIDs))
        let apps = content.applications.filter { included.contains($0.bundleIdentifier) }
        guard !apps.isEmpty else { throw MacCaptureError.nothingGrantedOnScreen }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let clipped = region.intersection(display.frame)
        let local = clipped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return try await capture(filter: filter, rect: clipped, scale: CGFloat(filter.pointPixelScale), maxLongEdge: nil, sourceRect: local)
    }

    /// The window under a frontmost app, for pinning an observation to its window.
    func frontWindow(pid: pid_t) async throws -> SCWindow? {
        try await content().windows.first { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0 }
    }

    private func capture(
        filter: SCContentFilter,
        rect: CGRect,
        scale: CGFloat,
        maxLongEdge: Int?,
        maxPixels: Int? = nil,
        sourceRect: CGRect? = nil
    ) async throws -> Capture {
        let geometry = MacCaptureSizing.geometry(capturedRect: rect, nativeScale: scale, maxLongEdge: maxLongEdge, maxPixels: maxPixels)
        let configuration = SCStreamConfiguration()
        // Width and height are pixels; sizing here makes the capture pipeline do the downscale.
        configuration.width = geometry.imageSize.width
        configuration.height = geometry.imageSize.height
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        if let sourceRect { configuration.sourceRect = sourceRect }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        var recorded = geometry
        recorded.imageSize = ImagePixelSize(width: image.width, height: image.height)
        guard let data = Self.png(image) else { throw MacCaptureError.encodingFailed }
        return Capture(data: data, mediaType: "image/png", geometry: recorded, capturedAt: Date())
    }

    static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
#endif
