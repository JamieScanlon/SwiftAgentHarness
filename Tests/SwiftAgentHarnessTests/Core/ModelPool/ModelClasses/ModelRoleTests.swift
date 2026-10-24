import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Model roles")
struct ModelRoleTests {
    @Test("Well-known roles map to their contracts")
    func wellKnownContracts() {
        #expect(ModelRole.main.wellKnownContract == .generate)
        #expect(ModelRole.compactor.wellKnownContract == .generate)
        #expect(ModelRole.gatekeeper.wellKnownContract == .decide)
        #expect(ModelRole.guardrail.wellKnownContract == .decide)
        #expect(ModelRole.router.wellKnownContract == .decide)
        #expect(ModelRole.skillFilter.wellKnownContract == .decide)
        #expect(ModelRole.memoryGate.wellKnownContract == .decide)
        #expect(ModelRole.embedder(space: "text-v3").wellKnownContract == .embed)
        #expect(ModelRole.embedder(space: "text-v3").embeddingSpace == "text-v3")
        #expect(ModelRole.reranker.wellKnownContract == .rerank)
        #expect(ModelRole.image.wellKnownContract == .render)
        #expect(ModelRole(rawValue: "host-custom").wellKnownContract == nil)
        #expect(ModelRole.guardrail.rawValue == "guard")
    }

    @Test("Unbound defaults follow the roles table")
    func defaults() {
        #expect(ModelRole.main.defaultWhenUnbound == .required)
        #expect(ModelRole.subagent.defaultWhenUnbound == .role(.main))
        #expect(ModelRole.compactor.defaultWhenUnbound == .chain([.backgroundSmall, .main]))
        #expect(ModelRole.recall.defaultWhenUnbound == .role(.backgroundSmall))
        #expect(ModelRole.gatekeeper.defaultWhenUnbound == .off)
        #expect(ModelRole.embedder(space: "x").defaultWhenUnbound == .off)
    }

    @Test("Unbound decide roles resolve to nil, so the consuming layer is off")
    func unboundDecideRole() {
        let resolver = RoleBindingResolver()
        #expect(resolver.resolve(.gatekeeper) == nil)
        #expect(resolver.resolve(.main) == nil)
    }

    @Test("Default chains walk to the first bound role")
    func defaultChain() {
        let main = RoleBinding(role: .main, contract: .generate, pin: "big-model", priority: .foreground, thinking: .adaptive)
        var resolver = RoleBindingResolver(settings: [.main: main])
        let compactor = resolver.resolve(.compactor)
        #expect(compactor?.pin == "big-model")
        #expect(compactor?.role == .compactor)
        #expect(compactor?.thinking == nil)
        #expect(compactor?.effectiveThinking == .disabled)

        resolver.settings[.backgroundSmall] = RoleBinding(role: .backgroundSmall, contract: .generate, pin: "small-model")
        #expect(resolver.resolve(.compactor)?.pin == "small-model")
        #expect(resolver.resolve(.subagent)?.pin == "big-model")
    }

    @Test("Layers apply in order: settings, mode patch, conversation patch, per-call pin")
    func layering() {
        let settings = RoleBinding(role: .gatekeeper, contract: .decide, pin: "settings-pin", fallback: ["fb-1"])
        let resolver = RoleBindingResolver(
            settings: [.gatekeeper: settings],
            modePatches: [.gatekeeper: RoleBindingPatch(pin: "mode-pin", locality: .localOnly)],
            conversationPatches: [.gatekeeper: RoleBindingPatch(fallback: ["fb-2"], budget: RoleBudget(maxUSDPerCall: 0.01))]
        )
        let resolved = resolver.resolve(.gatekeeper)
        #expect(resolved?.pin == "mode-pin")
        #expect(resolved?.locality == .localOnly)
        #expect(resolved?.fallback == ["fb-2"])
        #expect(resolved?.budget?.maxUSDPerCall == 0.01)
        #expect(resolver.resolve(.gatekeeper, pin: "call-pin")?.pin == "call-pin")
    }

    @Test("A patch alone binds a well-known role with its contract")
    func patchOnly() {
        let resolver = RoleBindingResolver(conversationPatches: [.router: RoleBindingPatch(pin: "router-model")])
        let resolved = resolver.resolve(.router)
        #expect(resolved?.contract == .decide)
        #expect(resolved?.pin == "router-model")
    }

