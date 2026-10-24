import EasyJSON
import Foundation
import Logging
import Synchronization
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// A router decider that picks `choice` with probability `p`, spreading the rest over the other options.
private func routerProvider(choice: String, p: Double, counter: CallCounter = CallCounter()) -> FakeDecisionProvider {
    ConsumerFixtures.provider({ request in
        guard case .choice(_, let options)? = request.questions.first?.question else { return [:] }
        let others = options.filter { $0.id != choice }
        var probabilities = Dictionary(uniqueKeysWithValues: others.map { ($0.id, (1 - p) / Double(max(1, others.count))) })
        probabilities[choice] = p
        return [ModelPoolRouterConfiguration.questionID: .choice(choice: choice, probabilities: probabilities)]
    }, counter: counter)
}

private func routerConfiguration() -> ModelPoolRouterConfiguration {
    ModelPoolRouterConfiguration(policy: ConsumerFixtures.highActs(ModelPoolRouterConfiguration.questionID))
}

private func chat(_ slug: String) -> ModelRegistryEntry {
    var entry = DecisionFixtures.chatModel(slug)
    entry.capabilities = [.completion, .tools]
    return entry
}

private let small = Model(
    id: UUID(), protocol: .openAIAPI, modelName: "small-chat", serverURL: URL(string: "http://localhost:1")!,
    capabilities: [.completion, .tools], modelProtocol: .openAIAPI
)

private actor QueryLog {
    private(set) var queries: [ModelQuery] = []
    func record(_ query: ModelQuery) { queries.append(query) }
}

@Suite("Model Pool router")
struct ModelPoolRouterTests {
    @Test("Only a calibrated act on an offered candidate counts; fewer than two candidates make no call")
    func choose() async {
        let counter = CallCounter()
        let dispatcher = ConsumerFixtures.dispatcher(role: .router, provider: routerProvider(choice: "b", p: 0.95, counter: counter))
        let router = ModelPoolRouter(configuration: routerConfiguration())
        let candidates = [ModelPoolRouterCandidate(id: "a", description: "A"), ModelPoolRouterCandidate(id: "b", description: "B")]
        let choice = await router.choose(request: "hi", current: "a", candidates: candidates, dispatcher: dispatcher, context: DecisionCallContext())
        #expect(choice?.id == "b")
        #expect(choice?.probability(of: "b") == 0.95)
        #expect(await router.choose(request: "hi", current: "a", candidates: [candidates[0]], dispatcher: dispatcher, context: DecisionCallContext()) == nil)
        #expect(await counter.count == 1)

        let unsure = ConsumerFixtures.dispatcher(role: .router, provider: routerProvider(choice: "b", p: 0.6))
        #expect(await router.choose(request: "hi", current: "a", candidates: candidates, dispatcher: unsure, context: DecisionCallContext()) == nil)
    }

    @Test("Candidate descriptions name family, context, and capabilities")
    func describe() {
        let text = ModelPoolRouterCandidate.describing(DecisionFixtures.chatModel("big-chat"), id: "big-chat").description
        #expect(text.contains("family chat"))
        #expect(text.contains("128k context"))
        #expect(text.contains("tools"))
    }
}

@Suite("Model Pool turn selector")
struct ModelPoolTurnSelectorTests {
    private func selector(
        choice: String,
        p: Double,
        ranked: [ModelRegistryEntry] = [chat("small-chat"), chat("big-chat")],
        margin: Double = 0.25,
        receipts: InMemoryRouteReceiptRecorder = InMemoryRouteReceiptRecorder(),
        queries: QueryLog = QueryLog(),
        routerBound: Bool = true
    ) -> ModelPoolTurnSelector {
        ModelPoolTurnSelector(
            candidates: { query in await queries.record(query); return ranked },
            dispatcher: ConsumerFixtures.dispatcher(role: .router, provider: routerProvider(choice: choice, p: p), bound: routerBound),
            configuration: ModelPoolTurnSelectorConfiguration(router: routerConfiguration(), warmCacheMargin: margin),
            receipts: receipts
        )
    }

