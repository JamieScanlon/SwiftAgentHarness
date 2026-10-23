import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

/// Keeps docs/DECISION_MODELS.md honest: each test mirrors a guide sample. The only substitutions are a mock
/// transport and a static candidate source in place of `registerDefaults` and the host's `ModelManager`.
@Suite("Decision models guide examples")
struct DecisionGuideExamplesTests {
    /// Answers the gate's `verdict` with P(clear) = 0.99 from `jev-1.13.0`, and anything else with 0.9.
    private func vendor() -> MockDecisionTransport {
        MockDecisionTransport(handler: { request in
            if request.httpMethod == "GET" { return .ok("{}") }
            let ids = request.jsonBody?[test: "questions"]?.testObject?.keys.sorted() ?? []
            let answers = ids.map { id in
                id == ToolApprovalClassifierConfiguration.questionID
                    ? "\"\(id)\": {\"type\": \"choice\", \"choice\": \"clear\", \"probabilities\": {\"clear\": 0.99, \"caution\": 0.01}}"
                    : "\"\(id)\": {\"type\": \"noul\", \"noul\": 0.9}"
            }.joined(separator: ",")
            return .ok("{\"model\": \"jev-1.13.0\", \"answers\": {\(answers)}}")
        })
    }

    @Test("Quick start: a pinned decider with an alias, a version-keyed policy, a bound role, and a prepared gate")
    func quickStart() async throws {
        let decider = DecisionRuntimeConfig(
            providerID: "typesafe",
            label: "TypeSafe SystemOne",
            surface: .systemOne,
            serverURL: URL(string: "https://api.typesafe.ai/v1")!,
            apiKeyEnvVars: ["TYPESAFE_API_KEY"],
            models: [
                DecisionModelConfig(endpointModelID: "jev-1.13.0", aliases: ["jev-latest"], roles: ["gatekeeper"]),
            ]
        )
        let policy = DecisionPolicy(
            question: ToolApprovalClassifierConfiguration.questionID,
            bands: ["jev-1.13.0": .ranges(
                confirm: DecisionRange(0, 0.95, upperOpen: true),
                act: DecisionRange(0.95, 1)
            )]
        )
        let roles = RoleBindingResolver(settings: [
            .gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide, pin: "jev-1.13.0"),
        ])
        let provider = HTTPDecisionProvider(
            manifest: decider.manifest(), entries: decider.registryEntries(), transport: vendor(),
            retryExecutor: instantRetryExecutor(), credential: { _ in "sk-test" }
        )
        let dispatcher = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource(decider.registryEntries()),
            providers: StaticDecisionProviderResolver(["typesafe": provider]),
            roles: roles,
            logger: DecisionLogCapture().logger
        )
        let gate = ToolApprovalClassifierGate(
            dispatcher: dispatcher,
            configuration: ToolApprovalClassifierConfiguration(policy: policy)
        )
        let (validation, aliasProbes) = await gate.prepare()
        #expect(validation.canAct)
        #expect(aliasProbes.map(\.status) == [.matches])
        guard case .allowOnce(let reason, _) = await gate.evaluate(GatekeeperFixtures.input()) else {
            Issue.record("the quick-start gate should approve a clear call")
            return
        }
        #expect(reason.contains("model=jev-1.13.0"))
    }

    @Test("Local server sample: quirks as profile config, and a local auth profile")
    func localServer() {
        let local = DecisionRuntimeConfig(
            providerID: "local-decider",
            label: "Local decider",
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            models: [DecisionModelConfig(
                endpointModelID: "my-decider-q8",
                profile: DecisionProfiles.systemOne(
                    images: FeatureSupport(params: ["encoding": .string("images-array")]),
                    extraFeatures: [
                        DecisionFeatureKey.modelField: FeatureSupport(params: ["mode": .string("omit")]),
                    ],
                    limits: ContractLimits(contextTokens: 32_768, maxItemsPerCall: 64, maxOptions: 255, scoreLevels: 2...10)
                )
            )]
        )
        let authStore = AuthProfileStore(environment: [:], seedProfiles: [
            AuthProfile(id: "local-decider", providerID: "local-decider", authType: .local,
                        baseURL: URL(string: "http://127.0.0.1:8080")!),
        ])
        #expect(local.isLocal)
        #expect(local.registryEntries()[0].locality == .local)
        let options = DecisionSurfaceOptions(profile: local.registryEntries()[0].profile(for: .decide)!)
        #expect(!options.sendModel)
        #expect(options.imagesEncoding == .imagesArray)
        #expect(authStore.seedProfiles.first?.authType == .local)
    }

    @Test("Policy, escalation, and role samples validate")
    func policyAndRoles() throws {
        let basePolicy = DecisionPolicy(
            question: "verdict",
            on: .p,
            bands: [
                "jev-1.13.0": .ranges(
                    refuse: nil,
                    confirm: DecisionRange(0, 0.95, upperOpen: true),
                    act: DecisionRange(0.95, 1)
                ),
            ],
            onUnavailable: .confirm,
            onRefusal: .confirm,
            onError: .confirm,
            escalate: nil
        )
        try basePolicy.validate()

        var policy = basePolicy
        policy.escalate = DecisionEscalation(to: "jev-xl-2.0", when: .pBetween(0.5, 0.95))
        policy.bands["jev-xl-2.0"] = .ranges(confirm: DecisionRange(0, 0.9, upperOpen: true), act: DecisionRange(0.9, 1))
        try policy.validate()
        #expect(policy.tunedVersions == ["jev-1.13.0", "jev-xl-2.0"])

        let roles = RoleBindingResolver(
            settings: [
                .gatekeeper: RoleBinding(
                    role: .gatekeeper,
                    contract: .decide,
                    minGuarantee: .calibratedDistribution,
                    pin: "jev-1.13.0",
                    fallback: ["jev-1.12.0"],
                    priority: .background,
                    locality: .any,
                    budget: RoleBudget(maxUSDPerCall: 0.001)
                ),
            ],
            modePatches: [:],
            conversationPatches: [:]
        )
        #expect(roles.resolve(.gatekeeper)?.pin == "jev-1.13.0")
        #expect(roles.resolve(.memoryGate) == nil)
    }

    @Test("Direct dispatch sample returns a conservative verdict and never throws")
    func directDispatch() async {
        let dispatcher = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource([]),
            roles: RoleBindingResolver(settings: [.memoryGate: RoleBinding(role: .memoryGate, contract: .decide)]),
            receipts: InMemoryRouteReceiptRecorder(capacity: 500),
            cache: DecisionResponseCache(),
            logger: DecisionLogCapture().logger
        )
        let memoryPolicy = DecisionFixtures.gatePolicy(versions: ["v1"], question: "safe")
        let outcome = await dispatcher.decide(
            DecisionFixtures.yesNoRequest(), role: .memoryGate, policy: memoryPolicy,
            context: DecisionCallContext(conversationID: UUID(), timeBudget: .seconds(1))
        )
        switch outcome.verdict {
        case .act?: Issue.record("no candidate must never act")
        case .confirm?, .refuse?, nil: break
        }
    }
}
