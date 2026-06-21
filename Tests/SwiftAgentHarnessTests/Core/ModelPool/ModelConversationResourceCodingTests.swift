import Foundation
import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("ModelConversation resource Codable compatibility")
struct ModelConversationResourceCodingTests {
    @Test("Decodes legacy JSON without resource-shape keys")
    func decodesLegacySubset() throws {
        let model = Model(
            protocol: .openAIAPI,
            modelName: "t",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","model":\(try encodeModelJSON(model)),"messages":[],"turns":[],"state":"idle","showError":false,"errorMessage":"","createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z","systemPrompt":"s","interactionMode":"chat","disabledToolNames":[],"disabledSkillNames":[],"thinkingEnabled":true}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conv = try decoder.decode(ModelConversation.self, from: legacyJSON)
        #expect(conv.lifecycle == .active)
        #expect(conv.resourceRunStatus == .idle)
        #expect(conv.tags.isEmpty)
        #expect(conv.branchChildren.isEmpty)
    }

    private func encodeModelJSON(_ model: Model) throws -> String {
        let e = JSONEncoder()
        let data = try e.encode(model)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