    private func request(history: Bool) -> TurnModelRequest {
        TurnModelRequest(conversationID: UUID(), currentModel: small, request: "prove this theorem", hasHistory: history)
    }

    @Test("A clear router pick switches the turn's model and emits a generate receipt")
    func switches() async {
        let receipts = InMemoryRouteReceiptRecorder()
        let model = await selector(choice: "big-chat", p: 0.95, receipts: receipts).selectModel(for: request(history: false))
        #expect(model.modelName == "big-chat")
        let receipt = await receipts.receipts.first
        #expect(receipt?.contract == .generate)
        #expect(receipt?.role == .main)
        #expect(receipt?.routerPick == "big-chat")
        #expect(receipt?.resolved?.modelID == "big-chat")
        #expect(receipt?.summary.contains("routed") == true)
    }

    @Test("A warm cache keeps the current model unless the router clears the margin")
    func warmCache() async {
        let receipts = InMemoryRouteReceiptRecorder()
        // The router acts on big-chat (p = 0.9, small-chat 0.1): a lead of 0.8, under a 0.95 margin.
        let kept = await selector(choice: "big-chat", p: 0.9, margin: 0.95, receipts: receipts).selectModel(for: request(history: true))
        #expect(kept.modelName == "small-chat")
        #expect(await receipts.receipts.first?.rankedOut.first?.reason.contains("warm-cache margin") == true)
        let switched = await selector(choice: "big-chat", p: 0.95, margin: 0.25).selectModel(for: request(history: true))
        #expect(switched.modelName == "big-chat")
    }

    @Test("No clear pick, an unbound router, or a lone candidate keeps the conversation's model")
    func keeps() async {
        #expect(await selector(choice: "big-chat", p: 0.6).selectModel(for: request(history: false)).modelName == "small-chat")
        #expect(await selector(choice: "small-chat", p: 0.99).selectModel(for: request(history: false)).modelName == "small-chat")
        #expect(await selector(choice: "big-chat", p: 0.99, routerBound: false).selectModel(for: request(history: false)).modelName == "small-chat")
        #expect(await selector(choice: "big-chat", p: 0.99, ranked: [chat("small-chat")]).selectModel(for: request(history: false)).modelName == "small-chat")
    }

    @Test("The Pool applies the hard filter: candidates must keep the current model's tools and vision")
    func hardFilter() async {
        let queries = QueryLog()
        _ = await selector(choice: "big-chat", p: 0.95, queries: queries).selectModel(for: request(history: false))
        #expect(await queries.queries.first?.mustIncludeCapabilities == [.tools])
    }
}

