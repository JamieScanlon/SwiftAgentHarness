import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Model contracts and profiles")
struct ModelContractTests {
    @Test("Output guarantee ladder is ranked free-text < json-mode < schema-strict < logprobs < calibrated")
    func guaranteeLadder() {
        let ladder: [OutputGuarantee] = [.freeText, .jsonMode, .schemaStrict, .logprobs, .calibratedDistribution]
        #expect(ladder == ladder.sorted())
        #expect(OutputGuarantee.allCases.sorted() == ladder)
        #expect(OutputGuarantee.logprobs < .calibratedDistribution)
        #expect(max(OutputGuarantee.schemaStrict, .jsonMode) == .schemaStrict)
    }

    @Test("Eight contracts with stable raw values")
    func contracts() {
        #expect(ModelContract.allCases.map(\.rawValue) == [
            "generate", "decide", "embed", "rerank", "render", "transcribe", "session", "parse",
        ])
    }

    @Test("FeatureSupport equality ignores param key order and compares values")
    func featureSupportEquality() {
        let a = FeatureSupport(version: "v1", params: ["a": .integer(1), "b": .string("x")])
        let b = FeatureSupport(version: "v1", params: ["b": .string("x"), "a": .integer(1)])
        let c = FeatureSupport(version: "v1", params: ["a": .integer(2), "b": .string("x")])
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test("FeatureSupport typed param accessors")
    func featureParams() {
        let feature = FeatureSupport(params: [
            "encoding": .string("assets"),
            "kinds": .array([.string("yes-no"), .string("box")]),
            "edgePx": .array([.integer(280), .integer(1568)]),
            "count": .double(3),
        ])
        #expect(feature.stringParam("encoding") == "assets")
        #expect(feature.stringArrayParam("kinds") == ["yes-no", "box"])
        #expect(feature.intPairParam("edgePx")! == (280, 1568))
        #expect(feature.intParam("count") == 3)
        #expect(feature.stringParam("missing") == nil)
    }

    @Test("Limits narrow to the tighter value and intersect score levels")
    func limitsNarrow() {
        let model = ContractLimits(contextTokens: 65_536, maxItemsPerCall: nil, maxOptions: 255, scoreLevels: 2...10)
        let binding = ContractLimits(contextTokens: 32_000, maxItemsPerCall: 64, scoreLevels: 3...12)
        let merged = model.narrowed(by: binding)
        #expect(merged.contextTokens == 32_000)
        #expect(merged.maxItemsPerCall == 64)
        #expect(merged.maxOptions == 255)
        #expect(merged.scoreLevels == 3...10)
    }

    @Test("A binding override can narrow a profile but never widen it")
    func profileNarrowing() {
        let model = DecisionProfiles.systemOne(
            images: FeatureSupport(params: ["encoding": .string("assets")]),
            limits: ContractLimits(contextTokens: 65_536, maxOptions: 255, scoreLevels: 2...10)
        )
        var binding = model
        binding.surface = "systemone-edge"
        binding.guarantee = .logprobs
        binding.limits = ContractLimits(maxItemsPerCall: 64)
        binding.input = [.text]
        binding.features[DecisionFeatureKey.images] = FeatureSupport(supported: false)
        binding.features["only-on-binding"] = FeatureSupport()

        let effective = model.narrowed(by: binding)
        #expect(effective.surface == "systemone-edge")
        #expect(effective.guarantee == .logprobs)
        #expect(effective.limits.maxItemsPerCall == 64)
        #expect(effective.limits.contextTokens == 65_536)
        #expect(effective.input == [.text])
        #expect(effective.feature(DecisionFeatureKey.images) == nil)
        #expect(effective.features["only-on-binding"] == nil)

        var wider = model
        wider.guarantee = .calibratedDistribution
        wider.interaction = [.unary, .batch(discount: 0.5)]
        let notWidened = DecisionProfiles.systemOne(limits: ContractLimits()).narrowed(by: wider)
        #expect(notWidened.interaction.map(\.kind) == [.unary])
    }

    @Test("Narrowing a profile by a different contract is a no-op")
    func narrowingOtherContract() {
        let decide = DecisionProfiles.systemOne()
        let generate = DecisionFixtures.chatModel("m").synthesizedGenerateProfile
        #expect(decide.narrowed(by: generate) == decide)
    }

    @Test("Profiles round-trip through Codable")
    func profileCodable() throws {
        let profile = DecisionProfiles.openAIDecisions()
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ContractProfile.self, from: data)
        #expect(decoded == profile)
    }
}

