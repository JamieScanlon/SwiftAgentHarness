import Foundation
import SwiftAgentHarness
import Testing

@Suite("ConversationBranchRequest")
struct ConversationBranchRequestTests {
    @Test func decodesFromEntryIdAlias() throws {
        let id = UUID()
        let data = Data("{\"fromEntryId\":\"\(id.uuidString)\"}".utf8)
        let decoded = try JSONDecoder().decode(ConversationBranchRequest.self, from: data)
        #expect(decoded.userMessageID == id)
    }
}
