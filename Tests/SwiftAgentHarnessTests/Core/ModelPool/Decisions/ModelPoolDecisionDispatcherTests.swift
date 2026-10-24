import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private func gatekeeper(
    pin: String? = nil,
    fallback: [String] = [],
    minGuarantee: OutputGuarantee? = nil,
    locality: RoleLocality = .any,
    budget: RoleBudget? = nil,
    cascade: RoleCascade? = nil,
    query: ContractQuery? = nil
) -> RoleBindingResolver {
    RoleBindingResolver(settings: [.gatekeeper: RoleBinding(
        role: .gatekeeper, contract: .decide, minGuarantee: minGuarantee, query: query, pin: pin,
        fallback: fallback, cascade: cascade, locality: locality, budget: budget
    )])
}

private func dispatcher(
    entries: [ModelRegistryEntry],
    providers: [ProviderID: any DecisionProviding],
    roles: RoleBindingResolver,
    emulator: (any DecisionEmulationLLMProviding)? = nil,
    scheduler: any ModelCallScheduling = NoOpModelCallScheduler(),
    budget: any BudgetAccounting = AlwaysAllowBudgetAccounting(),
    receipts: InMemoryRouteReceiptRecorder = InMemoryRouteReceiptRecorder(),
    cache: DecisionResponseCache? = nil
) -> ModelPoolDecisionDispatcher {
    ModelPoolDecisionDispatcher(
        candidates: StaticContractCandidateSource(entries),
        providers: StaticDecisionProviderResolver(providers),
        roles: roles,
        emulator: emulator,
        scheduler: scheduler,
        budgetAccounting: budget,
        receipts: receipts,
        cache: cache
    )
}

@Suite("Model Pool decision dispatcher")
struct ModelPoolDecisionDispatcherTests {
    @Test("An unbound decide role fails conservatively and still emits a receipt")
    func unboundRole() async {
        let receipts = InMemoryRouteReceiptRecorder()
        let pool = dispatcher(entries: [], providers: [:], roles: RoleBindingResolver(), receipts: receipts)
        let outcome = await pool.decide(
            DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: DecisionFixtures.gatePolicy(versions: ["v1"])
        )
        #expect(outcome.error == .roleUnbound(.gatekeeper))
        #expect(outcome.verdict == .confirm)
        #expect(outcome.result == nil)
        let recorded = await receipts.receipts
        #expect(recorded.count == 1)
        #expect(recorded[0].decision?.reason == .error)
    }

    @Test("A calibrated answer in the act band acts, with the version, band, cost, and request id on the receipt")
    func actsWithReceipt() async {
        let receipts = InMemoryRouteReceiptRecorder()
        let entry = DecisionFixtures.decider("d-2026-09", prices: [PriceComponent(unit: .inputToken, usd: 0.04, per: 1_000_000)])
        let pool = dispatcher(
            entries: [entry],
            providers: ["decider": FakeDecisionProvider.constant(providerID: "decider", pYes: 0.97, inputTokens: 1_000)],
            roles: gatekeeper(),
            receipts: receipts
        )
        let outcome = await pool.decide(
            DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: DecisionFixtures.gatePolicy(versions: ["d-2026-09"])
        )
        #expect(outcome.verdict == .act)
        #expect(outcome.error == nil)
        let receipt = outcome.receipt
        #expect(receipt.contract == .decide)
        #expect(receipt.role == .gatekeeper)
        #expect(receipt.resolved?.versionServed == "d-2026-09")
        #expect(receipt.resolved?.bindingID == "decider/d-2026-09")
        #expect(receipt.resolved?.surface == .systemOne)
        #expect(receipt.guarantee == .calibratedDistribution)
        #expect(abs(receipt.costUSD! - 0.00004) < 1e-12)
        #expect(receipt.requestIDs == ["req-d-2026-09"])
        #expect(receipt.decision?.verdict == .act)
        #expect(receipt.decision?.value == 0.97)
        #expect(receipt.cascade == nil)
        #expect(await receipts.receipts.count == 1)
    }

