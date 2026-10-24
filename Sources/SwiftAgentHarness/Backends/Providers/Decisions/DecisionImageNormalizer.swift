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
        let image = try decode(asset)
        guard let factor = scale(width: image.width, height: image.height, window: window) else {
            throw DecisionProviderError.image("aspect ratio \(image.width)x\(image.height) cannot fit the image window")
        }
        if factor == 1.0 { return asset }
        return try encode(resize(image, factor: factor), mediaType: asset.mediaType, quality: nil)
        #else
        return asset
        #endif
    }

    /// Re-encodes `asset` at `factor` of its size (JPEG also at lower quality) to get under a body-size cap.
    /// Never shrinks below the window's minimums. Returns `nil` when the result would not be smaller.
    public static func shrink(_ asset: DecisionImageAsset, factor: Double = 0.5, window: Window?) throws -> DecisionImageAsset? {
        #if canImport(ImageIO)
        let image = try decode(asset)
        var applied = factor
        if let window {
            let minEdge = Double(min(image.width, image.height))
            let area = Double(image.width * image.height)
            let floor = max(
                Double(window.edgePx.lowerBound) / minEdge,
                (Double(window.totalPixels.lowerBound) / area).squareRoot()
            )
            applied = max(applied, floor)
        }
        guard applied < 1.0 else { return nil }
        let shrunk = try encode(resize(image, factor: applied), mediaType: asset.mediaType, quality: asset.mediaType == .jpeg ? 0.7 : nil)
        return shrunk.data.count < asset.data.count ? shrunk : nil
        #else
        return nil
        #endif
    }

    #if canImport(ImageIO)
    private static func decode(_ asset: DecisionImageAsset) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw DecisionProviderError.image("undecodable \(asset.mediaType.rawValue) asset")
        }
        return image
    }

    private static func resize(_ image: CGImage, factor: Double) throws -> CGImage {
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
        return resized
    }

    private static func encode(_ image: CGImage, mediaType: DecisionImageAsset.MediaType, quality: Double?) throws -> DecisionImageAsset {
        let output = NSMutableData()
        let type = mediaType == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else {
            throw DecisionProviderError.image("could not create encoder")
        }
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw DecisionProviderError.image("encode failed")
        }
        return DecisionImageAsset(mediaType: mediaType, data: output as Data)
    }
    #endif

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
