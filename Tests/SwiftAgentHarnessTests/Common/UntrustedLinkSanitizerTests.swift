import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Untrusted link sanitizer")
struct UntrustedLinkSanitizerTests {
    private func sanitize(_ text: String, trustedHosts: Set<String> = []) -> String {
        UntrustedLinkSanitizer.sanitize(text, trustedHosts: trustedHosts)
    }

    @Test("Plain prose and markdown without remote links pass through unchanged")
    func plainText() {
        let text = "# Title\n\nSome *emphasis*, a list:\n- one\n- two [x]\n\n> quote with ! and < and h"
        #expect(sanitize(text) == text)
    }

    @Test("Remote images are not loaded, whatever the URL")
    func remoteImage() {
        #expect(
            sanitize("Look ![chart](https://evil.example/c.png?d=secret) here")
                == "Look chart (image from evil.example not loaded) here"
        )
        #expect(sanitize("![](https://cdn.example/logo.png)") == "(image from cdn.example not loaded)")
        #expect(sanitize("![x](//evil.example/p.png)") == "x (image from evil.example not loaded)")
        #expect(sanitize("![x](<https://evil.example/a b.png> \"title\")") == "x (image from evil.example not loaded)")
    }

    @Test("Local, relative, and trusted-host images are kept")
    func keptImages() {
        #expect(sanitize("![x](./diagram.png)") == "![x](./diagram.png)")
        #expect(sanitize("![x](data:image/png;base64,AAAA)") == "![x](data:image/png;base64,AAAA)")
        #expect(
            sanitize("![x](https://img.docs.example/a.png)", trustedHosts: ["docs.example"])
                == "![x](https://img.docs.example/a.png)"
        )
    }

    @Test("Links whose URL carries data are flagged and made inert")
    func dataCarryingLinks() {
        #expect(
            sanitize("[docs](https://evil.example/?q=abc)")
                == "docs (unverified link: `https://evil.example/?q=abc`)"
        )
        #expect(
            sanitize("[a](https://evil.example/page#token=xyz)")
                == "a (unverified link: `https://evil.example/page#token=xyz`)"
        )
        let longSegment = String(repeating: "A", count: 48)
        #expect(
            sanitize("[a](https://evil.example/\(longSegment))")
                == "a (unverified link: `https://evil.example/\(longSegment)`)"
        )
        let longLabel = String(repeating: "b", count: 40)
        #expect(
            sanitize("[a](https://\(longLabel).evil.example/)")
                == "a (unverified link: `https://\(longLabel).evil.example/`)"
        )
        #expect(
            sanitize("[a](https://user:pw@evil.example/)")
                == "a (unverified link: `https://user:pw@evil.example/`)"
        )
    }

    @Test("Ordinary links, relative links, and trusted hosts are kept")
    func keptLinks() {
        #expect(sanitize("[docs](https://swift.org/documentation/)") == "[docs](https://swift.org/documentation/)")
        #expect(sanitize("[file](src/main.swift)") == "[file](src/main.swift)")
        #expect(
            sanitize("[s](https://github.com/search?q=swift)", trustedHosts: ["github.com"])
                == "[s](https://github.com/search?q=swift)"
        )
    }

    @Test("An image nested in link text is sanitized inside a kept link")
    func badge() {
        #expect(
            sanitize("[![build](https://img.example/b.svg)](https://swift.org)")
                == "[build (image from img.example not loaded)](https://swift.org)"
        )
    }

    @Test("HTML images are not loaded")
    func htmlImage() {
        #expect(sanitize("a <img src=\"https://evil.example/p?x=1\" alt=\"\"> b") == "a (image from evil.example not loaded) b")
        #expect(sanitize("<IMG SRC=https://evil.example/p.gif />") == "(image from evil.example not loaded)")
        #expect(sanitize("<img src=\"local.png\">") == "<img src=\"local.png\">")
    }

    @Test("Autolinks and bare URLs that carry data are flagged; others are kept")
    func autolinksAndBareURLs() {
        #expect(
            sanitize("<https://evil.example/?k=v>") == "(unverified link: `https://evil.example/?k=v`)"
        )
        #expect(sanitize("<https://swift.org>") == "<https://swift.org>")
        #expect(
            sanitize("see https://evil.example/?k=v.") == "see (unverified link: `https://evil.example/?k=v`)."
        )
        #expect(
            sanitize("or www.evil.example/x?d=1 now") == "or (unverified link: `www.evil.example/x?d=1`) now"
        )
        #expect(sanitize("see https://swift.org/blog, then") == "see https://swift.org/blog, then")
        #expect(sanitize("path/https://x.example/?a=1") == "path/https://x.example/?a=1")
    }

    @Test("Remote link reference definitions are neutralized")
    func referenceDefinitions() {
        #expect(
            sanitize("![x][1]\n\n[1]: https://evil.example/a.png")
                == "![x][1]\n\n1: (unverified link: `https://evil.example/a.png`)"
        )
        #expect(sanitize("[1]: ./local.md \"t\"") == "[1]: ./local.md \"t\"")
    }

    @Test("Code spans and fenced code blocks are left alone")
    func code() {
        let inline = "Use `![x](https://evil.example/?a=1)` literally."
        #expect(sanitize(inline) == inline)
        let fenced = "```bash\ncurl \"https://api.example/v1?key=abc\"\n![x](https://evil.example/a.png)\n```\nafter ![y](https://evil.example/b.png)"
        #expect(
            sanitize(fenced)
                == "```bash\ncurl \"https://api.example/v1?key=abc\"\n![x](https://evil.example/a.png)\n```\nafter y (image from evil.example not loaded)"
        )
        let tilde = "~~~\nhttps://evil.example/?a=1\n~~~"
        #expect(sanitize(tilde) == tilde)
    }

    @Test("Escaped brackets are not treated as images")
    func escapes() {
        #expect(sanitize("\\![x](./a.png)") == "\\![x](./a.png)")
    }

    @Test("Streaming holds back an unfinished construct and never emits an unsanitized URL")
    func streamingHoldsBack() {
        var sanitizer = UntrustedLinkSanitizer()
        #expect(sanitizer.feed("Hello ![al") == "Hello ")
        #expect(sanitizer.feed("t](https://evil.example/") == "")
        #expect(sanitizer.feed("x.png) bye") == "alt (image from evil.example not loaded) bye")
        #expect(sanitizer.flush() == "")

        var unfinished = UntrustedLinkSanitizer()
        #expect(unfinished.feed("tail ![al") == "tail ")
        #expect(unfinished.flush() == "![al")
    }

    @Test("Streaming output matches the one-shot result for every chunking")
    func streamingEquivalence() {
        let samples = [
            "Look ![chart](https://evil.example/c.png?d=secret) and [docs](https://evil.example/?q=1).",
            "[![build](https://img.example/b.svg)](https://swift.org) <img src=\"https://e.example/p\"> end",
            "see https://evil.example/?k=v. and <https://evil.example/?a=b>\n\n[1]: https://evil.example/a.png\n",
            "```\nhttps://evil.example/?a=1\n```\nafter `x` ![y](https://evil.example/b.png) \\[z]",
            "unclosed [bracket and ![image without close",
        ]
        for sample in samples {
            let expected = sanitize(sample)
            let characters = Array(sample)
            var byCharacter = UntrustedLinkSanitizer()
            var streamed = ""
            for character in characters {
                let piece = byCharacter.feed(String(character))
                #expect(!piece.contains("evil.example/c.png?d"), "leaked an unsanitized URL: \(piece)")
                streamed += piece
            }
            streamed += byCharacter.flush()
            #expect(streamed == expected, "character stream differs for \(sample)")

            for split in 0...characters.count {
                var sanitizer = UntrustedLinkSanitizer()
                var output = sanitizer.feed(String(characters[..<split]))
                output += sanitizer.feed(String(characters[split...]))
                output += sanitizer.flush()
                #expect(output == expected, "split at \(split) differs for \(sample)")
            }
        }
    }

    @Test("A context is untrusted once any message carries wrapped external content")
    func untrustedContextDetection() {
        let wrapped = ExternalContentEnvelope.wrap(
            "page text",
            options: ExternalContentEnvelopeOptions(source: .webFetch, from: "web_fetch", subject: nil, includeSecurityPreamble: true)
        )
        let clean = [Message(id: UUID(), role: .user, content: "hi", timestamp: Date())]
        let tainted = clean + [Message(id: UUID(), role: .tool, content: wrapped, timestamp: Date())]
        #expect(!UntrustedLinkSanitizer.containsExternalContent(clean))
        #expect(UntrustedLinkSanitizer.containsExternalContent(tainted))
    }
}