    @Test("Availability errors fall back to the next candidate in the same compat group")
    func fallbackOnTransient() async {
        let primary = DecisionFixtures.decider("primary", provider: "a", compatGroup: "fam")
        let backup = DecisionFixtures.decider("backup", provider: "b", compatGroup: "fam")
        let pool = dispatcher(
            entries: [primary, backup],
            providers: [
                "a": FakeDecisionProvider.failing(providerID: "a", status: 503),
                "b": FakeDecisionProvider.constant(providerID: "b", pYes: 0.95),
            ],
            roles: gatekeeper(pin: "primary", fallback: ["backup"])
        )
        let outcome = await pool.decide(
            DecisionFixtures.yesNoRequest(), role: .gatekeeper,
            policy: DecisionFixtures.gatePolicy(versions: ["primary", "backup"])
        )
        #expect(outcome.verdict == .act)
        #expect(outcome.receipt.resolved?.modelID == "backup")
        #expect(outcome.receipt.fallback == [RouteReceipt.Fallback(from: "a/primary", reason: .transient)])
    }

    @Test("A fallback whose version has no bands answers as untuned, never act")
    func fallbackWithoutBands() async {
        let primary = DecisionFixtures.decider("primary", provider: "a", compatGroup: "fam")
        let backup = DecisionFixtures.decider("backup", provider: "b", compatGroup: "fam")
        let pool = dispatcher(
            entries: [primary, backup],
            providers: [
                "a": FakeDecisionProvider.failing(providerID: "a", status: 429),
                "b": FakeDecisionProvider.constant(providerID: "b", pYes: 0.99),
            ],
            roles: gatekeeper(pin: "primary", fallback: ["backup"])
        )
        let outcome = await pool.decide(
            DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: DecisionFixtures.gatePolicy(versions: ["primary"])
        )
        #expect(outcome.verdict == .confirm)
        #expect(outcome.evaluation?.reason == .untunedVersion)
    }

    @Test("Threshold-bearing roles never fall back across compat groups")
    func noCrossGroupFallback() async {
        let primary = DecisionFixtures.decider("primary", provider: "a", compatGroup: "fam-1")
        let other = DecisionFixtures.decider("other", provider: "b", compatGroup: "fam-2")
        let otherCounter = CallCounter()
        let pool = dispatcher(
            entries: [primary, other],
            providers: [
                "a": FakeDecisionProvider.failing(providerID: "a", status: 503),
                "b": FakeDecisionProvider.constant(providerID: "b", pYes: 0.99, counter: otherCounter),
            ],
            roles: gatekeeper(pin: "primary", fallback: ["other"])
        )
        let outcome = await pool.decide(
            DecisionFixtures.yesNoRequest(), role: .gatekeeper,
            policy: DecisionFixtures.gatePolicy(versions: ["primary", "other"])
        )
        #expect(outcome.verdict == .confirm)
        #expect(outcome.error == .provider(classification: .transient, message: String(describing: DecisionProviderError.http(status: 503, body: "{}", requestID: nil))))
        #expect(await otherCounter.count == 0)
        #expect(outcome.receipt.rankedOut.contains { $0.reason.contains("compat group") })
    }

    @Test("Without a tuned policy the role is not compat-bound and may fall back anywhere")
    func untunedRoleFallsBackAnywhere() async {
        let primary = DecisionFixtures.decider("primary", provider: "a", compatGroup: "fam-1")
        let other = DecisionFixtures.decider("other", provider: "b", compatGroup: "fam-2")
        let pool = dispatcher(
            entries: [primary, other],
            providers: [
                "a": FakeDecisionProvider.failing(providerID: "a", status: 503),
                "b": FakeDecisionProvider.constant(providerID: "b", pYes: 0.99),
            ],
            roles: gatekeeper(pin: "primary", fallback: ["other"])
        )
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(outcome.result?.modelVersion == "other")
        #expect(outcome.evaluation == nil)
    }

