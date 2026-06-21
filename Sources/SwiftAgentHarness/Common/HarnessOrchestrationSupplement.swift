import Foundation

/// Optional harness-aligned telemetry carried on ``ConversationOrchestrationState`` when the server
/// enables wire supplements (see server docs). Omitted from JSON when unset; backward-compatible for clients.
public struct HarnessOrchestrationSupplement: Codable, Sendable, Equatable {
    /// Logical milestone (e.g. `modelCallStarted`) aligned with the server’s Agent Runtime mapping.
    public var milestone: String?
    /// Coarse termination bucket (e.g. `naturalStop`, `externalCancellation`).
    public var terminationCategory: String?
    /// Optional detail (e.g. failure message) when category is `failure`.
    public var terminationDetail: String?

    public init(
        milestone: String? = nil,
        terminationCategory: String? = nil,
        terminationDetail: String? = nil
    ) {
        self.milestone = milestone
        self.terminationCategory = terminationCategory
        self.terminationDetail = terminationDetail
    }
}
