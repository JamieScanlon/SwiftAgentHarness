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
    let groupIndex: ToolPolicyGroupIndex
    let nameIndex: ToolRegistryNameIndex
    let modePolicyContext: ModePolicyContext

    init(
        availabilitySnapshots: [RuntimeToolAvailabilitySnapshot],
        effectiveEntries: [ToolRegistryEntry],
        dispatchContract: AgentRuntimeToolDispatchContract,
        groupIndex: ToolPolicyGroupIndex? = nil,
        nameIndex: ToolRegistryNameIndex? = nil,
        modePolicyContext: ModePolicyContext? = nil,
        catalogEntriesForNameIndex: [ToolRegistryEntry]? = nil
    ) {
        self.availabilitySnapshots = availabilitySnapshots
        self.effectiveEntries = effectiveEntries
        self.dispatchContract = dispatchContract
        let entriesForGroups = catalogEntriesForNameIndex ?? effectiveEntries
        let builtNameIndex = nameIndex ?? ToolRegistryNameIndex.build(entries: entriesForGroups)
        self.groupIndex = groupIndex ?? ToolPolicyGroupIndex.build(from: entriesForGroups)
        self.nameIndex = builtNameIndex
        self.modePolicyContext = modePolicyContext
            ?? ModePolicyContext(interactionMode: .agent, resolvedProfile: .builtIn(for: .agent))
    }

    var effectiveTools: [ToolDefinition] {
        effectiveEntries.map(\.definition)
    }
}

