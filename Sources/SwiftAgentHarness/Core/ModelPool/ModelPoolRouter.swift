import EasyJSON
import Foundation

/// Configuration for the Pool's `router` role: a decision-model ranking input to the selection pipeline's rank
/// stage (spec: model-classes § The selection pipeline, step 3).
public struct ModelPoolRouterConfiguration: Sendable {
    public static let questionID = "model"

    /// Bands on the chosen candidate's probability. The router changes the order only on `act`.
    public var policy: DecisionPolicy
    public var role: ModelRole
    /// Candidates offered to the router, best statically-ranked first.
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

/// One candidate the router may choose, identified by a stable id (a model slug or a binding id).
public struct ModelPoolRouterCandidate: Sendable, Equatable {
    public var id: String
    public var description: String

    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }

    /// Describes a registry entry for the router: name, family, context, capabilities, and price.
    public static func describing(_ entry: ModelRegistryEntry, id: String) -> ModelPoolRouterCandidate {
        var parts: [String] = []
        if let name = entry.displayName { parts.append(name) }
        if let family = entry.family { parts.append("family \(family)") }
        if let context = entry.maxContextLength { parts.append("\(context / 1_000)k context") }
        let caps = entry.capabilities.map(\.rawValue).sorted()
        if !caps.isEmpty { parts.append(caps.joined(separator: ", ")) }
        if let usd = entry.cost?.combinedPer1MUSD { parts.append(String(format: "$%.2f per 1M tokens", usd)) }
        return ModelPoolRouterCandidate(id: id, description: parts.joined(separator: "; "))
    }
}

/// The router's pick and the probabilities behind it.
public struct ModelPoolRouterChoice: Sendable, Equatable {
    public var id: String
    public var probabilities: [String: Double]

    public func probability(of id: String) -> Double {
        probabilities[id] ?? 0
    }
}

/// The router's decide call. It belongs to the Model Pool: callers never invoke it, and its answer is one input to
/// ranking. Anything short of a calibrated `act` leaves the static ranking unchanged (spec failure default: the
/// role's default).
public struct ModelPoolRouter: Sendable {
    public var configuration: ModelPoolRouterConfiguration

    public init(configuration: ModelPoolRouterConfiguration) {
        self.configuration = configuration
    }

    /// Asks the router which candidate should serve `request`; `nil` keeps the static order.
    func choose(
        request: String,
        current: String?,
        candidates: [ModelPoolRouterCandidate],
        dispatcher: any DecisionDispatching,
        context: DecisionCallContext
    ) async -> ModelPoolRouterChoice? {
        var seen = Set<String>()
        let offered = Array(candidates.filter { seen.insert($0.id).inserted }.prefix(configuration.maxCandidates))
        guard offered.count >= 2, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var routerContext = context
        routerContext.timeBudget = configuration.timeBudget
        routerContext.pin = nil
        let outcome = await dispatcher.decide(
            Self.makeRequest(request: request, current: current, candidates: offered, maxCharacters: configuration.maxRequestCharacters),
            role: configuration.role,
            policy: configuration.policy,
            context: routerContext
        )
        guard case .verdict(.act, let accepted) = DecisionConsumerResult(outcome),
              case .choice(let choice, let probabilities)? = accepted.result?.answers[ModelPoolRouterConfiguration.questionID],
              offered.contains(where: { $0.id == choice })
        else { return nil }
        return ModelPoolRouterChoice(id: choice, probabilities: probabilities)
    }

    static func makeRequest(
        request: String,
        current: String?,
        candidates: [ModelPoolRouterCandidate],
        maxCharacters: Int
    ) -> DecisionRequest {
        var state: [String: JSON] = [
            "request": .string(DecisionConsumerText.bounded(request, maxCharacters: maxCharacters)),
        ]
        if let current { state["current_model"] = .string(current) }
        return DecisionRequest(
            state: .object(state),
            questions: [
                DecisionQuestionItem(ModelPoolRouterConfiguration.questionID, .choice(
                    instructions: .string("Which model should handle this request?"),
                    options: candidates.map { DecisionOption($0.id, .string($0.description)) }
                )),
            ]
        )
    }
}
