import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use surface intents")
struct ComputerUseSurfaceIntentTests {
    private static var schemaURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "openapi/schemas/ws/client-surface-intent-wire.schema.json")
    }

    private func schema() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.schemaURL)) as? [String: Any])
    }

    private let samples: [ClientSurfaceIntent] = [
        .computerUseRequest(ComputerUseSurfaceIntentPayload(
            requestID: "cu-q-1", requestKind: .question, prompt: "Which file?", target: "This Mac", lifecycleID: "call-1"
        )),
        .computerUseRequest(ComputerUseSurfaceIntentPayload(
            requestID: "cu-h-1", requestKind: .handoff, prompt: "Sign in", reason: "login", target: "This Mac", lifecycleID: "call-1"
        )),
        .computerUseRequestCleared(requestID: "cu-q-1", lifecycleID: "call-1"),
        .computerUseActivity(ComputerUseSurfaceIntentPayload(
            target: "This Mac", lifecycleID: "call-1", status: .acting, step: 3, maxSteps: 40, app: "com.apple.TextEdit", action: "click"
        )),
    ]

    @Test("Every intent kind the harness emits is declared in the wire schema")
    func kindsInSchema() throws {
        let properties = try #require(try schema()["properties"] as? [String: Any])
        let kind = try #require(properties["kind"] as? [String: Any])
        let declared = Set(try #require(kind["enum"] as? [String]))
        for intent in samples {
            #expect(declared.contains(intent.kind.rawValue), "\(intent.kind.rawValue) missing from schema")
        }
    }

    @Test("Encoded computer-use intents use only fields the schema declares")
    func fieldsInSchema() throws {
        let root = try schema()
        let properties = try #require(root["properties"] as? [String: Any])
        let computerUse = try #require(properties["computerUse"] as? [String: Any])
        let declaredPayload = Set(try #require(computerUse["properties"] as? [String: Any]).keys)
        for intent in samples {
            let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any])
            #expect(Set(object.keys).isSubset(of: Set(properties.keys)))
            let payload = try #require(object["computerUse"] as? [String: Any])
            #expect(Set(payload.keys).isSubset(of: declaredPayload), "undeclared: \(Set(payload.keys).subtracting(declaredPayload))")
        }
    }

    @Test("Intents round-trip through Codable")
    func roundTrip() throws {
        for intent in samples {
            #expect(try JSONDecoder().decode(ClientSurfaceIntent.self, from: JSONEncoder().encode(intent)) == intent)
        }
    }
}
