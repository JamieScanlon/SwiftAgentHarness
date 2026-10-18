import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Resizes image assets into a binding's declared window before sending. Out-of-range images are rejected by the
/// reference vendor rather than resized, so the codec does it.
public enum DecisionImageNormalizer {
    public struct Window: Sendable, Equatable {
        public var edgePx: ClosedRange<Int>
        public var totalPixels: ClosedRange<Int>

        public init(edgePx: ClosedRange<Int>, totalPixels: ClosedRange<Int>) {
            self.edgePx = edgePx
            self.totalPixels = totalPixels
        }
    }

    /// Scale factor that brings `(width, height)` inside `window`, or `nil` when no uniform scale can.
    public static func scale(width: Int, height: Int, window: Window) -> Double? {
        guard width > 0, height > 0 else { return nil }
        let w = Double(width)
        let h = Double(height)
        let area = w * h
        let upper = min(
            Double(window.edgePx.upperBound) / max(w, h),
            (Double(window.totalPixels.upperBound) / area).squareRoot()
        )
        let lower = max(
            Double(window.edgePx.lowerBound) / min(w, h),
            (Double(window.totalPixels.lowerBound) / area).squareRoot()
        )
        guard lower <= upper else { return nil }
        return min(max(1.0, lower), upper)
    }

    public static func normalize(_ asset: DecisionImageAsset, window: Window) throws -> DecisionImageAsset {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw DecisionProviderError.image("undecodable \(asset.mediaType.rawValue) asset")
        }
        guard let factor = scale(width: image.width, height: image.height, window: window) else {
            throw DecisionProviderError.image("aspect ratio \(image.width)x\(image.height) cannot fit the image window")
        }
        if factor == 1.0 { return asset }
        let width = max(1, Int((Double(image.width) * factor).rounded(.down)))
        let height = max(1, Int((Double(image.height) * factor).rounded(.down)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DecisionProviderError.image("could not allocate \(width)x\(height) context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else {
            throw DecisionProviderError.image("resize failed")
        }
        let output = NSMutableData()
        let type = asset.mediaType == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else {
            throw DecisionProviderError.image("could not create encoder")
        }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DecisionProviderError.image("encode failed")
        }
        return DecisionImageAsset(mediaType: asset.mediaType, data: output as Data)
        #else
        return asset
        #endif
    }

    /// Pixel dimensions of an encoded image, when decodable.
    public static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image.width, image.height)
        #else
        return nil
        #endif
    }
}
