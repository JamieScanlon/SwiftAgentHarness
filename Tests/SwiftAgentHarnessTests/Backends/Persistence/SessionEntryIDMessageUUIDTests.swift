import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite struct SessionEntryIDMessageUUIDTests {
    @Test func fromMessageUUIDUsesFirstEightHexDigits() {
        let uuid = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        #expect(SessionEntryID.fromMessageUUID(uuid).rawValue == "550e8400")
    }

    @Test func initRejectsFullUUIDString() {
        #expect(SessionEntryID("550e8400-e29b-41d4-a716-446655440000") == nil)
        #expect(SessionEntryID("550e8400")?.rawValue == "550e8400")
    }

    @Test func matchingMessageIDFindsMessageWithPrefixEntryId() throws {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let message = Message(id: uuid, role: .user, content: "hi")
        let entryId = SessionEntryID.fromMessageUUID(uuid)
        #expect(SessionEntryID.matchingMessageID(for: entryId, in: [message]) == uuid)
    }
}
