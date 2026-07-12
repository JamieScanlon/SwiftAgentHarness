import Foundation
import Testing
import Vapor
@testable import SwiftAgentHarness

@Suite("APILayer REST error envelope")
struct APILayerRESTErrorResponseTests {
    @Test("error builds typed JSON envelope with content type")
    func errorEnvelopeShape() throws {
        let response = APILayerRESTErrorResponse.error(status: .unauthorized, message: "token required")
        #expect(response.status == .unauthorized)
        #expect(response.headers.first(name: .contentType) == "application/json")
        let data = try #require(response.body.data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["type"] as? String == "error")
        #expect(json?["message"] as? String == "token required")
    }

    @Test("invalidConversationID uses canonical message")
    func invalidConversationID() throws {
        let response = APILayerRESTErrorResponse.invalidConversationID()
        #expect(response.status == .badRequest)
        let data = try #require(response.body.data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["type"] as? String == "error")
        #expect(json?["message"] as? String == "Invalid conversation ID")
    }
}
