import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Decode, downscale, and PNG-encode helpers for images the harness derives from observations (approval-card
/// crops and replay thumbnails). Never used on the screenshot the model sees, whose geometry must not change.
enum ComputerUseImageEncoding {
    /// `data` scaled so its long edge is at most `maxEdgePx`, as PNG. `nil` when it can't be decoded.
    static func thumbnail(of data: Data, maxEdgePx: Int, alt: String) -> PresentationImage? {
        #if canImport(ImageIO)
        guard let image = decode(data) else { return nil }
        return png(scaled(image, maxEdgePx: maxEdgePx), alt: alt)
        #else
        return nil
        #endif
    }

    #if canImport(ImageIO)
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func scaled(_ image: CGImage, maxEdgePx: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxEdgePx, maxEdgePx > 0 else { return image }
        let factor = Double(maxEdgePx) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func png(_ image: CGImage, alt: String) -> PresentationImage? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PresentationImage(data: encoded as Data, mediaType: "image/png", width: image.width, height: image.height, alt: alt)
    }
    #endif
}
