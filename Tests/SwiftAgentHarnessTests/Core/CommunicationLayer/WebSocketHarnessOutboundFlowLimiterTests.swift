import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

@Suite(.serialized)
struct WebSocketHarnessOutboundFlowLimiterTests {
    private let cid = UUID(uuidString: "A22BBB58-8BF7-4DB8-BDD8-E44AF256FF68")!
    private var convEvents: String { ConversationTopicFormat.topic(conversationID: cid) }
    private var convState: String { ConversationTopicFormat.stateTopic(conversationID: cid) }

    private func eventLine(topic: String, seq: Int) -> String {
        #"{"kind":"event","topic":"\#(topic)","trustClass":"trusted","originTrust":"system","seq":\#(seq),"value":{"ok":true}}"#
    }

    private func transientEventLine(topic: String, seq: Int, runID: UUID, turnOrdinal: Int) -> String {
        #"{"kind":"event","topic":"\#(topic)","trustClass":"restricted","originTrust":"unknown-party","seq":\#(seq),"value":{"semanticKind":"contentDelta"},"runId":"\#(runID.uuidString.lowercased())","turnOrdinal":\#(turnOrdinal)}"#
    }

    private func wireLine(_ json: String) -> HarnessOutboundWireLine {
        guard let line = HarnessOutboundWireLine.make(json: json) else {
            Issue.record("invalid test harness line")
            return HarnessOutboundWireLine(json: json, kind: .event, topic: "test", seq: 0)
        }
        return line
    }

    @Test func disabledConfigurationPassesThroughWithoutTracking() async throws {
        let cfg = WebSocketOutboundFlowConfiguration.disabled
        let sent = Mutex<[String]>([])
        let limiter = WebSocketHarnessOutboundFlowLimiter(
            configuration: cfg,
            wsSend: { json in sent.withLock { $0.append(json) } },
            requestDisconnect: {}
        )
        let json = eventLine(topic: convEvents, seq: 1)
        try await limiter.sendHarnessLine(wireLine(json))
        #expect(sent.withLock { $0 } == [json])
    }

