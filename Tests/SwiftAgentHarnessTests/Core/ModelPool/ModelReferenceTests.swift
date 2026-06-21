import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ModelReference")
struct ModelReferenceTests {
    @Test("parses canonical UUID strings as .id")
    func parsesUUID() {
        let uuid = UUID()
        let ref = ModelReference.parse(uuid.uuidString)
        #expect(ref == .id(uuid))
    }

    @Test("parses uppercase UUID strings as .id (case-insensitive)")
    func parsesUppercasedUUID() {
        let uuid = UUID()
        let ref = ModelReference.parse(uuid.uuidString.uppercased())
        #expect(ref == .id(uuid))
    }

    @Test("trims surrounding whitespace before classifying")
    func trimsWhitespace() {
        let uuid = UUID()
        let padded = "  \(uuid.uuidString)\n"
        #expect(ModelReference.parse(padded) == .id(uuid))

        let slugWithSpace = "   llama3.3:latest  "
        #expect(ModelReference.parse(slugWithSpace) == .slug("llama3.3:latest"))
    }

    @Test("non-UUID strings parse as .slug")
    func parsesSlug() {
        #expect(ModelReference.parse("llama3.3:latest") == .slug("llama3.3:latest"))
        #expect(ModelReference.parse("minimax/minimax-m2") == .slug("minimax/minimax-m2"))
    }

    @Test("empty / whitespace-only input returns nil")
    func rejectsEmpty() {
        #expect(ModelReference.parse("") == nil)
        #expect(ModelReference.parse("   ") == nil)
        #expect(ModelReference.parse("\n\t") == nil)
    }
}
