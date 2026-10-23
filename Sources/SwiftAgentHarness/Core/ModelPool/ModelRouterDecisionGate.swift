import Foundation
import Logging

/// Configuration for the `router` role: pick the turn's model among ranked candidates.
public struct ModelRouterConfiguration: Sendable {
    public static let questionID = "model"

    /// Bands on the chosen candidate's probability. The router switches models only on `act`.
    public var policy: DecisionPolicy
    public var role: ModelRole
    /// Candidates offered to the router, best-ranked first.
    public var maxCandidates: Int
    public var maxRequestCharacters: Int
    public var timeBudget: Duration

    public init(
        policy: DecisionPolicy,
        role: ModelRole = .router,
        maxCandidates: Int = 8,
        maxRequestCharacters: Int = 2_000,
        timeBudget: Duration = .seconds(1)
    ) {
        self.policy = policy
        self.role = role
        self.maxCandidates = min(255, max(2, maxCandidates))
        self.maxRequestCharacters = max(64, maxRequestCharacters)
        self.timeBudget = timeBudget
    }
}

/// Chooses the model for one turn. Candidates come from the Pool's ranked list, so hard constraints (capabilities,
/// locality, lifecycle) are already applied; the router only ranks among them. Anything short of a calibrated `act`
/// keeps the conversation's model (spec failure default: role default). Switching models costs the warm prompt
/// cache, so set the act band accordingly.
public actor ModelRouterDecisionGate {
    private let dispatcher: any DecisionDispatching
    public nonisolated let configuration: ModelRouterConfiguration
    private let logger: Logger

    public init(dispatcher: any DecisionDispatching, configuration: ModelRouterConfiguration, logger: Logger? = nil) {
        self.dispatcher = dispatcher
        self.configuration = configuration
        self.logger = logger ?? Logger(label: "SwiftAgentHarness.ModelPool.Router")
    }

    /// The candidate to use instead of `currentSlug`, or `nil` to keep the current model.
    public func route(
        userRequest: String,
        currentSlug: String,
        candidates: [ModelRegistryEntry],
        conversationID: UUID?,
        runID: UUID? = nil,
        rolePatches: RoleBindingPatches = .none
    ) async -> ModelRegistryEntry? {
        var seen = Set<String>()
        let offered = candidates.filter { $0.supports(.generate) && seen.insert($0.slug).inserted }
            .prefix(configuration.maxCandidates)
        guard offered.count >= 2, !userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let outcome = await dispatcher.decide(
            Self.makeRequest(userRequest: userRequest, currentSlug: currentSlug, candidates: Array(offered),
                             maxCharacters: configuration.maxRequestCharacters),
            role: configuration.role,
            policy: configuration.policy,
            context: DecisionCallContext(
                conversationID: conversationID, runID: runID, timeBudget: configuration.timeBudget, rolePatches: rolePatches
            )
        )
        guard case .verdict(.act, let accepted) = DecisionConsumerResult(outcome),
              case .choice(let choice, _)? = accepted.result?.answers[ModelRouterConfiguration.questionID],
              choice != currentSlug,
              let chosen = offered.first(where: { $0.slug == choice })
        else { return nil }
        logger.info("router moved turn from \(currentSlug) to \(chosen.slug): \(outcome.receipt.summary)")
        return chosen
    }

    static func makeRequest(
        userRequest: String,
        currentSlug: String,
        candidates: [ModelRegistryEntry],
        maxCharacters: Int
    ) -> DecisionRequest {
        DecisionRequest(
            state: .object([
                "user_request": .string(DecisionConsumerText.bounded(userRequest, maxCharacters: maxCharacters)),
                "current_model": .string(currentSlug),
            ]),
            questions: [
                DecisionQuestionItem(ModelRouterConfiguration.questionID, .choice(
                    instructions: .string("Which model should handle this request?"),
                    options: candidates.map { DecisionOption($0.slug, .string(describe($0))) }
                )),
            ]
        )
    }

    static func describe(_ entry: ModelRegistryEntry) -> String {
        var parts: [String] = []
        if let name = entry.displayName { parts.append(name) }
        if let family = entry.family { parts.append("family \(family)") }
        if let context = entry.maxContextLength { parts.append("\(context / 1_000)k context") }
        let caps = entry.capabilities.map(\.rawValue).sorted()
        if !caps.isEmpty { parts.append(caps.joined(separator: ", ")) }
        if let usd = entry.cost?.combinedPer1MUSD { parts.append(String(format: "$%.2f per 1M tokens", usd)) }
        return parts.joined(separator: "; ")
    }
}
