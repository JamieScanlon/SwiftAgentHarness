import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Mode registry concurrency")
struct ModeRegistryConcurrencyTests {
    @Test("Parallel resolve and register remain consistent")
    func parallelResolveAndRegister() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let customProfile = ResolvedModeProfile(
            id: "concurrency-mode",
            interactionMode: .plan,
            assemblyKind: .planCollaboration,
            allowsProactiveCompactionTriggers: true,
            appliesAgentBuildOrchestratorHarness: false,
            builtInSeedVersion: 0,
            semanticLayerTags: []
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    _ = try? await registry.resolve(modeId: InteractionMode.chat.rawValue)
                }
            }
            for _ in 0..<8 {
                group.addTask {
                    try? await registry.register(customProfile, replacing: true)
                }
            }
            for _ in 0..<8 {
                group.addTask {
                    _ = await registry.registeredModeIDs()
                }
            }
        }

        let ids = await registry.registeredModeIDs()
        #expect(ids.contains("chat"))
        #expect(ids.contains("concurrency-mode"))
        let resolved = try await registry.resolve(modeId: "concurrency-mode")
        #expect(resolved.id == "concurrency-mode")
    }
}
