import Foundation
import Testing
@testable import SwiftAgentHarness

/// Validates JSON files under `openapi/schemas/ws/fixtures/` against the same rules as runtime harness validation (no Node.js required in CI).
struct WebSocketSchemaFixtureTests {

    private static var packageRootOpenAPISchemasWS: URL {
        var url = URL(fileURLWithPath: #filePath)
        // Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/<this file> → repo root
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "openapi/schemas/ws", directoryHint: .isDirectory)
    }

    @Test func commClientControlValidFixturePassesValidator() throws {
        let url = Self.packageRootOpenAPISchemasWS.appending(path: "fixtures/comm-client-control-valid-subscribe.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: obj) == nil)
    }

    @Test func commClientControlValidSubscribeDualFixturePassesValidator() throws {
        let url = Self.packageRootOpenAPISchemasWS.appending(path: "fixtures/comm-client-control-valid-subscribe-dual.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: obj) == nil)
    }

    @Test func commClientControlInvalidFixtureFailsValidator() throws {
        let url = Self.packageRootOpenAPISchemasWS.appending(path: "fixtures/comm-client-control-invalid-extra-key.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: obj) != nil)
    }

    @Test func commClientControlValidAckFixturePassesValidator() throws {
        let url = Self.packageRootOpenAPISchemasWS.appending(path: "fixtures/comm-client-control-valid-ack.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: obj) == nil)
    }

    @Test func commClientControlInvalidAckMissingUpToFailsValidator() throws {
        let url = Self.packageRootOpenAPISchemasWS.appending(path: "fixtures/comm-client-control-invalid-ack-missing-upto.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: obj) != nil)
    }
}
