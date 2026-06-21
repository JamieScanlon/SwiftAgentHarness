import Foundation
import Testing
@testable import SwiftAgentHarness

struct WebSocketCommClientControlValidatorTests {
    @Test func validSubscribePasses() {
        let obj: [String: Any] = ["kind": "subscribe", "topic": "pool/health", "since": 2]
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: obj) == nil)
    }

    @Test func extraKeyRejected() {
        let obj: [String: Any] = ["kind": "subscribe", "topic": "pool/health", "foo": true]
        let err = WebSocketCommClientControlValidator.validationError(jsonObject: obj)
        #expect(err?.contains("unexpected keys") == true)
    }

    @Test func invalidSinceTypeRejected() {
        let obj: [String: Any] = ["kind": "unsubscribe", "topic": "pool/health", "since": "nope"]
        let err = WebSocketCommClientControlValidator.validationError(jsonObject: obj)
        #expect(err?.contains("since") == true)
    }

    @Test func subscribeSinceMessageSeqPassesValidation() {
        let obj: [String: Any] = [
            "kind": "subscribe",
            "topic": "conversation/6ba7b810-9dad-11d1-80b4-00c04fd430c8/events",
            "sinceMessageSeq": 1,
        ]
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: obj) == nil)
    }

    @Test func invalidResumeTokenTypeRejected() {
        let obj: [String: Any] = [
            "kind": "subscribe",
            "topic": "conversation/6ba7b810-9dad-11d1-80b4-00c04fd430c8/events",
            "resumeToken": 99,
        ]
        let err = WebSocketCommClientControlValidator.validationError(jsonObject: obj)
        #expect(err?.contains("resumeToken") == true)
    }

    @Test func invalidKindRejected() {
        let obj: [String: Any] = ["kind": "peek", "topic": "x"]
        let err = WebSocketCommClientControlValidator.validationError(jsonObject: obj)
        #expect(err?.contains("subscribe") == true)
    }

    @Test func validDedupeCheckAndSetPasses() {
        let obj: [String: Any] = [
            "kind": "dedupe_check_and_set",
            "dedupeKey": "k1",
            "dedupeTtlSeconds": 120,
        ]
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: obj) == nil)
    }

    @Test func dedupeMissingKeyRejected() {
        let obj: [String: Any] = ["kind": "dedupe_check_and_set"]
        let err = WebSocketCommClientControlValidator.validationError(jsonObject: obj)
        #expect(err?.contains("dedupeKey") == true)
    }

    @Test func dedupeExtraKeyRejected() {
        let obj: [String: Any] = [
            "kind": "dedupe_check_and_set",
            "dedupeKey": "k",
            "topic": "x",
        ]
        let err = WebSocketCommClientControlValidator.validationError(jsonObject: obj)
        #expect(err?.contains("unexpected keys") == true)
    }
}
