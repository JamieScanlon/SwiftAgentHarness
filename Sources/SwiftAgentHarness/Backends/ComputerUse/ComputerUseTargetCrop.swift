import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// The cropped screen region an approval card shows for the action it asks about, cut from the observation the
/// action cites.
enum ComputerUseTargetCrop {
    /// Smallest region shown, in points, so a small control keeps enough surroundings to recognize.
    static let minimumRegion = (width: 240.0, height: 140.0)
    static let paddingPoints = 16.0
    static let maximumEdgePx = 480

    /// The region `action` lands on, in the observation's global space: the element's padded frame, or a box
    /// around a point. `nil` when the action has no located target.
    static func region(for action: ComputerAction, in observation: DisplayObservation) -> DisplayRect? {
        guard let target = action.citedTargets.first(where: { $0.observation == observation.id }) else { return nil }
        let focus: DisplayRect
        switch target {
        case .ref(let ref, _):
            guard let frame = observation.tree?.elements[ref]?.frame else { return nil }
            focus = DisplayRect(
                x: frame.x - paddingPoints,
                y: frame.y - paddingPoints,
                width: frame.width + 2 * paddingPoints,
                height: frame.height + 2 * paddingPoints
            )
        case .point(let point, _):
            focus = DisplayRect(x: point.x, y: point.y, width: 0, height: 0)
        }
        let width = max(focus.width, minimumRegion.width)
        let height = max(focus.height, minimumRegion.height)
        let region = DisplayRect(x: focus.center.x - width / 2, y: focus.center.y - height / 2, width: width, height: height)
        let bounds = observation.image?.geometry.capturedRect ?? observation.target.bounds
        return clamp(region, to: bounds)
    }

    /// `region` cut from the observation's screenshot, scaled to at most ``maximumEdgePx``. `nil` when the
    /// observation carries no pixels or the region misses them.
    static func image(of region: DisplayRect, in observation: DisplayObservation, alt: String) -> PresentationImage? {
        #if canImport(ImageIO)
        guard let observationImage = observation.image, let data = observationImage.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let screenshot = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let geometry = observationImage.geometry
        // Map through the recorded geometry, then onto the decoded bitmap in case it differs from `imageSize`.
        let origin = geometry.toImage(DisplayPoint(x: region.minX, y: region.minY))
        let corner = geometry.toImage(DisplayPoint(x: region.maxX, y: region.maxY))
        let sx = Double(screenshot.width) / Double(max(1, geometry.imageSize.width))
        let sy = Double(screenshot.height) / Double(max(1, geometry.imageSize.height))
        let pixels = CGRect(
            x: origin.x * sx,
            y: origin.y * sy,
            width: (corner.x - origin.x) * sx,
            height: (corner.y - origin.y) * sy
        ).integral.intersection(CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1, var crop = screenshot.cropping(to: pixels) else { return nil }

        let longEdge = max(crop.width, crop.height)
        if longEdge > maximumEdgePx {
            let factor = Double(maximumEdgePx) / Double(longEdge)
            let width = max(1, Int((Double(crop.width) * factor).rounded()))
            let height = max(1, Int((Double(crop.height) * factor).rounded()))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            crop = scaled
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, crop, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PresentationImage(data: encoded as Data, mediaType: "image/png", width: crop.width, height: crop.height, alt: alt)
        #else
        return nil
        #endif
    }

    private static func clamp(_ region: DisplayRect, to bounds: DisplayRect) -> DisplayRect {
        let width = min(region.width, bounds.width)
        let height = min(region.height, bounds.height)
        let x = min(max(region.x, bounds.minX), bounds.maxX - width)
        let y = min(max(region.y, bounds.minY), bounds.maxY - height)
        return DisplayRect(x: x, y: y, width: width, height: height)
    }
}
