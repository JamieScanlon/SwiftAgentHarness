import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

private struct SanitizerMockImageProcessor: ImageProcessing {
    var thumbnailResult: Data?
    var scaleResult: Data??
    var scaleToFileSizeResult: Data?

    init(
        thumbnailResult: Data? = nil,
        scaleResult: Data?? = .none,
        scaleToFileSizeResult: Data? = nil
    ) {
        self.thumbnailResult = thumbnailResult
        self.scaleResult = scaleResult
        self.scaleToFileSizeResult = scaleToFileSizeResult
    }

    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data? {
        thumbnailResult
    }

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

@Suite("Tool result inline image sanitizer")
struct ToolResultInlineImageSanitizerTests {
    private let tinyPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private func sanitizePolicy(
        mode: ToolResultInlineImageSanitizer.Mode = .sanitize,
        maxPixelDimension: Int = 1_200,
        maxBytes: Int = 5_000_000,
        placeholder: String = "[inline image payload omitted]"
    ) -> ToolResultInlineImageSanitizer.Policy {
        ToolResultInlineImageSanitizer.Policy(
            mode: mode,
            maxPixelDimension: maxPixelDimension,
            maxBytes: maxBytes,
            placeholder: placeholder
        )
    }

    @Test("strip mode replaces data URLs with placeholder")
    func stripMode() {
        let input = "prefix data:image/png;base64,\(tinyPNGBase64) suffix"
        let output = ToolResultInlineImageSanitizer.sanitizeString(
            input,
            policy: sanitizePolicy(mode: .strip),
            processor: SanitizerMockImageProcessor(),
            logger: nil
        )
        #expect(output.contains("[inline image payload omitted]"))
        #expect(!output.contains("data:image/png;base64"))
    }

    @Test("canonicalize removes whitespace from base64 payload")
    func canonicalizeWhitespace() {
        let mid = tinyPNGBase64.index(tinyPNGBase64.startIndex, offsetBy: tinyPNGBase64.count / 2)
        let spaced = String(tinyPNGBase64[..<mid]) + "\n" + String(tinyPNGBase64[mid...])
        let input = "data:image/png;base64,\(spaced)"
        let output = ToolResultInlineImageSanitizer.sanitizeString(
            input,
            policy: sanitizePolicy(),
            processor: SanitizerMockImageProcessor(),
            logger: nil
        )
        #expect(output.contains("data:image/png;base64,\(tinyPNGBase64)"))
    }

    @Test("undecodable base64 degrades to failure marker")
    func undecodableBase64() {
        let input = "data:image/png;base64,==="
        let output = ToolResultInlineImageSanitizer.sanitizeString(
            input,
            policy: sanitizePolicy(),
            processor: SanitizerMockImageProcessor(),
            logger: nil
        )
        #expect(output.contains("[inline image payload omitted]: undecodable base64"))
    }

    @Test("magic bytes override declared MIME type")
    func magicByteMimeOverride() {
        let input = "shot data:image/jpeg;base64,\(tinyPNGBase64) end"
        let output = ToolResultInlineImageSanitizer.sanitizeString(
            input,
            policy: sanitizePolicy(),
            processor: SanitizerMockImageProcessor(),
            logger: nil
        )
        #expect(output.contains("data:image/png;base64,"))
        #expect(!output.contains("data:image/jpeg;base64"))
    }

    @Test("processor resize ladder output is re-embedded")
    func resizeLadder() {
        let tinyData = Data(base64Encoded: tinyPNGBase64)!
        let compressed = Data([0x01, 0x02, 0x03, 0x04])
        let processor = SanitizerMockImageProcessor(
            scaleResult: .some(tinyData),
            scaleToFileSizeResult: compressed
        )
        let input = "data:image/png;base64,\(tinyPNGBase64)"
        let output = ToolResultInlineImageSanitizer.sanitizeString(
            input,
            policy: sanitizePolicy(maxBytes: 4),
            processor: processor,
            logger: nil
        )
        #expect(output.contains("data:image/png;base64,"))
        #expect(output.contains(compressed.base64EncodedString()))
    }

    @Test("processor failure degrades to marker without throwing")
    func processorFailureDegrades() {
        let tinyData = Data(base64Encoded: tinyPNGBase64)!
        let processor = SanitizerMockImageProcessor(
            scaleResult: .some(tinyData),
            scaleToFileSizeResult: nil
        )
        let input = "data:image/png;base64,\(tinyPNGBase64)"
        let output = ToolResultInlineImageSanitizer.sanitizeString(
            input,
            policy: sanitizePolicy(maxBytes: 4),
            processor: processor,
            logger: nil
        )
        #expect(output.contains("[inline image payload omitted]: image exceeds byte cap"))
    }

    @Test("second sanitize pass is idempotent for already-sanitized payload")
    func idempotency() {
        let input = "data:image/png;base64,\(tinyPNGBase64)"
        let policy = sanitizePolicy()
        let processor = SanitizerMockImageProcessor()
        let first = ToolResultInlineImageSanitizer.sanitizeString(
            input,
            policy: policy,
            processor: processor,
            logger: nil
        )
        let second = ToolResultInlineImageSanitizer.sanitizeString(
            first,
            policy: policy,
            processor: processor,
            logger: nil
        )
        #expect(first == second)
    }

    @Test("metadata JSON strings are sanitized recursively")
    func metadataJSON() {
        let metadata: JSON = .object([
            "image": .string("data:image/png;base64,\(tinyPNGBase64)"),
        ])
        let output = ToolResultInlineImageSanitizer.sanitizeJSON(
            metadata,
            policy: sanitizePolicy(mode: .strip),
            processor: SanitizerMockImageProcessor(),
            logger: nil
        )
        guard case .object(let object) = output,
              case .string(let image) = object["image"] else {
            Issue.record("Expected sanitized metadata object")
            return
        }
        #expect(image == "[inline image payload omitted]")
    }
}
