import Testing
@testable import SwiftAgentHarness

@Suite("Message tool arguments parser")
struct MessageToolArgumentsParserTests {
    @Test("decodes complete presentation JSON")
    func decodeComplete() {
        let json = """
        {"title":"Hi","blocks":[{"type":"text","text":"Hello world"}]}
        """
        let presentation = MessageToolArgumentsParser.decodePresentation(from: json)
        #expect(presentation?.title == "Hi")
        #expect(presentation?.textFallback().contains("Hello world") == true)
    }

    @Test("extracts visible text from partial streaming fragment")
    func partialFragment() {
        let fragment = #"{"blocks":[{"type":"text","text":"Hel"}"#
        let visible = MessageToolArgumentsParser.visibleText(fromArgumentsFragment: fragment)
        #expect(visible == "Hel")
    }

    @Test("ignores non-message tool names at turn loop boundary")
    func toolNameConstant() {
        #expect(MessageToolArgumentsParser.toolName == "message")
    }
}