@Suite("Decide rank stage router")
struct DecideRankStageRouterTests {
    private func dispatcher(
        pickFor routerChoice: String,
        pin: String? = nil,
        entries: [ModelRegistryEntry],
        counters: [ProviderID: CallCounter],
        routerCounter: CallCounter
    ) -> ModelPoolDecisionDispatcher {
        var providers: [ProviderID: any DecisionProviding] = ["router-p": routerProvider(choice: routerChoice, p: 0.95, counter: routerCounter)]
        for (id, counter) in counters {
            providers[id] = FakeDecisionProvider.constant(providerID: id, pYes: 0.9, counter: counter)
        }
        return ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource(entries + [DecisionFixtures.decider(
                "router-1", provider: "router-p", profile: DecisionProfiles.systemOne(questionKinds: [.choice])
            )]),
            providers: StaticDecisionProviderResolver(providers),
            roles: RoleBindingResolver(settings: [
                .gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide, pin: pin),
                .router: RoleBinding(role: .router, contract: .decide, pin: "router-1"),
            ]),
            // The router fixture answers as ConsumerFixtures.version, so its bands are keyed by that version.
            router: routerConfiguration(),
            logger: DecisionLogCapture().logger
        )
    }

    @Test("The router moves its pick to the front of an open ranking and is recorded on the receipt")
    func reorders() async {
        let a = CallCounter(), b = CallCounter(), routerCounter = CallCounter()
        let pool = dispatcher(
            pickFor: "pb/b",
            entries: [DecisionFixtures.decider("a", provider: "pa", roles: ["gatekeeper"]), DecisionFixtures.decider("b", provider: "pb")],
            counters: ["pa": a, "pb": b],
            routerCounter: routerCounter
        )
        let outcome = await pool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(outcome.result?.modelVersion == "b")
        #expect(outcome.receipt.routerPick == "pb/b")
        #expect(await a.count == 0)
        #expect(await routerCounter.count == 1)
    }

    @Test("Pinned roles, the router's own calls, and single candidates skip the router")
    func skips() async {
        let a = CallCounter(), b = CallCounter(), routerCounter = CallCounter()
        let entries = [DecisionFixtures.decider("a", provider: "pa"), DecisionFixtures.decider("b", provider: "pb")]
        let pinned = dispatcher(pickFor: "pb/b", pin: "a", entries: entries, counters: ["pa": a, "pb": b], routerCounter: routerCounter)
        #expect(await pinned.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper).result?.modelVersion == "a")
        #expect(await routerCounter.count == 0)

        let single = dispatcher(
            pickFor: "pb/b", entries: [entries[0]], counters: ["pa": a], routerCounter: routerCounter
        )
        _ = await single.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(await routerCounter.count == 0)

        // The router's own call goes through the same dispatcher without consulting itself.
        let open = dispatcher(pickFor: "pb/b", entries: entries, counters: ["pa": a, "pb": b], routerCounter: routerCounter)
        _ = await open.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(await routerCounter.count == 1)
    }

    @Test("The router sees the role and questions, never the state")
    func summary() {
        let text = ModelPoolDecisionDispatcher.routerSummary(of: DecisionFixtures.yesNoRequest(state: .string("secret state")), role: .gatekeeper)
        #expect(text.contains("decide role gatekeeper"))
        #expect(text.contains("yes-no: Is the action safe?"))
        #expect(!text.contains("secret state"))
    }
}

// MARK: - End to end

/// Records which model each base LLM was built for, then returns the scripted LLM.
private final class ModelRecordingLLMFactory: ModelLLMFactoring, Sendable {
    let llm: any LLMProtocol
    let names: ModelNameLog

    init(llm: any LLMProtocol, names: ModelNameLog) {
        self.llm = llm
        self.names = names
    }

    func makeBaseLLM(
        model: Model,
        providerBindings: [ProviderBinding]?,
        conversationID: UUID?,
        ownerAccountID: UUID?,
        systemPrompt: SystemPrompt,
        logger: Logger?,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?
    ) -> any LLMProtocol {
        names.append(model.modelName)
        return llm
    }
}

private final class ModelNameLog: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ name: String) { storage.withLock { $0.append(name) } }
    var all: [String] { storage.withLock { $0 } }
}

@Suite("Model Pool routing end to end")
struct ModelPoolRoutingIntegrationTests {
    @Test("The runtime asks the Pool; a routed turn builds its orchestrator for the chosen model")
    func routedTurn() async throws {
        let current = ModelRegistryEntry.from(model: section6Model())
        let big = chat("big-chat")
        let names = ModelNameLog()
        let selector = ModelPoolTurnSelector(
            candidates: { _ in [current, big] },
            dispatcher: ConsumerFixtures.dispatcher(role: .router, provider: routerProvider(choice: "big-chat", p: 0.95)),
            configuration: ModelPoolTurnSelectorConfiguration(router: routerConfiguration())
        )
        let manager = HarnessRuntimeSession(
            container: try section6Container(),
            llmFactory: ModelRecordingLLMFactory(
                llm: ScriptedToolThenAnswerLLM(toolName: "none", toolCallID: "c1", finalAssistantText: "done"),
                names: names
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence(),
            turnModelSelector: selector
        )
        try await manager.createConversation(with: section6Model(), userSystemPrompt: "router")
        let conversationID = try #require(await manager.currentConversationID)
        let response = try await manager.sendMessageAndStreamResponse("prove this theorem", images: [], conversationID: conversationID)
        await awaitStreamingRunSettled(manager, response: response, timeoutMS: 15_000)
        #expect(names.all.contains("big-chat"))
        let stored = try #require(await manager.modelConversation(id: conversationID))
        #expect(stored.model.modelName == "section6-model")
    }
}
