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

    /// Detects graphics support from the environment.
    ///
    /// Nothing constructed a non-`.none` capability before this, so both encoders were
    /// unreachable outside tests — which is how they stayed malformed. Detection is
    /// conservative: an unrecognised terminal gets the text placeholder rather than a
    /// sequence it will print as garbage.
    public static func detected(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> InlineImageCapabilities {
        let term = environment["TERM"]?.lowercased() ?? ""
        let program = environment["TERM_PROGRAM"]?.lowercased() ?? ""

        // Kitty advertises itself in TERM and exports a window id; Ghostty and WezTerm
        // implement the same protocol.
        let kitty = term.contains("kitty")
            || environment["KITTY_WINDOW_ID"] != nil
            || program.contains("ghostty")
            || program.contains("wezterm")

        // iTerm2 exports TERM_PROGRAM; so does Apple's Terminal.app, which does NOT
        // implement OSC 1337 image display — match iTerm specifically.
        let iterm2 = program.contains("iterm")

        return InlineImageCapabilities(kitty: kitty, iterm2: iterm2)
    }

    public var preferredProtocol: InlineImageProtocol {
        if kitty { return .kitty }
        if iterm2 { return .iterm2 }
        return .textFallback
    }
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

    /// PNG magic number. Kitty needs to be told the transmission format, and the two
    /// legal answers here are "PNG" and "raw pixels" — guessing wrong renders noise.
    public var isPNG: Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }
}

public enum InlineImageRenderer: Sendable {
    /// Kitty caps a single escape's payload at 4096 base64 bytes.
    static let kittyChunkSize = 4096

    public static func render(_ image: InlineImage, capabilities: InlineImageCapabilities) -> String {
        // An empty payload encodes to nothing at all; the placeholder is still the honest
        // rendering.
        guard !image.data.isEmpty else { return textPlaceholder(image) }
        switch capabilities.preferredProtocol {
        case .kitty: return kittyEncode(image)
        case .iterm2: return iterm2Encode(image)
        case .textFallback: return textPlaceholder(image)
        }
    }

    public static func textPlaceholder(_ image: InlineImage) -> String {
        "[\(image.altText) \(image.width)×\(image.height)]"
    }

    /// Kitty graphics protocol.
    ///
    /// The previous encoding was `ESC _ G i=<w>,<h>,<more> ; payload ESC \`, which is not
    /// valid syntax: `i=` is the *image id*, and the control block is a comma-separated
    /// `key=value` list. Correct form is `a=T` (transmit and display), `f=100` for PNG or
    /// `f=32` for RGBA with explicit `s=`/`v=` dimensions, and `m=1` on every chunk but
    /// the last. Only the first chunk carries the full key list.
    public static func kittyEncode(_ image: InlineImage) -> String {
        let payload = image.data.base64EncodedString()
        let chunks = chunk(payload, size: kittyChunkSize)
        guard !chunks.isEmpty else { return "" }

        var result = ""
        for (index, piece) in chunks.enumerated() {
            let more = index + 1 < chunks.count ? 1 : 0
            let keys: String
            if index == 0 {
                var first = ["a=T"]
                if image.isPNG {
                    first.append("f=100")
                } else {
                    first.append("f=32")
                    first.append("s=\(image.width)")
                    first.append("v=\(image.height)")
                }
                first.append("m=\(more)")
                keys = first.joined(separator: ",")
            } else {
                keys = "m=\(more)"
            }
            result += "\u{1B}_G\(keys);\(piece)\u{1B}\\"
        }
        return result
    }

    /// iTerm2 inline image protocol.
    ///
    /// The previous encoding terminated the OSC with `DEL` (0x7F) instead of `BEL`, so the
    /// sequence never closed and the terminal swallowed everything printed after it — the
    /// TUI simply went blank. `size=` is also required in practice.
    public static func iterm2Encode(_ image: InlineImage) -> String {
        let payload = image.data.base64EncodedString()
        let arguments = [
            "inline=1",
            "size=\(image.data.count)",
            "width=\(image.width)px",
            "height=\(image.height)px",
            "preserveAspectRatio=1",
        ].joined(separator: ";")
        return "\u{1B}]1337;File=\(arguments):\(payload)\u{7}"
    }

    private static func chunk(_ text: String, size: Int) -> [String] {
        guard size > 0, !text.isEmpty else { return [] }
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

/// Renders an image into a transcript line, degrading to a placeholder.
///
/// Graphics escapes are zero-width as far as ``ANSIWidth`` is concerned, which is correct
/// — the terminal draws the image over cells the renderer doesn't account for — but it
/// means an image line must be emitted alone so the differential renderer's row
/// accounting stays honest.
public struct InlineImageComponent: TUIComponent {
    public var image: InlineImage
    public var capabilities: InlineImageCapabilities

    public init(image: InlineImage, capabilities: InlineImageCapabilities = .none) {
        self.image = image
        self.capabilities = capabilities
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        switch capabilities.preferredProtocol {
        case .textFallback:
            return [ANSIStyle.finishLine(
                ANSITruncate.truncate(ANSIStyle.dim(InlineImageRenderer.textPlaceholder(image)), toWidth: width)
            )]
        case .kitty, .iterm2:
            // The escape carries no visible columns; the placeholder is appended so the
            // line still reads on a terminal that ignored the sequence.
            let escape = InlineImageRenderer.render(image, capabilities: capabilities)
            let caption = ANSITruncate.truncate(
                ANSIStyle.dim(InlineImageRenderer.textPlaceholder(image)),
                toWidth: width
            )
            return [ANSIStyle.finishLine(escape + caption)]
        }
    }
}