    @Test("minGuarantee patches flow into the query")
    func minGuaranteePatch() {
        let resolver = RoleBindingResolver(
            settings: [.memoryGate: RoleBinding(role: .memoryGate, contract: .decide)],
            modePatches: [.memoryGate: RoleBindingPatch(minGuarantee: .calibratedDistribution)]
        )
        let resolved = resolver.resolve(.memoryGate)
        #expect(resolved?.minGuarantee == .calibratedDistribution)
        #expect(resolved?.query.minGuarantee == .calibratedDistribution)
    }

    @Test("Thinking rule: decide and safety roles never think; background roles opt in explicitly")
    func thinkingRule() {
        #expect(RoleBinding(role: .router, contract: .decide, thinking: .adaptive).effectiveThinking == .disabled)
        #expect(RoleBinding(role: .gatekeeper, contract: .generate, thinking: .adaptive).effectiveThinking == .disabled)
        #expect(RoleBinding(role: .guardrail, contract: .generate, thinking: .adaptive).effectiveThinking == .disabled)
        #expect(RoleBinding(role: .backgroundSmall, contract: .generate).effectiveThinking == .disabled)
        #expect(RoleBinding(role: .compactor, contract: .generate, thinking: .adaptive).effectiveThinking == .adaptive)
        #expect(RoleBinding(role: .main, contract: .generate).effectiveThinking == nil)
        #expect(RoleBinding(role: .main, contract: .generate, thinking: .level(.high, budgetTokens: 10)).effectiveThinking
            == .level(.high, budgetTokens: 10))
    }

    @Test("Embedders and threshold-bearing decide roles are compat-bound")
    func compatBound() {
        let tuned = DecisionFixtures.gatePolicy(versions: ["v1"])
        let untuned = DecisionPolicy(question: "q", bands: [:])
        #expect(RoleBinding(role: .embedder(space: "s"), contract: .embed).isCompatBound(policy: nil))
        #expect(RoleBinding(role: .gatekeeper, contract: .decide).isCompatBound(policy: tuned))
        #expect(!RoleBinding(role: .gatekeeper, contract: .decide).isCompatBound(policy: untuned))
        #expect(!RoleBinding(role: .gatekeeper, contract: .decide).isCompatBound(policy: nil))
        #expect(!RoleBinding(role: .main, contract: .generate).isCompatBound(policy: tuned))
    }

    @Test("Role locality admits only matching entries")
    func locality() {
        #expect(RoleLocality.any.admits(nil))
        #expect(RoleLocality.localOnly.admits(.local))
        #expect(!RoleLocality.localOnly.admits(.vendor))
        #expect(!RoleLocality.localOnly.admits(nil))
        #expect(RoleLocality.noVendorRetention.admits(.vendorNoRetention))
        #expect(RoleLocality.noVendorRetention.admits(.local))
        #expect(!RoleLocality.noVendorRetention.admits(.vendor))
    }

    @Test("Role bindings round-trip through Codable")
    func codable() throws {
        let binding = RoleBinding(
            role: .gatekeeper, contract: .decide, minGuarantee: .calibratedDistribution, pin: "d-1",
            fallback: ["d-2"], cascade: RoleCascade(to: "d-big", when: .pBetween(0.4, 0.8)),
            thinking: .disabled, locality: .noVendorRetention, budget: RoleBudget(maxUSDPerCall: 0.001)
        )
        let decoded = try JSONDecoder().decode(RoleBinding.self, from: JSONEncoder().encode(binding))
        #expect(decoded == binding)
    }
}

@Suite("Route receipts")
struct RouteReceiptTests {
    @Test("In-memory recorder keeps the most recent receipts up to capacity")
    func recorderCapacity() async {
        let recorder = InMemoryRouteReceiptRecorder(capacity: 2)
        for name in ["a", "b", "c"] {
            await recorder.record(RouteReceipt(role: .gatekeeper, contract: .decide, requested: name))
        }
        let receipts = await recorder.receipts
        #expect(receipts.map(\.requested) == ["b", "c"])
    }
}
