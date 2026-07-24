import Foundation
import Testing
@testable import SwiftAgentHarness

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

@Suite("Attachment vision image sanitizer")
struct AttachmentVisionImageSanitizerTests {
    @Test("returns scaled bytes when processor shrinks the image")
    func returnsScaledBytes() {
        let original = Data(repeating: 0x11, count: 1_000_000)
        let scaled = Data(repeating: 0x22, count: 50_000)
        let processor = AttachmentSanitizerMockImageProcessor(
            scaleResult: scaled,
            scaleToFileSizeResult: scaled
        )
        let result = AttachmentVisionImageSanitizer.sanitize(
            original,
            maxPixelDimension: 1_200,
            maxBytes: 256_000,
            processor: processor
        )
        #expect(result == scaled)
    }

    @Test("returns nil when image cannot fit byte cap")
    func returnsNilWhenOverByteCap() {
        let original = Data(repeating: 0x33, count: 500_000)
        let processor = AttachmentSanitizerMockImageProcessor(
            scaleResult: original,
            scaleToFileSizeResult: nil
        )
        let result = AttachmentVisionImageSanitizer.sanitize(
            original,
            maxPixelDimension: 1_200,
            maxBytes: 256_000,
            processor: processor
        )
        #expect(result == nil)
    }

    @Test("passthrough when already under caps and scale is a no-op")
    func passthroughUnderCaps() {
        let original = Data("tiny".utf8)
        let processor = AttachmentSanitizerMockImageProcessor(
            scaleResult: .some(nil),
            scaleToFileSizeResult: nil
        )
        let result = AttachmentVisionImageSanitizer.sanitize(
            original,
            maxPixelDimension: 1_200,
            maxBytes: 256_000,
            processor: processor
        )
        #expect(result == original)
    }

#if canImport(CoreGraphics) && canImport(ImageIO)
    @Test("default processor keeps projected JPEG under image budget")
    func defaultProcessorFitsImageBudget() throws {
        let jpeg = try #require(Self.makeStripedJPEG(width: 2048, height: 2730, quality: 0.92))
        #expect(jpeg.count > 256_000)
        let result = try #require(
            AttachmentVisionImageSanitizer.sanitize(
                jpeg,
                maxPixelDimension: 1_200,
                maxBytes: 5_000_000,
                processor: DefaultImageProcessor()
            )
        )
        #expect(!result.isEmpty)
        #expect(result.count <= 5_000_000)
        let maxDim = try #require(Self.maxPixelDimension(of: result))
        #expect(maxDim <= 1_200)
    }

    private static func makeStripedJPEG(width: Int, height: Int, quality: CGFloat) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        for y in 0..<height {
            let t = CGFloat(y % 256) / 255.0
            context.setFillColor(red: t, green: 1.0 - t, blue: CGFloat((y * 3) % 256) / 255.0, alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func maxPixelDimension(of data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return max(width, height)
    }
#endif
}

private struct AttachmentSanitizerMockImageProcessor: ImageProcessing {
    var scaleResult: Data??
    var scaleToFileSizeResult: Data?

    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data? { data }

    func scaleImage(_ data: Data, maxPixelDimension: Int) -> Data? {
        if let explicit = scaleResult {
            return explicit
        }
        return data
    }

    func scaleImageToFileSize(_ data: Data, maxFileSize: Int) -> Data? {
        if let explicit = scaleToFileSizeResult { return explicit }
        return data.count <= maxFileSize ? data : nil
    }
}