@Suite("Registry entry contracts")
struct ModelRegistryEntryContractsTests {
    @Test("Legacy chat rows synthesize one generate profile from capabilities and request features")
    func legacySynthesis() throws {
        let entry = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion, .tools, .vision, .thinking],
            requestFeatures: ModelRequestFeatures(
                streaming: true, responseFormats: [.text, .jsonSchema], parallelToolCalls: .uncapped, reasoningEfforts: []
            ),
            maxContextLength: 200_000,
            maxOutputTokens: 8_192,
            providers: [ProviderBinding(
                providerId: "anthropic", modelProtocol: .anthropic, endpointModelId: "claude",
                serverURL: URL(string: "https://api.anthropic.com")!
            )]
        )
        #expect(entry.contractProfiles.count == 1)
        let generate = try #require(entry.profile(for: .generate))
        #expect(generate.surface == .anthropicMessages)
        #expect(generate.input.contains(.image))
        #expect(generate.output.contains(.toolCalls))
        #expect(generate.supportsInteraction(.stream))
        #expect(generate.guarantee == .schemaStrict)
        #expect(generate.limits.contextTokens == 200_000)
        #expect(generate.limits.maxOutputTokens == 8_192)
        #expect(generate.feature("tools") != nil)
        #expect(generate.feature("reasoning")?.stringParam("mode") == "optional")
        #expect(!entry.supports(.decide))
    }

    @Test("Explicit decide-only rows do not support generate")
    func decideOnly() {
        let entry = DecisionFixtures.decider("decider-2026-09")
        #expect(entry.supports(.decide))
        #expect(!entry.supports(.generate))
        #expect(entry.profile(for: .decide)?.guarantee == .calibratedDistribution)
    }

    @Test("Binding overrides narrow the served profile")
    func bindingOverride() {
        var entry = DecisionFixtures.decider("decider-2026-09")
        var override = DecisionProfiles.systemOne(limits: ContractLimits(maxItemsPerCall: 64))
        override.surface = "edge"
        entry.providers[0].contractOverrides = [override]
        let served = entry.profile(for: .decide, binding: entry.providers[0])
        #expect(served?.surface == "edge")
        #expect(served?.limits.maxItemsPerCall == 64)
        #expect(served?.limits.contextTokens == 65_536)
    }

    @Test("Effective prices prefer binding, then entry vector, then the legacy budget")
    func effectivePrices() {
        var entry = DecisionFixtures.decider("d", prices: [])
        #expect(entry.effectivePrices(binding: entry.providers[0]).isEmpty)
        entry.cost = ModelCostBudget(inputPer1MUSD: 0.2, outputPer1MUSD: 0, cachedInputPer1MUSD: nil)
        #expect(entry.effectivePrices(binding: entry.providers[0]).component(for: .inputToken)?.usd == 0.2)
        entry.prices = [PriceComponent(unit: .inputToken, usd: 0.1, per: 1_000_000)]
        #expect(entry.effectivePrices(binding: entry.providers[0]).component(for: .inputToken)?.usd == 0.1)
        entry.providers[0].prices = [PriceComponent(unit: .request, usd: 0.001, per: 1)]
        #expect(entry.effectivePrices(binding: entry.providers[0]).first?.unit == .request)
    }

    @Test("Legacy ModelQuery never matches decide-only or retired entries")
    func legacyQueryIsGenerateOnly() {
        let decider = DecisionFixtures.decider("decider")
        var chat = DecisionFixtures.chatModel("chat")
        let query = ModelQuery()
        #expect(!query.matches(decider))
        #expect(query.matches(chat))
        chat.lifecycle = ModelLifecycle(status: .retired)
        #expect(!query.matches(chat))
        #expect(ModelQuery.rank(entries: [decider, chat], query: query).isEmpty)
    }

    @Test("Legacy ModelQuery compiles to a generate ContractQuery")
    func legacyQueryCompiles() {
        let query = ModelQuery(
            mustIncludeCapabilities: [.tools, .vision],
            minimumContextWindow: 32_000,
            preferredUseClass: "memory-recall",
            preferredFamily: "claude",
            excludeFamilies: ["x"],
            requireStreaming: true,
            requireResponseFormats: [.jsonSchema]
        ).contractQuery
        #expect(query.contract == .generate)
        #expect(query.interaction == .stream)
        #expect(query.input == [.image])
        #expect(query.output == [.toolCalls])
        #expect(query.minGuarantee == .schemaStrict)
        #expect(query.limits.contextTokens == 32_000)
        #expect(query.prefer.useClass == "memory-recall")
        #expect(query.prefer.family == "claude")
        #expect(query.excludeFamilies == ["x"])
        #expect(query.rejection(for: DecisionFixtures.chatModel("m").synthesizedGenerateProfile) == "input image unsupported")
    }

    @Test("Registry merge unions contracts so a model served by chat and decide endpoints keeps both")
    func mergeUnionsContracts() throws {
        let key = "vendor/model-1"
        var chat = DecisionFixtures.chatModel("model-1")
        chat.canonicalModelKey = key
        var decider = DecisionFixtures.decider("model-1", provider: "decider", compatGroup: "g", roles: ["gatekeeper"])
        decider.canonicalModelKey = key
        let merged = LogicalModelRegistryMerger.merge(
            entries: [chat, decider],
            providerPreference: .specDefaults
        )
        #expect(merged.count == 1)
        let entry = try #require(merged.values.first)
        #expect(entry.supports(.generate))
        #expect(entry.supports(.decide))
        #expect(entry.compatGroup == "g")
        #expect(entry.roles == ["gatekeeper"])
        #expect(entry.providers.count == 2)
    }

    @Test("Merging legacy-only rows keeps contracts empty")
    func mergeLegacyOnly() {
        var a = DecisionFixtures.chatModel("m")
        a.canonicalModelKey = "k"
        var b = DecisionFixtures.chatModel("m")
        b.canonicalModelKey = "k"
        b.providers[0].providerId = "other"
        let merged = LogicalModelRegistryMerger.merge(entries: [a, b], providerPreference: .specDefaults)
        #expect(merged.values.first?.contracts.isEmpty == true)
    }
}

