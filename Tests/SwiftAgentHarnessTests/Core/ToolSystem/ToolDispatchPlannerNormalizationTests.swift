import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Tool dispatch planner normalization")
struct ToolDispatchPlannerNormalizationTests {
    @Test("effectivePlannerMode passes serial and mixedDeterministic through unchanged")
    func passesSupportedModesThrough() {
        let serial = ToolDispatchPlannerNormalization.effectivePlannerMode(.serial)
        #expect(serial.mode == .serial)
        #expect(serial.wasAllParallelRemapped == false)

        let mixed = ToolDispatchPlannerNormalization.effectivePlannerMode(.mixedDeterministic)
        #expect(mixed.mode == .mixedDeterministic)
        #expect(mixed.wasAllParallelRemapped == false)

        let unset = ToolDispatchPlannerNormalization.effectivePlannerMode(nil)
        #expect(unset.mode == nil)
        #expect(unset.wasAllParallelRemapped == false)
    }

    @Test("effectivePlannerMode remaps allParallel to mixedDeterministic")
    func remapsAllParallel() {
        let normalized = ToolDispatchPlannerNormalization.effectivePlannerMode(.allParallel)
        #expect(normalized.mode == .mixedDeterministic)
        #expect(normalized.wasAllParallelRemapped == true)
    }

    @Test("dispatch contract remaps allParallel planner mode")
    func dispatchContractRemapsAllParallel() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let readOnlyEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable
        )
        let policy = ToolPolicyConfiguration(
            parallelDispatchEnabled: true,
            dispatchPlannerMode: .allParallel
        )
        let contract = gateway.dispatchContract(from: policy, effectiveEntries: [readOnlyEntry])
        #expect(contract.parallelDispatchEnabled == true)
        #expect(contract.dispatchPlannerMode == .mixedDeterministic)
        #expect(contract.dispatchPlannerMode != .allParallel)
    }

    @Test("dispatch contract with allParallel never yields Kit allParallel planner mode")
    func effectiveContractNeverEmitsKitAllParallel() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let readOnlyEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable
        )
        let policy = ToolPolicyConfiguration(
            parallelDispatchEnabled: true,
            dispatchPlannerMode: .allParallel
        )
        let contract = gateway.dispatchContract(from: policy, effectiveEntries: [readOnlyEntry])
        let kitMode = AgentLoopToolDispatch.kitDispatchPlannerMode(contract.dispatchPlannerMode)
        #expect(kitMode == .mixedDeterministic)
        #expect(kitMode != .allParallel)
    }
}
