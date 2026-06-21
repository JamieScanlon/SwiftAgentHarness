import Foundation

/// Configures optional WebSocket harness outbound flow control (`ack` credits + bounded buffering).
///
/// Default **`enabled`** applies credit-based throttling after the client sends the first `ack` per topic. Opt out via ``disabled`` or [`ServerConfig`](ServerConfig.swift).
public struct WebSocketOutboundFlowConfiguration: Sendable, Equatable {
    /// Master toggle; when `false`, all other fields are ignored.
    public var enabled: Bool

    /// When `true`, state-like topics defer credit windows until the first `ack` for that topic.
    /// High-frequency `*/events` topics still honor ``applyLimitsToHighFrequencyEventsBeforeFirstAck``.
    public var limitOnlyAfterFirstAckPerTopic: Bool

    /// When `true`, high-frequency event topics (`conversation/{id}/events`, trace streams, …) apply
    /// credit windows immediately even before the first client `ack`.
    public var applyLimitsToHighFrequencyEventsBeforeFirstAck: Bool

    /// Maximum **`kind: event`** payloads outstanding per `(topic)` connection slot **without** an `ack` covering those seqs (high-frequency `*/events` topics).
    public var maxInflightEvents: Int

    /// Same as ``maxInflightEvents`` for state-like topics (`*/state`, registries, `pool/health`, `models/registry`).
    public var maxInflightStateLike: Int

    /// Soft threshold on inflight **events-topic** count — crossing may emit `lagging` + `hint: flow_pressure`.
    public var softInflightEvents: Int

    /// Soft threshold on inflight **state-like** event count.
    public var softInflightStateLike: Int

    /// Minimum wall time between synthetic `flow_pressure` lagging notices per topic.
    public var flowPressureCooldownNanoseconds: UInt64

    /// When over capacity on state-like topics, collapse queued pending **`event`** lines to one latest-wins payload.
    public var coalesceStateTopicsWhenOverCapacity: Bool

    /// Disconnect after this many queued **high-frequency** event lines are buffered awaiting capacity (silent drops forbidden).
    public var disconnectPendingEventsThreshold: Int

    /// Disconnect once queued UTF‑8 bytes across pending buffers approximate‑exceeds this budget (`0` disables byte‑budget disconnect).
    public var disconnectBufferedBytesThreshold: Int

    public init(
        enabled: Bool = true,
        limitOnlyAfterFirstAckPerTopic: Bool = true,
        applyLimitsToHighFrequencyEventsBeforeFirstAck: Bool = true,
        maxInflightEvents: Int = 256,
        maxInflightStateLike: Int = 64,
        softInflightEvents: Int = 128,
        softInflightStateLike: Int = 32,
        flowPressureCooldownNanoseconds: UInt64 = 500_000_000,
        coalesceStateTopicsWhenOverCapacity: Bool = true,
        disconnectPendingEventsThreshold: Int = 8192,
        disconnectBufferedBytesThreshold: Int = 16_777_216
    ) {
        self.enabled = enabled
        self.limitOnlyAfterFirstAckPerTopic = limitOnlyAfterFirstAckPerTopic
        self.applyLimitsToHighFrequencyEventsBeforeFirstAck = applyLimitsToHighFrequencyEventsBeforeFirstAck
        self.maxInflightEvents = max(1, maxInflightEvents)
        self.maxInflightStateLike = max(1, maxInflightStateLike)
        self.softInflightEvents = max(1, softInflightEvents)
        self.softInflightStateLike = max(1, softInflightStateLike)
        self.flowPressureCooldownNanoseconds = flowPressureCooldownNanoseconds
        self.coalesceStateTopicsWhenOverCapacity = coalesceStateTopicsWhenOverCapacity
        self.disconnectPendingEventsThreshold = max(64, disconnectPendingEventsThreshold)
        self.disconnectBufferedBytesThreshold = max(0, disconnectBufferedBytesThreshold)
    }

    public static let disabled = WebSocketOutboundFlowConfiguration(enabled: false)
}
