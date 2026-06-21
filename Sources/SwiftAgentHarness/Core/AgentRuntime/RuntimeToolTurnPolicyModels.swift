import Foundation
import SwiftAgentKit

struct RuntimeToolAvailabilitySnapshot: Sendable {
    let entry: ToolRegistryEntry
    let decision: ToolAvailabilityDecision
}

struct RuntimeToolTurnPolicySnapshot: Sendable {
    let availabilitySnapshots: [RuntimeToolAvailabilitySnapshot]
    let effectiveEntries: [ToolRegistryEntry]
    let dispatchContract: AgentRuntimeToolDispatchContract

    var effectiveTools: [ToolDefinition] {
        effectiveEntries.map(\.definition)
    }
}