    @Test func highFrequencyQueuesThirdEventUntilAckDrains() async throws {
        let cfg = WebSocketOutboundFlowConfiguration(
            enabled: true,
            limitOnlyAfterFirstAckPerTopic: false,
            maxInflightEvents: 2,
            maxInflightStateLike: 8,
            softInflightEvents: 100,
            softInflightStateLike: 100,
            flowPressureCooldownNanoseconds: 60_000_000_000,
            coalesceStateTopicsWhenOverCapacity: true,
            disconnectPendingEventsThreshold: 50_000,
            disconnectBufferedBytesThreshold: 0
        )
        let sent = Mutex<[String]>([])
        let limiter = WebSocketHarnessOutboundFlowLimiter(
            configuration: cfg,
            wsSend: { json in sent.withLock { $0.append(json) } },
            requestDisconnect: {}
        )
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convEvents, seq: 1)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convEvents, seq: 2)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convEvents, seq: 3)))
        #expect(sent.withLock { $0 }.count == 2)

        await limiter.applyAck(topic: convEvents, upTo: 2)
        let lines = sent.withLock { $0 }
        #expect(lines.count == 3)
        #expect(lines.last?.contains(#""seq":3"#) == true)
    }

    @Test func stateLikeTopicCoalescesPendingWhenOverCapacity() async throws {
        let cfg = WebSocketOutboundFlowConfiguration(
            enabled: true,
            limitOnlyAfterFirstAckPerTopic: false,
            maxInflightEvents: 8,
            maxInflightStateLike: 1,
            softInflightEvents: 100,
            softInflightStateLike: 100,
            flowPressureCooldownNanoseconds: 60_000_000_000,
            coalesceStateTopicsWhenOverCapacity: true,
            disconnectPendingEventsThreshold: 50_000,
            disconnectBufferedBytesThreshold: 0
        )
        let sent = Mutex<[String]>([])
        let limiter = WebSocketHarnessOutboundFlowLimiter(
            configuration: cfg,
            wsSend: { json in sent.withLock { $0.append(json) } },
            requestDisconnect: {}
        )
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convState, seq: 10)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convState, seq: 11)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convState, seq: 12)))

        #expect(sent.withLock { $0 }.count == 1)
        #expect(sent.withLock { $0 }.first?.contains(#""seq":10"#) == true)

        await limiter.applyAck(topic: convState, upTo: 10)

        let lines = sent.withLock { $0 }
        #expect(lines.count == 2)
        #expect(lines.last?.contains(#""seq":12"#) == true)
    }

    @Test func emitsFlowPressureLaggingWhenOverSoftThreshold() async throws {
        let cfg = WebSocketOutboundFlowConfiguration(
            enabled: true,
            limitOnlyAfterFirstAckPerTopic: false,
            maxInflightEvents: 4,
            maxInflightStateLike: 4,
            softInflightEvents: 2,
            softInflightStateLike: 2,
            flowPressureCooldownNanoseconds: 0,
            coalesceStateTopicsWhenOverCapacity: false,
            disconnectPendingEventsThreshold: 50_000,
            disconnectBufferedBytesThreshold: 0
        )
        let sent = Mutex<[String]>([])
        let limiter = WebSocketHarnessOutboundFlowLimiter(
            configuration: cfg,
            wsSend: { json in sent.withLock { $0.append(json) } },
            requestDisconnect: {}
        )
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convEvents, seq: 1)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convEvents, seq: 2)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convEvents, seq: 3)))

        let lines = sent.withLock { $0 }
        #expect(lines.contains(where: { $0.contains("\"kind\":\"lagging\"") && $0.contains(HarnessWireHints.flowPressure) }))
    }

    @Test func transientConversationEventsParticipateInAckWindow() async throws {
        let cfg = WebSocketOutboundFlowConfiguration(
            enabled: true,
            limitOnlyAfterFirstAckPerTopic: false,
            maxInflightEvents: 2,
            maxInflightStateLike: 8,
            softInflightEvents: 100,
            softInflightStateLike: 100,
            flowPressureCooldownNanoseconds: 60_000_000_000,
            coalesceStateTopicsWhenOverCapacity: true,
            disconnectPendingEventsThreshold: 50_000,
            disconnectBufferedBytesThreshold: 0
        )
        let sent = Mutex<[String]>([])
        let limiter = WebSocketHarnessOutboundFlowLimiter(
            configuration: cfg,
            wsSend: { json in sent.withLock { $0.append(json) } },
            requestDisconnect: {}
        )
        let runID = UUID()
        try await limiter.sendHarnessLine(wireLine(transientEventLine(topic: convEvents, seq: 1, runID: runID, turnOrdinal: 1)))
        try await limiter.sendHarnessLine(wireLine(transientEventLine(topic: convEvents, seq: 2, runID: runID, turnOrdinal: 2)))
        try await limiter.sendHarnessLine(wireLine(transientEventLine(topic: convEvents, seq: 3, runID: runID, turnOrdinal: 3)))
        #expect(sent.withLock { $0 }.count == 2)

        await limiter.applyAck(topic: convEvents, upTo: 2)
        let lines = sent.withLock { $0 }
        #expect(lines.count == 3)
        #expect(lines.last?.contains(#""seq":3"#) == true)
        #expect(lines.last?.contains(#""turnOrdinal":3"#) == true)
    }

    @Test func subAgentPathEventTopicUsesHighFrequencyClass() async throws {
        let cfg = WebSocketOutboundFlowConfiguration(
            enabled: true,
            limitOnlyAfterFirstAckPerTopic: false,
            maxInflightEvents: 2,
            maxInflightStateLike: 8,
            softInflightEvents: 100,
            softInflightStateLike: 100,
            flowPressureCooldownNanoseconds: 60_000_000_000,
            coalesceStateTopicsWhenOverCapacity: true,
            disconnectPendingEventsThreshold: 50_000,
            disconnectBufferedBytesThreshold: 0
        )
        let sent = Mutex<[String]>([])
        let limiter = WebSocketHarnessOutboundFlowLimiter(
            configuration: cfg,
            wsSend: { json in sent.withLock { $0.append(json) } },
            requestDisconnect: {}
        )
        let topic = "subagent/\(cid.uuidString.lowercased())/agent-0/events"
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: topic, seq: 1)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: topic, seq: 2)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: topic, seq: 3)))
        #expect(sent.withLock { $0 }.count == 2)
    }

    @Test func traceServerTopicUsesHighFrequencyClass() async throws {
        let cfg = WebSocketOutboundFlowConfiguration(
            enabled: true,
            limitOnlyAfterFirstAckPerTopic: false,
            maxInflightEvents: 2,
            maxInflightStateLike: 8,
            softInflightEvents: 100,
            softInflightStateLike: 100,
            flowPressureCooldownNanoseconds: 60_000_000_000,
            coalesceStateTopicsWhenOverCapacity: true,
            disconnectPendingEventsThreshold: 50_000,
            disconnectBufferedBytesThreshold: 0
        )
        let sent = Mutex<[String]>([])
        let limiter = WebSocketHarnessOutboundFlowLimiter(
            configuration: cfg,
            wsSend: { json in sent.withLock { $0.append(json) } },
            requestDisconnect: {}
        )
        let topic = TraceTopicFormat.serverTopic
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: topic, seq: 1)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: topic, seq: 2)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: topic, seq: 3)))
        #expect(sent.withLock { $0 }.count == 2)
    }
}

