import EasyJSON
import Foundation
import Logging

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

enum ToolResultInlineImageSanitizer {
    enum Mode: Sendable {
        case sanitize
        case strip
    }

    struct Policy: Sendable {
        let mode: Mode
        let maxPixelDimension: Int
        let maxBytes: Int
        let placeholder: String
    }

    private static let dataURLPattern = #"data:image\/([a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/=\r\n]+)"#

    static func sanitizeString(
        _ content: String,
        policy: Policy,
        processor: ImageProcessing,
        logger: Logger?
    ) -> String {
        switch policy.mode {
        case .strip:
            return stripInlineImagePayloads(content, placeholder: policy.placeholder)
        case .sanitize:
            return transformInlineImagePayloads(
                content,
                policy: policy,
                processor: processor,
                logger: logger
            )
        }
    }

    static func sanitizeJSON(
        _ json: JSON,
        policy: Policy,
        processor: ImageProcessing,
        logger: Logger?
    ) -> JSON {
        switch json {
        case .string(let value):
            return .string(sanitizeString(value, policy: policy, processor: processor, logger: logger))
        case .array(let values):
            return .array(values.map { sanitizeJSON($0, policy: policy, processor: processor, logger: logger) })
        case .object(let object):
            var shaped: [String: JSON] = [:]
            for (key, value) in object {
                shaped[key] = sanitizeJSON(value, policy: policy, processor: processor, logger: logger)
            }
            return .object(shaped)
        default:
            return json
        }
    }

    private static func stripInlineImagePayloads(_ content: String, placeholder: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: dataURLPattern) else { return content }
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: nsRange, withTemplate: placeholder)
    }

    private static func transformInlineImagePayloads(
        _ content: String,
        policy: Policy,
        processor: ImageProcessing,
        logger: Logger?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: dataURLPattern) else { return content }
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)
        guard !matches.isEmpty else { return content }

        var result = ""
        var cursor = content.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: content) else { continue }
            result.append(contentsOf: content[cursor..<matchRange.lowerBound])
            let matched = String(content[matchRange])
            let replacement = sanitizeDataURLMatch(
                matched,
                match: match,
                in: content,
                policy: policy,
                processor: processor,
                logger: logger
            )
            result.append(replacement)
            cursor = matchRange.upperBound
        }
        result.append(contentsOf: content[cursor...])
        return result
    }

    private static func sanitizeDataURLMatch(
        _ matched: String,
        match: NSTextCheckingResult,
        in content: String,
        policy: Policy,
        processor: ImageProcessing,
        logger: Logger?
    ) -> String {
        guard match.numberOfRanges >= 3,
              let declaredRange = Range(match.range(at: 1), in: content),
              let payloadRange = Range(match.range(at: 2), in: content) else {
            return failureMarker(placeholder: policy.placeholder, reason: "malformed data URL")
        }

        let declaredMime = normalizeMime(String(content[declaredRange]))
        let canonicalBase64 = canonicalizeBase64(String(content[payloadRange]))
        guard !canonicalBase64.isEmpty else {
            return failureMarker(placeholder: policy.placeholder, reason: "empty base64 payload")
        }
        guard let decoded = Data(base64Encoded: canonicalBase64) else {
            return failureMarker(placeholder: policy.placeholder, reason: "undecodable base64")
        }
        guard let inferredMime = inferMime(from: decoded) else {
            return failureMarker(placeholder: policy.placeholder, reason: "unrecognized image format")
        }

        if isAlreadySanitized(
            declaredMime: declaredMime,
            inferredMime: inferredMime,
            data: decoded,
            canonicalBase64: canonicalBase64,
            matched: matched,
            policy: policy
        ) {
            return matched
        }

        var processed = decoded
        if policy.maxPixelDimension > 0,
           let scaled = processor.scaleImage(processed, maxPixelDimension: policy.maxPixelDimension) {
            processed = scaled
        } else if policy.maxPixelDimension > 0,
                  imageMaxPixelDimension(data: processed) ?? 0 > policy.maxPixelDimension {
            return failureMarker(placeholder: policy.placeholder, reason: "image exceeds dimension cap")
        }

        if policy.maxBytes > 0 {
            if let scaled = processor.scaleImageToFileSize(processed, maxFileSize: policy.maxBytes) {
                processed = scaled
            } else if processed.count > policy.maxBytes {
                return failureMarker(placeholder: policy.placeholder, reason: "image exceeds byte cap")
            }
        }

        let outputBase64 = processed.base64EncodedString()
        let outputDataURL = "data:\(inferredMime);base64,\(outputBase64)"
        logger?.info(
            "[ToolResultInlineImage] sanitized declared=\(declaredMime) inferred=\(inferredMime) sourceBytes=\(decoded.count) outputBytes=\(processed.count)"
        )
        return outputDataURL
    }

    private static func isAlreadySanitized(
        declaredMime: String,
        inferredMime: String,
        data: Data,
        canonicalBase64: String,
        matched: String,
        policy: Policy
    ) -> Bool {
        guard declaredMime == inferredMime else { return false }
        guard policy.maxBytes <= 0 || data.count <= policy.maxBytes else { return false }
        guard policy.maxPixelDimension <= 0
            || (imageMaxPixelDimension(data: data) ?? Int.max) <= policy.maxPixelDimension else {
            return false
        }
        guard matched.contains(";\(canonicalBase64)") || matched.hasSuffix(canonicalBase64) else {
            return false
        }
        return true
    }

    private static func canonicalizeBase64(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func normalizeMime(_ mime: String) -> String {
        mime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func failureMarker(placeholder: String, reason: String) -> String {
        "\(placeholder): \(reason)"
    }

    private static func inferMime(from data: Data) -> String? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let utType = CGImageSourceGetType(source) {
            return mimeType(fromUTType: utType as String)
        }
        #endif
        return sniffMime(from: data)
    }

    private static func imageMaxPixelDimension(data: Data) -> Int? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return max(width, height)
        #else
        return nil
        #endif
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    private static func mimeType(fromUTType utType: String) -> String? {
        switch utType {
        case "public.png", "image/png":
            return "image/png"
        case "public.jpeg", "image/jpeg":
            return "image/jpeg"
        case "com.compuserve.gif", "image/gif":
            return "image/gif"
        case "org.webmproject.webp", "public.webp", "image/webp":
            return "image/webp"
        default:
            if utType.hasPrefix("public.") {
                return utType.replacingOccurrences(of: "public.", with: "image/")
            }
            return nil
        }
    }
    #endif

    private static func sniffMime(from data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
           bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
           bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A {
            return "image/png"
        }
        if bytes.count >= 3,
           bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 6 {
            let prefix = String(bytes: bytes.prefix(6), encoding: .ascii)
            if prefix == "GIF87a" || prefix == "GIF89a" {
                return "image/gif"
            }
        }
        if bytes.count >= 12 {
            let riff = String(bytes: bytes.prefix(4), encoding: .ascii)
            let webp = String(bytes: bytes[8..<12], encoding: .ascii)
            if riff == "RIFF", webp == "WEBP" {
                return "image/webp"
            }
        }
        return nil
    }
}