@Suite("Contract query hard filter")
struct ContractQueryTests {
    let profile = DecisionProfiles.systemOne(
        images: FeatureSupport(version: "img-2026", params: ["encoding": .string("assets")]),
        limits: ContractLimits(contextTokens: 65_536, maxOptions: 10, scoreLevels: 2...5)
    )

    @Test("Passes when every hard need is met")
    func passes() {
        let query = ContractQuery(
            contract: .decide, interaction: .unary, input: [.image], output: [.distribution],
            minGuarantee: .calibratedDistribution, features: [DecisionFeatureKey.images: RequiredFeature(version: "img-2026")],
            limits: ContractLimits(contextTokens: 10_000, maxOptions: 5, scoreLevels: 2...4)
        )
        #expect(query.rejection(for: profile) == nil)
    }

    @Test("Each facet produces its own rejection reason")
    func rejections() {
        #expect(ContractQuery(contract: .embed).rejection(for: profile)?.contains("contract") == true)
        #expect(ContractQuery(contract: .decide, interaction: .stream).rejection(for: profile) == "no stream interaction")
        #expect(ContractQuery(contract: .decide, input: [.audio]).rejection(for: profile) == "input audio unsupported")
        #expect(ContractQuery(contract: .decide, output: [.vector]).rejection(for: profile) == "output vector unsupported")
        var weak = profile
        weak.guarantee = .logprobs
        #expect(ContractQuery(contract: .decide, minGuarantee: .calibratedDistribution).rejection(for: weak)?.contains("guarantee") == true)
        #expect(ContractQuery(contract: .decide, features: ["longContext": RequiredFeature()]).rejection(for: profile) == "feature longContext unsupported")
        #expect(ContractQuery(contract: .decide, features: [DecisionFeatureKey.images: RequiredFeature(version: "old")]).rejection(for: profile)?.contains("version") == true)
        #expect(ContractQuery(contract: .decide, limits: ContractLimits(contextTokens: 100_000)).rejection(for: profile)?.contains("context") == true)
        #expect(ContractQuery(contract: .decide, limits: ContractLimits(maxOptions: 20)).rejection(for: profile)?.contains("maxOptions") == true)
        #expect(ContractQuery(contract: .decide, limits: ContractLimits(scoreLevels: 2...8)).rejection(for: profile)?.contains("score") == true)
    }
}

