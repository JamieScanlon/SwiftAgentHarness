import Foundation
import Testing
@testable import SwiftAgentHarness

/// Captures transient conversation events.
private actor CapturingTopicPublisher: ConversationTopicPublishing {
    struct Event: Sendable {
        var conversationID: UUID
        var payload: ConversationTopicEventPayload
        var runID: UUID
        var modelCallId: UUID?
    }

    private(set) var events: [Event] = []

    func publishPersistedConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload, transcriptSequence: Int) async {}

    func publishTransientConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload, runID: UUID, modelCallId: UUID?) async {
        events.append(Event(conversationID: conversationID, payload: payload, runID: runID, modelCallId: modelCallId))
    }

    func publishConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload) async {}
}

@Suite("Route receipt export")
struct RouteReceiptExportTests {
    private func receipt() -> RouteReceipt {
        RouteReceipt(
            conversationID: UUID(),
            runID: UUID(),
            role: .gatekeeper,
            contract: .decide,
            requested: "jev-latest",
            resolved: .init(modelID: "jev-1.13.0", versionServed: "jev-1.13.0", bindingID: "typesafe/jev-1.13.0", surface: .systemOne),
            aliasResolved: .init(alias: "jev-latest", to: "jev-1.13.0"),
            rankedOut: [.init(modelID: "openai-d/x", reason: "question kind box unsupported")],
            fallback: [.init(from: "a/primary", reason: .transient)],
            guarantee: .calibratedDistribution,
            costUSD: 0.00004,
            latencyMs: 92,
            requestIDs: ["req_secret_123"],
            decision: .init(evaluation: DecisionEvaluation(verdict: .act, reason: .band(.act), modelVersion: "jev-1.13.0", value: 0.97), question: "verdict")
        )
    }

    @Test("The summary reads as 'answered by X (fallback from Y)'")
    func summary() {
        #expect(receipt().summary
            == "gatekeeper answered by jev-1.13.0 via typesafe/jev-1.13.0 (alias jev-latest; fallback from a/primary: transient) → act")
        let failed = RouteReceipt(role: .gatekeeper, contract: .decide, requested: "gatekeeper", errorClassification: .transient)
        #expect(failed.summary == "gatekeeper unanswered (transient)")
    }

    @Test("The wire form hashes request ids and carries no raw ids")
    func redaction() throws {
        let wire = receipt().wire
        #expect(wire.requestIDHashes.count == 1)
        #expect(wire.requestIDHashes[0].count == 16)
        #expect(wire.requestIDHashes[0] == RouteReceipt.hashRequestID("req_secret_123"))
        let json = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
        #expect(!json.contains("req_secret_123"))
        #expect(wire.decision?.reason == "band:act")
        #expect(wire.aliasResolved == ["alias": "jev-latest", "to": "jev-1.13.0"])
    }

    @Test("Receipts publish as transient routeReceipt events that decode and validate")
    func publishAndDecode() async throws {
        let publisher = CapturingTopicPublisher()
        let original = receipt()
        await ConversationEventsRouteReceiptRecorder(publisher: publisher).record(original)
        let event = try #require(await publisher.events.first)
        #expect(event.conversationID == original.conversationID)
        #expect(event.runID == original.runID)
        #expect(event.modelCallId == original.callID)
        #expect(event.payload.semanticKind == .routeReceipt)
        #expect(ConversationEventsReplayClassifier.stream(for: event.payload) == .transient)
        #expect(PublishingContractValidator.validateConversationEventPayload(event.payload).isEmpty)

        let envelope = CommResourceTopicMessage(
            transientEvent: "conversation/\(original.conversationID!.uuidString)/events",
            seq: 3,
            value: event.payload,
            runId: event.runID,
            turnOrdinal: 1
        )
        let line = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        guard case .routeReceipt(let wire, _, _) = ConversationTopicWireDecoding.decodeEvent(line: line) else {
            Issue.record("expected a decoded route receipt")
            return
        }
        #expect(wire == original.wire)
    }

    @Test("Receipts outside a conversation are not published; composites fan out")
    func noConversation() async {
        let publisher = CapturingTopicPublisher()
        let memory = InMemoryRouteReceiptRecorder()
        let composite = CompositeRouteReceiptRecorder([ConversationEventsRouteReceiptRecorder(publisher: publisher), memory])
        await composite.record(RouteReceipt(role: .router, contract: .decide, requested: "router"))
        #expect(await publisher.events.isEmpty)
        #expect(await memory.receipts.count == 1)
    }

    @Test("The dispatcher stamps conversation and run ids from the call context")
    func dispatcherStampsIDs() async {
        let memory = InMemoryRouteReceiptRecorder()
        let dispatcher = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource([DecisionFixtures.decider("d")]),
            providers: StaticDecisionProviderResolver(["decider": FakeDecisionProvider.constant(providerID: "decider", pYes: 0.9)]),
            roles: RoleBindingResolver(settings: [.gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide)]),
            receipts: memory,
            logger: DecisionLogCapture().logger
        )
        let conversationID = UUID()
        let runID = UUID()
        _ = await dispatcher.decide(
            DecisionFixtures.yesNoRequest(), role: .gatekeeper,
            context: DecisionCallContext(conversationID: conversationID, runID: runID)
        )
        let recorded = await memory.receipts
        #expect(recorded.first?.conversationID == conversationID)
        #expect(recorded.first?.runID == runID)
    }
}
