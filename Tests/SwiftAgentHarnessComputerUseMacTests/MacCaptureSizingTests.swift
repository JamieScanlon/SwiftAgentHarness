#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

@Suite("macOS capture sizing")
struct MacCaptureSizingTests {
    @Test("A capture is scaled to the long-edge cap, keeping the aspect ratio")
    func scalesToCap() {
        let size = MacCaptureSizing.pixelSize(for: CGRect(x: 0, y: 0, width: 1512, height: 982), nativeScale: 2, maxLongEdge: 1200)
        #expect(size == ImagePixelSize(width: 1200, height: 779))
    }

    @Test("A pixel-area cap shrinks the capture below it, keeping the aspect ratio")
    func pixelCap() {
        let size = MacCaptureSizing.pixelSize(
            for: CGRect(x: 0, y: 0, width: 1512, height: 982), nativeScale: 2, maxLongEdge: 1568, maxPixels: 1_150_000
        )
        #expect(size.width * size.height <= 1_150_000)
        #expect(size.width >= 1_320 && size.width <= 1_331)
        #expect(abs(Double(size.width) / Double(size.height) - 1512.0 / 982.0) < 0.01)
    }

    @Test("It never upscales past the display's native resolution")
    func neverUpscales() {
        let size = MacCaptureSizing.pixelSize(for: CGRect(x: 0, y: 0, width: 400, height: 300), nativeScale: 1, maxLongEdge: 1568)
        #expect(size == ImagePixelSize(width: 400, height: 300))
    }

    @Test("Without a cap a capture is full native resolution, for zoom")
    func fullResolution() {
        let size = MacCaptureSizing.pixelSize(for: CGRect(x: 0, y: 0, width: 300, height: 100), nativeScale: 2, maxLongEdge: nil)
        #expect(size == ImagePixelSize(width: 600, height: 200))
    }

    @Test("The recorded geometry is the rect the image was sized from, so model pixels map back exactly")
    func geometry() {
        let rect = CGRect(x: -1920, y: 40, width: 1920, height: 1080)
        let geometry = MacCaptureSizing.geometry(capturedRect: rect, nativeScale: 2, maxLongEdge: 1280)
        #expect(geometry.capturedRect == DisplayRect(rect))
        #expect(geometry.imageSize == ImagePixelSize(width: 1280, height: 720))
        #expect(geometry.scaleFactor == 2)
        let corner = geometry.toGlobal(DisplayPoint(x: 1280, y: 720))
        #expect(abs(corner.x - 0) < 0.001)
        #expect(abs(corner.y - 1120) < 0.001)
    }

    @Test("The harness's own apps are never captured, even when granted")
    func exclusion() {
        let included = MacCaptureSizing.capturedBundleIDs(
            granted: ["com.apple.TextEdit", "com.example.harness", "com.apple.Safari"],
            excluded: ["com.example.harness"]
        )
        #expect(included == ["com.apple.Safari", "com.apple.TextEdit"])
    }
}
#endif
