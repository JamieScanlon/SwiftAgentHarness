import Foundation

public enum InlineImageProtocol: String, Sendable {
    case kitty
    case iterm2
    case textFallback
}

public struct InlineImageCapabilities: Sendable, Equatable {
    public var kitty: Bool
    public var iterm2: Bool

    public init(kitty: Bool = false, iterm2: Bool = false) {
        self.kitty = kitty
        self.iterm2 = iterm2
    }

    public static let none = InlineImageCapabilities()
}

public struct InlineImage: Sendable, Equatable {
    public var data: Data
    public var width: Int
    public var height: Int
    public var altText: String

    public init(data: Data, width: Int, height: Int, altText: String = "image") {
        self.data = data
        self.width = width
        self.height = height
        self.altText = altText
    }
}

public enum InlineImageRenderer: Sendable {
    public static func render(_ image: InlineImage, capabilities: InlineImageCapabilities) -> String {
        if capabilities.kitty {
            return kittyEncode(image)
        }
        if capabilities.iterm2 {
            return iterm2Encode(image)
        }
        return textPlaceholder(image)
    }

    public static func textPlaceholder(_ image: InlineImage) -> String {
        "[\(image.altText) \(image.width)×\(image.height)]"
    }

    public static func kittyEncode(_ image: InlineImage) -> String {
        let payload = image.data.base64EncodedString()
        let chunks = chunk(payload, size: 4096)
        var result = ""
        for (index, chunk) in chunks.enumerated() {
            let more = index + 1 < chunks.count ? 1 : 0
            result += "\u{1B}_Gi=\(image.width),\(image.height),\(more);\(chunk)\u{1B}\\"
        }
        return result
    }

    public static func iterm2Encode(_ image: InlineImage) -> String {
        let payload = image.data.base64EncodedString()
        return "\u{1B}]1337;File=inline=1;width=\(image.width)px;height=\(image.height)px:\(payload)\u{7F}"
    }

    private static func chunk(_ text: String, size: Int) -> [String] {
        guard size > 0, !text.isEmpty else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}
