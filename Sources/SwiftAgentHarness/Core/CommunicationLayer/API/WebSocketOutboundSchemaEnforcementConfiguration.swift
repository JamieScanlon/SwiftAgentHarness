import Foundation

/// Runtime policy for outbound WebSocket schema-contract enforcement violations.
public struct WebSocketOutboundSchemaEnforcementConfiguration: Sendable, Equatable {
    /// Master toggle for runtime outbound contract enforcement.
    public var enabled: Bool
    /// Violations at or above this count (within ``windowNanoseconds``) trigger connection close.
    public var disconnectAfterViolations: Int
    /// Sliding window for repeated-violation disconnect policy.
    public var windowNanoseconds: UInt64

    public init(
        enabled: Bool = true,
        disconnectAfterViolations: Int = 5,
        windowNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.enabled = enabled
        self.disconnectAfterViolations = max(2, disconnectAfterViolations)
        self.windowNanoseconds = max(1_000_000_000, windowNanoseconds)
    }

    public static let disabled = WebSocketOutboundSchemaEnforcementConfiguration(enabled: false)
    public static let `default` = WebSocketOutboundSchemaEnforcementConfiguration()
}
