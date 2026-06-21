import Foundation
import Testing
@testable import SwiftAgentHarness

struct WebSocketOutboundHarnessValidationTests {
    @Test func harnessOutboundWireLineMakeFromEnvelope() throws {
        let payload = ModelStatePayload(phase: .done, thinking: false, updatedAt: Date(timeIntervalSince1970: 0))
        let topic = ResourceTopicName.poolHealth
        let envelope = CommResourceTopicMessage<ModelStatePayload>(snapshot: topic, seq: 1, value: payload)
        switch HarnessOutboundWireLine.make(from: envelope) {
        case .success(let line):
            #expect(line.kind == .snapshot)
            #expect(line.topic == topic)
            #expect(line.seq == 1)
        case .failure:
            Issue.record("expected wire line")
        }
        #expect(WebSocketOutboundHarnessValidation.validationIssueForCommResourceTopicEnvelope(envelope) == nil)
    }

    @Test func harnessOutboundWireLineMakeFromJSON() {
        let json = #"{"kind":"event","topic":"trace/server","trustClass":"trusted","originTrust":"system","seq":7,"value":{"spans":[]}}"#
        let line = HarnessOutboundWireLine.make(json: json)
        #expect(line?.kind == .event)
        #expect(line?.topic == "trace/server")
        #expect(line?.seq == 7)
    }

    @Test func validatesCommResourceTopicLine() throws {
        let payload = ModelStatePayload(phase: .done, thinking: false, updatedAt: Date(timeIntervalSince1970: 0))
        let topic = ResourceTopicName.poolHealth
        let envelope = CommResourceTopicMessage<ModelStatePayload>(snapshot: topic, seq: 1, value: payload)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(WebSocketOutboundHarnessValidation.validationIssueForCommResourceTopicJSONLine(json) == nil)
    }

    @Test func rejectsCommResourceTopicLineMissingTrustTags() {
        let json = #"{"kind":"snapshot","topic":"models/registry","seq":1,"value":{}}"#
        let issue = WebSocketOutboundHarnessValidation.validationIssueForCommResourceTopicJSONLine(json)
        #expect(issue != nil)
    }

    @Test func rejectsTransientConversationEventMissingSeq() {
        let json = #"{"kind":"event","topic":"conversation/550e8400-e29b-41d4-a716-446655440000/events","trustClass":"restricted","originTrust":"unknown-party","value":{"semanticKind":"contentDelta"},"runId":"550e8400-e29b-41d4-a716-446655440001","turnOrdinal":1}"#
        let issue = WebSocketOutboundHarnessValidation.validationIssueForCommResourceTopicJSONLine(json)
        #expect(issue != nil)
    }

    @Test func validatesControlResponsePayloads() {
        let errorPayload = APILayer.harnessErrorPayload(message: "bad request", code: "bad_request")
        #expect(WebSocketOutboundHarnessValidation.validationIssueForControlResponsePayload(errorPayload) == nil)

        let dedupePayload = APILayer.harnessDedupeResultPayload(firstSighting: true)
        #expect(WebSocketOutboundHarnessValidation.validationIssueForControlResponsePayload(dedupePayload) == nil)

        let invalid: [String: Any] = ["kind": "dedupe_result", "firstSighting": "yes"]
        #expect(WebSocketOutboundHarnessValidation.validationIssueForControlResponsePayload(invalid) != nil)
    }

    @Test func trackerDisconnectsAfterThresholdWithinWindow() async {
        let tracker = WebSocketOutboundSchemaViolationTracker(
            configuration: WebSocketOutboundSchemaEnforcementConfiguration(
                enabled: true,
                disconnectAfterViolations: 3,
                windowNanoseconds: 10_000_000_000
            )
        )
        #expect(await tracker.recordViolation(now: 1) == false)
        #expect(await tracker.recordViolation(now: 2) == false)
        #expect(await tracker.recordViolation(now: 3) == true)
    }
}
