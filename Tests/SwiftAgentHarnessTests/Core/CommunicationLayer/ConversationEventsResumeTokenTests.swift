import Foundation
import Testing
@testable import SwiftAgentHarness

struct ConversationEventsResumeTokenTests {
    private let secret = Data("unit-test-secret-will-be-hashed".utf8)

    @Test func mintAndParseRoundTrip() throws {
        let cid = UUID()
        let exp = Int(Date().timeIntervalSince1970) + 3600
        let payload = ConversationEventsResumeTokenPayload(
            v: ConversationEventsResumeTokenPayload.schemaVersion,
            conv: cid,
            msg: 3,
            chk: 1,
            tot: 9,
            exp: exp
        )
        let tok = try ConversationEventsResumeToken.mint(payload: payload, secret: secret)
        let decoded = try ConversationEventsResumeToken.parse(tok, secret: secret, conversationID: cid)
        #expect(decoded == payload)
    }

    @Test func wrongConversationFails() throws {
        let a = UUID()
        let b = UUID()
        let exp = Int(Date().timeIntervalSince1970) + 60
        let payload = ConversationEventsResumeTokenPayload(
            v: 1,
            conv: a,
            msg: 0,
            chk: 0,
            tot: 0,
            exp: exp
        )
        let tok = try ConversationEventsResumeToken.mint(payload: payload, secret: secret)
        #expect(throws: ConversationEventsResumeTokenError.self) {
            _ = try ConversationEventsResumeToken.parse(tok, secret: secret, conversationID: b)
        }
    }

    @Test func tamperFailsSignature() throws {
        let cid = UUID()
        let exp = Int(Date().timeIntervalSince1970) + 60
        let payload = ConversationEventsResumeTokenPayload(v: 1, conv: cid, msg: 0, chk: 0, tot: 0, exp: exp)
        var tok = try ConversationEventsResumeToken.mint(payload: payload, secret: secret)
        _ = tok.removeLast()

        #expect(throws: ConversationEventsResumeTokenError.self) {
            _ = try ConversationEventsResumeToken.parse(tok, secret: secret, conversationID: cid)
        }
    }
}
