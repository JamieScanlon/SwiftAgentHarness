import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Inline image protocols")
struct InlineImageProtocolTests {
    private static let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test("iTerm2 sequence is terminated with BEL, not DEL")
    func iterm2Terminator() {
        // Terminating with DEL left the OSC open, so the terminal swallowed every byte
        // printed afterwards and the TUI went blank.
        let image = InlineImage(data: Data([0xFF, 0xEE]), width: 4, height: 2, altText: "dot")
        let encoded = InlineImageRenderer.iterm2Encode(image)
        #expect(encoded.hasSuffix("\u{7}"))
        #expect(!encoded.contains("\u{7F}"))
        #expect(encoded.hasPrefix("\u{1B}]1337;File="))
    }

    @Test("iTerm2 sequence declares the payload size")
    func iterm2Size() {
        let data = Data(repeating: 0xAB, count: 37)
        let encoded = InlineImageRenderer.iterm2Encode(
            InlineImage(data: data, width: 10, height: 5)
        )
        #expect(encoded.contains("size=37"))
        #expect(encoded.contains("width=10px"))
        #expect(encoded.contains("height=5px"))
        #expect(encoded.contains(data.base64EncodedString()))
    }

    @Test("Kitty control block uses valid protocol keys")
    func kittyKeys() {
        // `i=` is the image *id*; the old encoder wrote dimensions into it, so nothing
        // ever rendered.
        let image = InlineImage(data: Self.pngHeader, width: 8, height: 8)
        let encoded = InlineImageRenderer.kittyEncode(image)
        #expect(encoded.hasPrefix("\u{1B}_G"))
        #expect(encoded.contains("a=T"))
        #expect(encoded.contains("f=100"))
        #expect(!encoded.contains("i=8,8"))
        #expect(encoded.hasSuffix("\u{1B}\\"))
    }

    @Test("Non-PNG payloads declare raw format and explicit dimensions")
    func kittyRawFormat() {
        let image = InlineImage(data: Data([0x01, 0x02, 0x03]), width: 6, height: 3)
        let encoded = InlineImageRenderer.kittyEncode(image)
        #expect(encoded.contains("f=32"))
        #expect(encoded.contains("s=6"))
        #expect(encoded.contains("v=3"))
    }

    @Test("Kitty chunks carry continuation markers and repeat no keys")
    func kittyChunking() {
        let big = Data(repeating: 0x7F, count: InlineImageRenderer.kittyChunkSize * 2)
        let encoded = InlineImageRenderer.kittyEncode(InlineImage(data: big, width: 2, height: 2))
        let escapes = encoded.components(separatedBy: "\u{1B}_G").dropFirst()
        #expect(escapes.count >= 2)
        // Only the first chunk carries the full key list.
        #expect(escapes.first?.contains("a=T") == true)
        #expect(escapes.dropFirst().allSatisfy { !$0.contains("a=T") })
        // Every chunk but the last says "more coming".
        #expect(escapes.dropLast().allSatisfy { $0.hasPrefix("m=1;") || $0.contains(",m=1;") })
        #expect(escapes.last?.contains("m=0") == true)
    }

    @Test("PNG detection keys off the magic number")
    func pngDetection() {
        #expect(InlineImage(data: Self.pngHeader, width: 1, height: 1).isPNG)
        #expect(!InlineImage(data: Data([0xFF, 0xD8, 0xFF]), width: 1, height: 1).isPNG)
        #expect(!InlineImage(data: Data(), width: 1, height: 1).isPNG)
    }

    @Test("Capabilities are detected from the environment")
    func capabilityDetection() {
        #expect(InlineImageCapabilities.detected(environment: ["TERM": "xterm-kitty"]).kitty)
        #expect(InlineImageCapabilities.detected(environment: ["KITTY_WINDOW_ID": "1"]).kitty)
        #expect(InlineImageCapabilities.detected(environment: ["TERM_PROGRAM": "ghostty"]).kitty)
        #expect(InlineImageCapabilities.detected(environment: ["TERM_PROGRAM": "iTerm.app"]).iterm2)
        // Apple Terminal exports TERM_PROGRAM but does not display images.
        let appleTerminal = InlineImageCapabilities.detected(environment: ["TERM_PROGRAM": "Apple_Terminal"])
        #expect(!appleTerminal.iterm2)
        #expect(!appleTerminal.kitty)
        #expect(InlineImageCapabilities.detected(environment: [:]) == .none)
    }

    @Test("Preferred protocol prefers kitty then iterm2 then text")
    func preferredProtocol() {
        #expect(InlineImageCapabilities(kitty: true, iterm2: true).preferredProtocol == .kitty)
        #expect(InlineImageCapabilities(kitty: false, iterm2: true).preferredProtocol == .iterm2)
        #expect(InlineImageCapabilities.none.preferredProtocol == .textFallback)
    }
}

@Suite("InlineImageComponent")
struct InlineImageComponentTests {
    @Test("Falls back to a placeholder with no graphics support")
    func placeholderFallback() {
        let component = InlineImageComponent(
            image: InlineImage(data: Data([0x01]), width: 12, height: 4, altText: "chart")
        )
        let rendered = ANSIWidth.stripANSI(component.render(width: 40).joined())
        #expect(rendered.contains("[chart 12×4]"))
    }

    @Test("Graphics escapes carry a readable caption")
    func captionAlongsideEscape() {
        let component = InlineImageComponent(
            image: InlineImage(data: Data([0x01]), width: 3, height: 3, altText: "plot"),
            capabilities: InlineImageCapabilities(kitty: true)
        )
        let line = component.render(width: 40)[0]
        #expect(line.contains("\u{1B}_G"))
        #expect(ANSIWidth.stripANSI(line).contains("plot"))
    }

    @Test("Honours the width bound at every width")
    func widthBound() {
        for capabilities in [InlineImageCapabilities.none, InlineImageCapabilities(kitty: true), InlineImageCapabilities(iterm2: true)] {
            let component = InlineImageComponent(
                image: InlineImage(data: Data(repeating: 0x2A, count: 64), width: 100, height: 50, altText: "a long alt text"),
                capabilities: capabilities
            )
            for width in 1...60 {
                for line in component.render(width: width) {
                    // Graphics escapes measure zero, which is correct — the terminal draws
                    // over cells the renderer does not account for.
                    #expect(ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line)) <= width)
                }
            }
        }
    }
}