@Suite("Price vectors and decide cost")
struct PriceVectorTests {
    @Test("Legacy per-1M budgets become token price components")
    func legacy() {
        let vector = PriceVector.fromLegacy(ModelCostBudget(inputPer1MUSD: 3, outputPer1MUSD: 15, cachedInputPer1MUSD: 0.3))
        #expect(vector.component(for: .inputToken)?.usdPerUnit == 3.0 / 1_000_000.0)
        #expect(vector.component(for: .outputToken)?.usd == 15)
        #expect(vector.component(for: .cacheReadToken)?.usd == 0.3)
        #expect(PriceVector.fromLegacy(nil).isEmpty)
    }

    @Test("Component selection honors tier and the most specific long-context threshold")
    func componentSelection() {
        let vector: PriceVector = [
            PriceComponent(unit: .inputToken, usd: 1, per: 1_000_000),
            PriceComponent(unit: .inputToken, usd: 2, per: 1_000_000, when: PriceCondition(contextAbove: 200_000)),
            PriceComponent(unit: .inputToken, usd: 0.5, per: 1_000_000, when: PriceCondition(tier: .batch)),
        ]
        #expect(vector.component(for: .inputToken, contextTokens: 1_000)?.usd == 1)
        #expect(vector.component(for: .inputToken, contextTokens: 300_000)?.usd == 2)
        #expect(vector.component(for: .inputToken, tier: .batch)?.usd == 0.5)
        #expect(vector.component(for: .image) == nil)
    }

    @Test("Decide projects and settles on input tokens; unknown is never zero")
    func decideCost() {
        let prices: PriceVector = [
            PriceComponent(unit: .inputToken, usd: 0.04, per: 1_000_000),
            PriceComponent(unit: .outputToken, usd: 99, per: 1),
        ]
        let projected = DecisionCostEstimator.project(prices: prices, estimatedInputTokens: 1_000)
        #expect(abs(projected.usd! - 0.00004) < 1e-12)
        #expect(abs(DecisionCostEstimator.settle(prices: prices, inputTokens: 1_000)! - 0.00004) < 1e-12)
        #expect(DecisionCostEstimator.project(prices: [], estimatedInputTokens: 10).usd == nil)
        #expect(DecisionCostEstimator.settle(prices: [], inputTokens: 10) == nil)
        let perRequest: PriceVector = [PriceComponent(unit: .request, usd: 0.002, per: 1)]
        #expect(DecisionCostEstimator.settle(prices: perRequest, inputTokens: nil) == 0.002)
        #expect(DecisionCostEstimator.estimateInputTokens(characterCount: 9) == 3)
    }
}
