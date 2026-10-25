import Foundation

/// A point in a display target's global space, in logical points (top-left origin, y down).
public struct DisplayPoint: Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in a display target's global space, in logical points.
public struct DisplayRect: Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: DisplayPoint { DisplayPoint(x: x + width / 2, y: y + height / 2) }

    public func contains(_ point: DisplayPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}

public struct ImagePixelSize: Sendable, Codable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// The geometry of one screenshot the harness sent to a model. Every image carries one, and model coordinates are
/// mapped back to logical points through it.
public struct ScreenshotGeometry: Sendable, Codable, Hashable {
    /// The captured region in the target's global space.
    public var capturedRect: DisplayRect
    /// Pixels actually sent to the model, after harness-side resizing.
    public var imageSize: ImagePixelSize
    /// Backing scale factor of the captured display.
    public var scaleFactor: Double

    public init(capturedRect: DisplayRect, imageSize: ImagePixelSize, scaleFactor: Double) {
        self.capturedRect = capturedRect
        self.imageSize = imageSize
        self.scaleFactor = scaleFactor
    }

    public func toGlobal(_ imagePoint: DisplayPoint) -> DisplayPoint {
        DisplayPoint(
            x: capturedRect.minX + imagePoint.x * capturedRect.width / Double(max(1, imageSize.width)),
            y: capturedRect.minY + imagePoint.y * capturedRect.height / Double(max(1, imageSize.height))
        )
    }

    public func toImage(_ globalPoint: DisplayPoint) -> DisplayPoint {
        DisplayPoint(
            x: (globalPoint.x - capturedRect.minX) * Double(imageSize.width) / max(capturedRect.width, .leastNonzeroMagnitude),
            y: (globalPoint.y - capturedRect.minY) * Double(imageSize.height) / max(capturedRect.height, .leastNonzeroMagnitude)
        )
    }
}

/// How the model expresses coordinates. Fixed for the lifetime of a computer-use session, so the convention the
/// model read in its tool description and the scaling the codec applies can never disagree.
public enum ComputerUseCoordinateMode: String, Sendable, Codable, Hashable {
    /// Pixels of the image the harness sent.
    case imagePixels = "image-pixels"
    /// A 0–999 grid over the captured region, independent of image size.
    case normalized1000 = "normalized-1000"
}

public enum ComputerUseCoordinateError: Error, Sendable, Equatable {
    case nonFinite
    case outOfBounds(x: Double, y: Double)
}

/// Maps model-emitted coordinates to logical points. The model never sees a scale factor.
public struct ComputerUseCoordinateCodec: Sendable, Hashable {
    public static let normalizedGridSize: Double = 1000

    public let mode: ComputerUseCoordinateMode

    public init(mode: ComputerUseCoordinateMode) {
        self.mode = mode
    }

    public func decode(x: Double, y: Double, geometry: ScreenshotGeometry) throws(ComputerUseCoordinateError) -> DisplayPoint {
        guard x.isFinite, y.isFinite else { throw .nonFinite }
        let limits = limits(for: geometry)
        let inBounds: Bool
        switch mode {
        case .imagePixels: inBounds = x >= 0 && y >= 0 && x <= limits.width && y <= limits.height
        case .normalized1000: inBounds = x >= 0 && y >= 0 && x < limits.width && y < limits.height
        }
        guard inBounds else { throw .outOfBounds(x: x, y: y) }
        return map(x: x, y: y, geometry: geometry)
    }

    private func limits(for geometry: ScreenshotGeometry) -> (width: Double, height: Double) {
        switch mode {
        case .imagePixels: return (Double(geometry.imageSize.width), Double(geometry.imageSize.height))
        case .normalized1000: return (Self.normalizedGridSize, Self.normalizedGridSize)
        }
    }

    private func map(x: Double, y: Double, geometry: ScreenshotGeometry) -> DisplayPoint {
        switch mode {
        case .imagePixels:
            return geometry.toGlobal(DisplayPoint(x: x, y: y))
        case .normalized1000:
            let rect = geometry.capturedRect
            let grid = Self.normalizedGridSize
            return DisplayPoint(x: rect.minX + x / grid * rect.width, y: rect.minY + y / grid * rect.height)
        }
    }

    public func decodeRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        geometry: ScreenshotGeometry
    ) throws(ComputerUseCoordinateError) -> DisplayRect {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw .outOfBounds(x: width, y: height) }
        let topLeft = try decode(x: x, y: y, geometry: geometry)
        let limits = limits(for: geometry)
        guard x + width <= limits.width, y + height <= limits.height else {
            throw .outOfBounds(x: x + width, y: y + height)
        }
        let bottomRight = map(x: x + width, y: y + height, geometry: geometry)
        return DisplayRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }
}