@Suite(.serialized)
struct ServerConfigFlowControlDefaultsTests {
    @Test func defaultServerConfigEnablesOutboundFlowControl() {
        let config = ServerConfig()
        #expect(config.websocketOutboundFlowConfiguration.enabled == true)
        #expect(config.websocketOutboundFlowConfiguration.applyLimitsToHighFrequencyEventsBeforeFirstAck == true)
    }

    @Test func defaultServerConfigEnforcesOperatorScopedTopics() {
        let config = ServerConfig()
        #expect(config.enforceOperatorForServerTraceSubscribe == true)
        #expect(config.resolvedServerTraceSubscribePolicy().enforceOperatorAllowlist == true)
    }
}

@Suite(.serialized)
struct WebSocketHarnessOutboundFlowDefaultBackpressureTests {
    private let cid = UUID(uuidString: "A22BBB58-8BF7-4DB8-BDD8-E44AF256FF68")!
    private var convEvents: String { ConversationTopicFormat.topic(conversationID: cid) }

    private func eventLine(topic: String, seq: Int) -> String {
        #"{"kind":"event","topic":"\#(topic)","trustClass":"trusted","originTrust":"system","seq":\#(seq),"value":{"ok":true}}"#
    }

    private func wireLine(_ json: String) -> HarnessOutboundWireLine {
        guard let line = HarnessOutboundWireLine.make(json: json) else {
            Issue.record("invalid test harness line")
            return HarnessOutboundWireLine(json: json, kind: .event, topic: "test", seq: 0)
        }
        return line
    }

    @Test func defaultConfigQueuesConversationEventsBeforeFirstAck() async throws {
        let cfg = WebSocketOutboundFlowConfiguration(
            maxInflightEvents: 2,
            maxInflightStateLike: 8,
            softInflightEvents: 100,
            softInflightStateLike: 100,
            flowPressureCooldownNanoseconds: 60_000_000_000,
            disconnectPendingEventsThreshold: 50_000,
            disconnectBufferedBytesThreshold: 0
        )
        let sent = Mutex<[String]>([])
        let limiter = WebSocketHarnessOutboundFlowLimiter(
            configuration: cfg,
            wsSend: { json in sent.withLock { $0.append(json) } },
            requestDisconnect: {}
        )
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convEvents, seq: 1)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convEvents, seq: 2)))
        try await limiter.sendHarnessLine(wireLine(eventLine(topic: convEvents, seq: 3)))
        #expect(sent.withLock { $0 }.count == 2)
    }
}