    @Test("Quality-class and permanent errors never fall back")
    func noFallbackOnPermanent() async {
        let primary = DecisionFixtures.decider("primary", provider: "a")
        let backup = DecisionFixtures.decider("backup", provider: "b")
        let backupCounter = CallCounter()
        let pool = dispatcher(
            entries: [primary, backup],
            providers: [
                "a": FakeDecisionProvider.failing(providerID: "a", status: 422),
                "b": FakeDecisionProvider.constant(providerID: "b", pYes: 0.9, counter: backupCounter),
            ],
            roles: gatekeeper(pin: "primary", fallback: ["backup"])
        )
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: DecisionFixtures.gatePolicy(versions: ["primary"]))
        #expect(outcome.verdict == .confirm)
        #expect(outcome.receipt.errorClassification == .permanent)
        #expect(await backupCounter.count == 0)
    }

    @Test("The hard filter drops bindings that cannot answer every question kind")
    func hardFilterQuestionKinds() async {
        let openAI = DecisionFixtures.decider("openai-decider", provider: "openai-d", profile: DecisionProfiles.openAIDecisions())
        let systemOne = DecisionFixtures.decider(
            "s1", provider: "s1",
            profile: DecisionProfiles.systemOne(images: FeatureSupport(params: ["encoding": .string("assets")]))
        )
        let pool = dispatcher(
            entries: [openAI, systemOne],
            providers: [
                "openai-d": FakeDecisionProvider.constant(providerID: "openai-d", pYes: 0.5),
                "s1": FakeDecisionProvider(providerID: "s1") { request, target in
                    DecisionResult(modelVersion: "s1", calibrated: true, guarantee: .calibratedDistribution,
                                   answers: ["button": .box(DecisionBox(top: 0, left: 0, bottom: 0.5, right: 0.5), peak: nil)])
                },
            ],
            roles: RoleBindingResolver(settings: [.guardrail: RoleBinding(role: .guardrail, contract: .decide)])
        )
        let request = DecisionRequest(
            state: .string("screen"),
            assets: ["shot": DecisionImageAsset(mediaType: .png, data: Data([1]))],
            questions: [DecisionQuestionItem("button", .box(instructions: .string("find it")))]
        )
        let outcome = await pool.decide(request, role: .guardrail)
        #expect(outcome.receipt.resolved?.modelID == "s1")
        #expect(outcome.receipt.rankedOut.contains { $0.modelID == "openai-d/openai-decider" && $0.reason.contains("box") })
    }

    @Test("local-only roles fail closed when no local decider exists")
    func localityFailsClosed() async {
        let cloud = DecisionFixtures.decider("cloud", locality: .vendor)
        let pool = dispatcher(
            entries: [cloud],
            providers: ["decider": FakeDecisionProvider.constant(providerID: "decider", pYes: 0.99)],
            roles: gatekeeper(locality: .localOnly)
        )
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: DecisionFixtures.gatePolicy(versions: ["cloud"]))
        #expect(outcome.error == .noCandidate(role: .gatekeeper, localityRestricted: true))
        #expect(outcome.verdict == .confirm)
    }

    @Test("Retired entries are never selected; deprecated ones only when pinned")
    func lifecycle() async {
        let retired = DecisionFixtures.decider("old", lifecycle: ModelLifecycle(status: .retired))
        let deprecated = DecisionFixtures.decider("aging", lifecycle: ModelLifecycle(status: .deprecated))
        let providers: [ProviderID: any DecisionProviding] = ["decider": FakeDecisionProvider.constant(providerID: "decider", pYes: 0.9)]
        let open = dispatcher(entries: [retired, deprecated], providers: providers, roles: gatekeeper())
        let openOutcome = await open.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(openOutcome.error == .noCandidate(role: .gatekeeper, localityRestricted: false))

        let pinned = dispatcher(entries: [retired, deprecated], providers: providers, roles: gatekeeper(pin: "aging"))
        #expect(await pinned.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper).result?.modelVersion == "aging")

        let pinnedRetired = dispatcher(entries: [retired], providers: providers, roles: gatekeeper(pin: "old"))
        #expect(await pinnedRetired.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper).error == .pinRejected(pin: "old", reason: "retired"))
    }

    @Test("A pin must satisfy minGuarantee; an emulated chat model cannot stand in for a calibrated decider")
    func pinMustMeetGuarantee() async {
        let chat = DecisionFixtures.chatModel("chat-1")
        let pool = dispatcher(
            entries: [chat], providers: [:],
            roles: gatekeeper(pin: "chat-1", minGuarantee: .calibratedDistribution),
            emulator: FixedEmulationProvider(llm: ScriptedDecisionLLM(responses: []))
        )
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        guard case .pinRejected(let pin, let reason) = outcome.error else {
            Issue.record("expected pinRejected, got \(String(describing: outcome.error))")
            return
        }
        #expect(pin == "chat-1")
        #expect(reason.contains("guarantee"))
        #expect(await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, context: DecisionCallContext(pin: "missing")).error
            == .pinRejected(pin: "missing", reason: "not in registry"))
    }

    @Test("The Pool never emulates silently: chat models are used only when named")
    func noSilentEmulation() async {
        let chat = DecisionFixtures.chatModel("chat-1")
        let llm = ScriptedDecisionLLM(responses: [LLMResponse(content: "{\"safe\": \"yes\"}")])
        let emulator = FixedEmulationProvider(llm: llm)
        let open = dispatcher(entries: [chat], providers: [:], roles: gatekeeper(), emulator: emulator)
        #expect(await open.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper).error == .noCandidate(role: .gatekeeper, localityRestricted: false))
        #expect(await llm.callCount == 0)

        let named = dispatcher(entries: [chat], providers: [:], roles: gatekeeper(pin: "chat-1"), emulator: emulator)
        let outcome = await named.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: DecisionFixtures.gatePolicy(versions: ["chat-1"]))
        #expect(outcome.result?.calibrated == false)
        #expect(outcome.receipt.resolved?.surface == .llmEmulation)
        #expect(outcome.receipt.guarantee == .schemaStrict)
        #expect(outcome.verdict == .confirm)
        #expect(outcome.evaluation?.reason == .uncalibrated)
    }

    @Test("Chat models advertising logprobs are emulated on the logprobs rung")
    func logprobsRung() async {
        let chat = DecisionFixtures.chatModel("chat-lp", logprobs: true)
        let llm = ScriptedDecisionLLM(responses: [ScriptedDecisionLLM.logprobs([("Y", 0.8), ("N", 0.2)])])
        let pool = dispatcher(entries: [chat], providers: [:], roles: gatekeeper(pin: "chat-lp"), emulator: FixedEmulationProvider(llm: llm))
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(outcome.receipt.guarantee == .logprobs)
        guard case .yesNo(let p)? = outcome.result?.answers["safe"] else { Issue.record("expected yes-no"); return }
        #expect(abs(p - 0.8) < 1e-9)
    }

    @Test("An ambiguous stage-1 answer escalates once; stage 2 is final and both stages are billed")
    func cascadeEscalates() async {
        let small = DecisionFixtures.decider("small", provider: "a", prices: [PriceComponent(unit: .inputToken, usd: 1, per: 1_000_000)])
        let big = DecisionFixtures.decider("big", provider: "b", prices: [PriceComponent(unit: .inputToken, usd: 10, per: 1_000_000)])
        let smallCounter = CallCounter()
        let pool = dispatcher(
            entries: [small, big],
            providers: [
                "a": FakeDecisionProvider.constant(providerID: "a", pYes: 0.6, inputTokens: 1_000, counter: smallCounter),
                "b": FakeDecisionProvider.constant(providerID: "b", pYes: 0.95, inputTokens: 1_000),
            ],
            roles: gatekeeper(pin: "small")
        )
        let policy = DecisionFixtures.gatePolicy(
            versions: ["small", "big"],
            escalate: DecisionEscalation(to: "big", when: .pBetween(0.4, 0.9))
        )
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: policy)
        #expect(outcome.verdict == .act)
        #expect(outcome.result?.modelVersion == "big")
        #expect(outcome.firstStage?.modelVersion == "small")
        #expect(outcome.receipt.cascade?.escalated == true)
        #expect(outcome.receipt.cascade?.firstStage?.versionServed == "small")
        #expect(outcome.receipt.resolved?.versionServed == "big")
        #expect(abs(outcome.receipt.costUSD! - (0.001 + 0.01)) < 1e-12)
        #expect(outcome.receipt.requestIDs == ["req-small", "req-big"])
        #expect(await smallCounter.count == 1)
    }

    @Test("A confident stage-1 answer does not escalate")
    func cascadeNotNeeded() async {
        let small = DecisionFixtures.decider("small", provider: "a")
        let big = DecisionFixtures.decider("big", provider: "b")
        let bigCounter = CallCounter()
        let pool = dispatcher(
            entries: [small, big],
            providers: [
                "a": FakeDecisionProvider.constant(providerID: "a", pYes: 0.98),
                "b": FakeDecisionProvider.constant(providerID: "b", pYes: 0.98, counter: bigCounter),
            ],
            roles: gatekeeper(pin: "small")
        )
        let policy = DecisionFixtures.gatePolicy(versions: ["small", "big"], escalate: DecisionEscalation(to: "big", when: .pBetween(0.4, 0.9)))
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: policy)
        #expect(outcome.receipt.cascade == RouteReceipt.Cascade(escalated: false))
        #expect(outcome.firstStage == nil)
        #expect(await bigCounter.count == 0)
    }

    @Test("Escalating to a chat model can only move toward confirm or refuse")
    func escalateToChatNeverActs() async {
        let small = DecisionFixtures.decider("small", provider: "a")
        let chat = DecisionFixtures.chatModel("main-llm")
        let llm = ScriptedDecisionLLM(responses: [LLMResponse(content: "{\"safe\": \"yes\"}")])
        let pool = dispatcher(
            entries: [small, chat],
            providers: ["a": FakeDecisionProvider.constant(providerID: "a", pYes: 0.7)],
            roles: gatekeeper(pin: "small"),
            emulator: FixedEmulationProvider(llm: llm)
        )
        let policy = DecisionFixtures.gatePolicy(versions: ["small", "main-llm"], escalate: DecisionEscalation(to: "main-llm", when: .pBelow(0.9)))
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: policy)
        #expect(outcome.receipt.cascade?.escalated == true)
        #expect(outcome.result?.calibrated == false)
        #expect(outcome.verdict == .confirm)
    }

    @Test("When the escalation target fails, the call fails conservatively")
    func stageTwoFailure() async {
        let small = DecisionFixtures.decider("small", provider: "a")
        let big = DecisionFixtures.decider("big", provider: "b")
        let pool = dispatcher(
            entries: [small, big],
            providers: [
                "a": FakeDecisionProvider.constant(providerID: "a", pYes: 0.6),
                "b": FakeDecisionProvider.failing(providerID: "b", status: 500),
            ],
            roles: gatekeeper(pin: "small")
        )
        var policy = DecisionFixtures.gatePolicy(versions: ["small", "big"], escalate: DecisionEscalation(to: "big", when: .pBelow(0.9)))
        policy.onError = .refuse
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: policy)
        #expect(outcome.verdict == .refuse)
        #expect(outcome.firstStage?.modelVersion == "small")
        #expect(outcome.receipt.cascade?.reason?.hasPrefix("stage 2 failed") == true)
    }

    @Test("Without a policy, the binding's cascade drives escalation")
    func bindingCascade() async {
        let small = DecisionFixtures.decider("small", provider: "a")
        let big = DecisionFixtures.decider("big", provider: "b")
        let pool = dispatcher(
            entries: [small, big],
            providers: [
                "a": FakeDecisionProvider.constant(providerID: "a", pYes: 0.5),
                "b": FakeDecisionProvider.constant(providerID: "b", pYes: 0.99),
            ],
            roles: gatekeeper(pin: "small", cascade: RoleCascade(to: "big", when: .pBetween(0.3, 0.7)))
        )
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(outcome.result?.modelVersion == "big")
    }

    @Test("Pinned versions are response-cached by (version, request); aliases never are")
    func responseCache() async {
        let counter = CallCounter()
        let pinned = DecisionFixtures.decider("d-2026-09")
        let cache = DecisionResponseCache()
        let provider = FakeDecisionProvider.constant(providerID: "decider", pYes: 0.9, counter: counter)
        let pool = dispatcher(entries: [pinned], providers: ["decider": provider], roles: gatekeeper(), cache: cache)
        _ = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        let second = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        _ = await pool.decide(DecisionFixtures.yesNoRequest(["other"]), role: .gatekeeper)
        #expect(await counter.count == 2)
        #expect(second.receipt.cacheHit)
        #expect(second.receipt.costUSD == 0)

        let aliasCounter = CallCounter()
        let alias = DecisionFixtures.decider("d-latest", lifecycle: ModelLifecycle(status: .active, aliasOf: "d"))
        let aliasProvider = FakeDecisionProvider.constant(providerID: "decider", pYes: 0.9, version: "d-2026-10", counter: aliasCounter)
        let aliasPool = dispatcher(entries: [alias], providers: ["decider": aliasProvider], roles: gatekeeper(), cache: DecisionResponseCache())
        let first = await aliasPool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        _ = await aliasPool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(await aliasCounter.count == 2)
        #expect(first.receipt.aliasResolved == RouteReceipt.AliasResolution(alias: "d-latest", to: "d-2026-10"))
    }

    @Test("Budget denial blocks dispatch; role caps filter expensive candidates")
    func budget() async {
        let entry = DecisionFixtures.decider("d")
        let counter = CallCounter()
        let denied = dispatcher(
            entries: [entry],
            providers: ["decider": FakeDecisionProvider.constant(providerID: "decider", pYes: 0.9, counter: counter)],
            roles: gatekeeper(),
            budget: DenyingBudget()
        )
        let outcome = await denied.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: DecisionFixtures.gatePolicy(versions: ["d"]))
        guard case .budgetDenied = outcome.error else { Issue.record("expected budgetDenied"); return }
        #expect(outcome.verdict == .confirm)
        #expect(await counter.count == 0)

        let pricey = DecisionFixtures.decider("pricey", prices: [PriceComponent(unit: .request, usd: 1, per: 1)])
        let capped = dispatcher(
            entries: [pricey],
            providers: ["decider": FakeDecisionProvider.constant(providerID: "decider", pYes: 0.9)],
            roles: gatekeeper(budget: RoleBudget(maxUSDPerCall: 0.01))
        )
        let cappedOutcome = await capped.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(cappedOutcome.error == .noCandidate(role: .gatekeeper, localityRestricted: false))
    }

    @Test("Budget accounting sees the projection and the input-token settlement")
    func budgetAccounting() async {
        let budget = RecordingBudget()
        let entry = DecisionFixtures.decider("d", prices: [PriceComponent(unit: .inputToken, usd: 1, per: 1_000)])
        let pool = dispatcher(
            entries: [entry],
            providers: ["decider": FakeDecisionProvider.constant(providerID: "decider", pYes: 0.9, inputTokens: 10)],
            roles: gatekeeper(),
            budget: budget
        )
        _ = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        let projected = await budget.projected
        #expect(projected.count == 1)
        #expect((projected[0] ?? 0) > 0)
        let settled = await budget.settled
        #expect(settled.count == 1)
        #expect(abs((settled[0] ?? 0) - 0.01) < 1e-12)
    }

    @Test("Calls reserve a background scheduler slot and always release it")
    func scheduler() async {
        let scheduler = RecordingScheduler()
        let entries = [DecisionFixtures.decider("a", provider: "a"), DecisionFixtures.decider("b", provider: "b")]
        let pool = dispatcher(
            entries: entries,
            providers: [
                "a": FakeDecisionProvider.failing(providerID: "a", status: 503),
                "b": FakeDecisionProvider.constant(providerID: "b", pYes: 0.5),
            ],
            roles: gatekeeper(pin: "a", fallback: ["b"]),
            scheduler: scheduler
        )
        _ = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, context: DecisionCallContext(conversationID: UUID()))
        let reservations = await scheduler.reservations
        #expect(reservations.count == 2)
        #expect(reservations.allSatisfy { $0.priority == .background && $0.conversationID != nil })
        #expect(await scheduler.releases == 2)
    }

    @Test("Ranking prefers models catalogued for the role, then language fit, then cost")
    func ranking() async {
        let generic = DecisionFixtures.decider("generic", provider: "g", prices: [PriceComponent(unit: .inputToken, usd: 0.01, per: 1_000_000)])
        let catalogued = DecisionFixtures.decider("gate-tuned", provider: "c", roles: ["gatekeeper"],
                                                  prices: [PriceComponent(unit: .inputToken, usd: 5, per: 1_000_000)])
        let providers: [ProviderID: any DecisionProviding] = [
            "g": FakeDecisionProvider.constant(providerID: "g", pYes: 0.5),
            "c": FakeDecisionProvider.constant(providerID: "c", pYes: 0.5),
        ]
        let pool = dispatcher(entries: [generic, catalogued], providers: providers, roles: gatekeeper())
        #expect(await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper).receipt.resolved?.modelID == "gate-tuned")

        let languages = FeatureSupport(params: ["strong": .array([.string("en")]), "weak": .array([.string("ja")])])
        let english = DecisionFixtures.decider("en-decider", provider: "g", profile: DecisionProfiles.systemOne(languages: languages))
        let multilingual = DecisionFixtures.decider("multi", provider: "c", profile: DecisionProfiles.systemOne(
            languages: FeatureSupport(params: ["strong": .array([.string("en"), .string("ja")])])
        ), prices: [PriceComponent(unit: .inputToken, usd: 1, per: 1_000_000)])
        let languagePool = dispatcher(entries: [english, multilingual], providers: providers, roles: gatekeeper())
        let japanese = await languagePool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, context: DecisionCallContext(language: "ja"))
        #expect(japanese.receipt.resolved?.modelID == "multi")
        let cheapest = await languagePool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, context: DecisionCallContext(language: "en"))
        #expect(cheapest.receipt.resolved?.modelID == "en-decider")
    }

    @Test("Invalid requests and policies fail before any dispatch")
    func invalidInputs() async {
        let counter = CallCounter()
        let pool = dispatcher(
            entries: [DecisionFixtures.decider("d")],
            providers: ["decider": FakeDecisionProvider.constant(providerID: "decider", pYes: 0.9, counter: counter)],
            roles: gatekeeper()
        )
        let badRequest = await pool.decide(DecisionRequest(state: .string("s"), questions: []), role: .gatekeeper)
        guard case .invalidRequest = badRequest.error else { Issue.record("expected invalidRequest"); return }
        let badPolicy = DecisionPolicy(question: "safe", bands: ["d": .ranges(confirm: DecisionRange(0, 0.8), act: DecisionRange(0.5, 1))])
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: badPolicy)
        #expect(outcome.error == .invalidPolicy(.overlappingRanges(modelVersion: "d")))
        #expect(await counter.count == 0)
    }

    @Test("A role bound to another contract is rejected")
    func contractMismatch() async {
        let roles = RoleBindingResolver(settings: [.gatekeeper: RoleBinding(role: .gatekeeper, contract: .generate)])
        let pool = dispatcher(entries: [], providers: [:], roles: roles)
        #expect(await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper).error
            == .contractMismatch(role: .gatekeeper, contract: .generate))
    }

    @Test("Warm-up pre-connects the top candidate")
    func warm() async {
        let transport = MockDecisionTransport([.ok("{}")])
        let entry = DecisionFixtures.decider("d")
        let provider = HTTPDecisionProvider(
            manifest: DecisionFixtures.manifest("decider"), entries: [entry], transport: transport,
            retryExecutor: instantRetryExecutor(), credential: { _ in nil }
        )
        let pool = dispatcher(entries: [entry], providers: ["decider": provider], roles: gatekeeper())
        await pool.warm(role: .gatekeeper, request: DecisionFixtures.yesNoRequest())
        #expect(await transport.requests.first?.url?.path == "/v1/models")
    }

    @Test("End to end through the HTTP provider and SystemOne codec")
    func endToEndHTTP() async {
        let transport = MockDecisionTransport([
            .ok("{\"model\": \"d-2026-09\", \"answers\": {\"safe\": {\"type\": \"noul\", \"noul\": 0.42}}, \"usage\": {\"input_tokens\": 50}}"),
        ])
        let entry = DecisionFixtures.decider("d-2026-09")
        let provider = HTTPDecisionProvider(
            manifest: DecisionFixtures.manifest("decider"), entries: [entry], transport: transport,
            retryExecutor: instantRetryExecutor(), credential: { _ in "k" }
        )
        let pool = dispatcher(entries: [entry], providers: ["decider": provider], roles: gatekeeper())
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: DecisionFixtures.gatePolicy(versions: ["d-2026-09"]))
        #expect(outcome.verdict == .refuse)
        #expect(outcome.receipt.decision?.reason == .band(.refuse))
    }
}

@Suite("Decision response cache")
struct DecisionResponseCacheTests {
    @Test("Evicts the oldest entry past capacity")
    func eviction() async {
        let cache = DecisionResponseCache(capacity: 2)
        let result = DecisionResult(modelVersion: "v", calibrated: true, guarantee: .calibratedDistribution, answers: [:])
        for id in ["a", "b", "c"] {
            await cache.store(result, modelVersion: "v", request: DecisionFixtures.yesNoRequest([id]))
        }
        #expect(await cache.count == 2)
        #expect(await cache.lookup(modelVersion: "v", request: DecisionFixtures.yesNoRequest(["a"])) == nil)
        #expect(await cache.lookup(modelVersion: "v", request: DecisionFixtures.yesNoRequest(["c"])) != nil)
        #expect(await cache.lookup(modelVersion: "other", request: DecisionFixtures.yesNoRequest(["c"])) == nil)
    }
}
