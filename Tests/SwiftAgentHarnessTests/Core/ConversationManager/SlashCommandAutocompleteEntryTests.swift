import Foundation
import SwiftAgentHarness
import Testing

@Suite("SlashCommandAutocompleteEntry REST decoding")
struct SlashCommandAutocompleteEntryDecodingTests {

    @Test("Decodes array like GET /slash-commands")
    func decodesArrayFromJSON() throws {
        let json = """
        [
            {
                "name": "/compact",
                "description": "Compact the current conversation context.",
                "argumentHint": "[reason]",
                "hiddenKeywords": "shrink",
                "bypassTier": "queued"
            }
        ]
        """
        let data = Data(json.utf8)
        let rows = try JSONDecoder().decode([SlashCommandAutocompleteEntry].self, from: data)
        #expect(rows.count == 1)
        #expect(rows[0].name == "/compact")
        #expect(rows[0].bypassTier == .queued)
    }
}
