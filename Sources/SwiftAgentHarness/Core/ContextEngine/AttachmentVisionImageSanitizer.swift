import Foundation

/// Downscale / recompress attachment image bytes for vision projection.
///
/// Mirrors the tool-result sanitization ladder (pixel cap, then byte cap) on raw `Data`
/// so oversize catalog blobs can still reach multimodal encoders as `.inline`.
enum AttachmentVisionImageSanitizer {
    static func sanitize(
        _ data: Data,
        maxPixelDimension: Int,
        maxBytes: Int,
        processor: ImageProcessing
    ) -> Data? {
        guard !data.isEmpty else { return nil }
        var processed = data
        if maxPixelDimension > 0,
           let scaled = processor.scaleImage(processed, maxPixelDimension: maxPixelDimension) {
            processed = scaled
        }
        if maxBytes > 0 {
            if let scaled = processor.scaleImageToFileSize(processed, maxFileSize: maxBytes) {
                processed = scaled
            } else if processed.count > maxBytes {
                return nil
            }
        }
        return processed
    }
}
