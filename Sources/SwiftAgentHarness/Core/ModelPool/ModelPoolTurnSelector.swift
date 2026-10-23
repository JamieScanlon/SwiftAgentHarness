import Foundation
import Logging

/// What the Agent Runtime asks the Pool for at the start of a turn: the `main` model for this conversation and
/// request. The runtime never sees candidates or the router; selecting the model is the Pool's job.
public struct TurnModelRequest: Sendable {
    public var conversationID: UUID
    public var runID: UUID?
    /// The conversation's model, which the turn uses unless the Pool picks another.
    public var currentModel: Model
    /// The latest user request.
    public var request: String
    /// Whether the conversation already has turns on `currentModel`, so its prompt cache is likely warm.
    public var hasHistory: Bool
    public var rolePatches: RoleBindingPatches

    public init(
        conversationID: UUID,
        runID: UUID? = nil,
        currentModel: Model,
        request: String,
        hasHistory: Bool,
        rolePatches: RoleBindingPatches = .none
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.currentModel = currentModel
        self.request = request
        self.hasHistory = hasHistory
        self.rolePatches = rolePatches
    }
}

public struct ModelPoolTurnSelectorConfiguration: Sendable {
    public var router: ModelPoolRouterConfiguration
    /// When the current model's cache is warm, the router's pick must beat the current model's probability by at
    /// least this much to switch. Leaving a warm model throws away its cached prefix (spec: fold in cache warmth).
    public var warmCacheMargin: Double

    public init(router: ModelPoolRouterConfiguration, warmCacheMargin: Double = 0.25) {
        self.router = router
        self.warmCacheMargin = max(0, warmCacheMargin)
    }
}

/// The Pool's per-turn selection for the `main` role: hard-filter candidates to the current model's tool and vision
/// capabilities, take the Pool's static ranking (capabilities, cost, latency), let the router re-rank, keep a warm
/// model unless the router clearly prefers another, and emit a route receipt. Without a router configured the turn
/// always uses the conversation's model.
public actor ModelPoolTurnSelector {
    public typealias CandidateProvider = @Sendable (ModelQuery) async -> [ModelRegistryEntry]

    private let candidates: CandidateProvider
    private let dispatcher: any DecisionDispatching
    public nonisolated let configuration: ModelPoolTurnSelectorConfiguration
    private let receipts: any RouteReceiptRecording
    private let logger: Logger

    /// - Parameter candidates: the Pool's ranked `generate` candidates for a query (for example
    ///   `ModelManager.resolveAll(.query(_:))`).
    public init(
        candidates: @escaping CandidateProvider,
        dispatcher: any DecisionDispatching,
        configuration: ModelPoolTurnSelectorConfiguration,
        receipts: any RouteReceiptRecording = NoOpRouteReceiptRecorder(),
        logger: Logger? = nil
    ) {
        self.candidates = candidates
        self.dispatcher = dispatcher
        self.configuration = configuration
        self.receipts = receipts
        self.logger = logger ?? Logger(label: "SwiftAgentHarness.ModelPool.TurnSelector")
    }

    /// Selects from the host's `ModelManager`.
    public init(
        modelManager: ModelManager,
        dispatcher: any DecisionDispatching,
        configuration: ModelPoolTurnSelectorConfiguration,
        receipts: any RouteReceiptRecording = NoOpRouteReceiptRecorder(),
        logger: Logger? = nil
    ) {
        self.init(
            candidates: { query in (try? await modelManager.resolveAll(.query(query))) ?? [] },
            dispatcher: dispatcher,
            configuration: configuration,
            receipts: receipts,
            logger: logger
        )
    }

    /// The model for this turn. Falls back to the conversation's model whenever there is no clear reason to switch.
    public func selectModel(for request: TurnModelRequest) async -> Model {
        let start = ContinuousClock.now
        let current = request.currentModel
        var receipt = RouteReceipt(
            conversationID: request.conversationID,
            runID: request.runID,
            role: .main,
            contract: .generate,
            requested: ModelRole.main.rawValue
        )

        let required = Set(current.capabilities).intersection([.tools, .vision])
        let ranked = await candidates(ModelQuery(mustIncludeCapabilities: required))
        var seen = Set<String>([current.modelName])
        let others = ranked.filter { $0.supports(.generate) && seen.insert($0.slug).inserted }
        let currentEntry = ranked.first { $0.slug == current.modelName } ?? ModelRegistryEntry.from(model: current)
        let pool = [currentEntry] + others

        var chosen = currentEntry
        if pool.count >= 2 {
            let router = ModelPoolRouter(configuration: configuration.router)
            let choice = await router.choose(
                request: request.request,
                current: current.modelName,
                candidates: pool.map { ModelPoolRouterCandidate.describing($0, id: $0.slug) },
                dispatcher: dispatcher,
                context: DecisionCallContext(
                    conversationID: request.conversationID, runID: request.runID, rolePatches: request.rolePatches
                )
            )
            if let choice, choice.id != current.modelName, let pick = pool.first(where: { $0.slug == choice.id }) {
                let lead = choice.probability(of: choice.id) - choice.probability(of: current.modelName)
                if request.hasHistory && lead < configuration.warmCacheMargin {
                    receipt.rankedOut.append(.init(
                        modelID: pick.slug,
                        reason: String(format: "router preferred it by %.2f, below the warm-cache margin %.2f", lead, configuration.warmCacheMargin)
                    ))
                } else {
                    chosen = pick
                    receipt.routerPick = pick.slug
                    logger.info("pool routed turn from \(current.modelName) to \(pick.slug)")
                }
            }
        }

        let binding = chosen.primaryBinding
        receipt.resolved = RouteReceipt.Resolved(
            modelID: chosen.slug,
            versionServed: nil,
            bindingID: binding.map { "\($0.providerId)/\($0.endpointModelId)" } ?? chosen.slug,
            surface: chosen.synthesizedGenerateProfile.surface
        )
        receipt.latencyMs = ModelPoolDecisionDispatcher.milliseconds(ContinuousClock.now - start)
        await receipts.record(receipt)
        return chosen.slug == current.modelName ? current : chosen.toModel()
    }
}
