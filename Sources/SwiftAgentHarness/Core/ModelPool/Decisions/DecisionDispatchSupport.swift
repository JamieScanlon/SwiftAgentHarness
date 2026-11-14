import Foundation
import Logging
import SwiftAgentKit

/// Registry rows the dispatcher selects from. ``ModelManager`` conforms; hosts and tests can supply a static list.
public protocol ContractCandidateSource: Sendable {
    /// Every registry row, including non-chat contracts.
    func allContractEntries() async -> [ModelRegistryEntry]
}

public struct StaticContractCandidateSource: ContractCandidateSource {
    public var entries: [ModelRegistryEntry]

    public init(_ entries: [ModelRegistryEntry]) {
        self.entries = entries
    }

    public func allContractEntries() async -> [ModelRegistryEntry] {
        entries
    }
}

/// Finds the decision provider that serves a binding.
public protocol DecisionProviderResolving: Sendable {
    func decisionProvider(for binding: ProviderBinding) -> (any DecisionProviding)?
}

/// Resolves through the process-wide ``ProviderRegistry`` `decision` slot.
public struct RegistryDecisionProviderResolver: DecisionProviderResolving {
    public init() {}

    public func decisionProvider(for binding: ProviderBinding) -> (any DecisionProviding)? {
        ProviderRegistry.decisionProvider(for: binding.providerId)
    }
}

/// Fixed provider map keyed by provider id.
public struct StaticDecisionProviderResolver: DecisionProviderResolving {
    public var providers: [ProviderID: any DecisionProviding]

    public init(_ providers: [ProviderID: any DecisionProviding]) {
        self.providers = providers
    }

    public func decisionProvider(for binding: ProviderBinding) -> (any DecisionProviding)? {
        providers[binding.providerId]
    }
}

/// Builds the `generate` model used by the LLM-emulation codec. Emulation never applies thinking.
public protocol DecisionEmulationLLMProviding: Sendable {
    func emulationLLM(for entry: ModelRegistryEntry) async throws -> any LLMProtocol
}

/// Emulation through the Pool's standard adapter factory, so emulated calls keep the same wrappers as chat calls.
public struct ModelLLMFactoryEmulationProvider: DecisionEmulationLLMProviding {
    private let factory: any ModelLLMFactoring
    private let logger: Logger?

    public init(factory: any ModelLLMFactoring, logger: Logger? = nil) {
        self.factory = factory
        self.logger = logger
    }

    public func emulationLLM(for entry: ModelRegistryEntry) async throws -> any LLMProtocol {
        let prompt = try await SystemPrompt(skillLoader: nil, logger: logger)
        return factory.makeBaseLLM(
            model: entry.toModel(),
            providerBindings: entry.providers,
            conversationID: nil,
            ownerAccountID: nil,
            systemPrompt: prompt,
            logger: logger
        )
    }
}

/// Response cache for `decide` against a pinned version, keyed by `(modelVersion, request hash)`.
public actor DecisionResponseCache {
    private struct Key: Hashable {
        var modelVersion: String
        var request: Data
    }

    private var storage: [Key: DecisionResult] = [:]
    private var order: [Key] = []
    private let capacity: Int

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    public func lookup(modelVersion: String, request: DecisionRequest) -> DecisionResult? {
        storage[Key(modelVersion: modelVersion, request: request.canonicalData)]
    }

    public func store(_ result: DecisionResult, modelVersion: String, request: DecisionRequest) {
        let key = Key(modelVersion: modelVersion, request: request.canonicalData)
        if storage[key] == nil {
            order.append(key)
            if order.count > capacity {
                storage.removeValue(forKey: order.removeFirst())
            }
        }
        storage[key] = result
    }

    public var count: Int { storage.count }
}

/// Per-call context for a `decide` dispatch.
public struct DecisionCallContext: Sendable {
    public var conversationID: UUID?
    /// The run this call belongs to; route receipts publish under it.
    public var runID: UUID?
    public var accountID: UUID?
    /// Per-call explicit pin (last layer of role resolution).
    public var pin: String?
    /// BCP-47 primary language of the state, used to prefer deciders strong in it.
    public var language: String?
    /// Total time budget across retries.
    public var timeBudget: Duration?
    /// Mode-profile and conversation role overrides for this call.
    public var rolePatches: RoleBindingPatches

    public init(
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        accountID: UUID? = nil,
        pin: String? = nil,
        language: String? = nil,
        timeBudget: Duration? = nil,
        rolePatches: RoleBindingPatches = .none
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.accountID = accountID
        self.pin = pin
        self.language = language
        self.timeBudget = timeBudget
        self.rolePatches = rolePatches
    }
}

public enum DecisionDispatchError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case invalidPolicy(DecisionPolicyValidationError)
    case roleUnbound(ModelRole)
    case contractMismatch(role: ModelRole, contract: ModelContract)
    case pinRejected(pin: String, reason: String)
    case noCandidate(role: ModelRole, localityRestricted: Bool)
    case budgetDenied(String)
    case provider(classification: ProviderFailoverClassification, message: String)
}

/// The full result of a dispatch. Gates read ``verdict``; it is always conservative on failure.
public struct DecisionOutcome: Sendable {
    /// Final answer (stage 2 when the call escalated). `nil` when every candidate failed.
    public var result: DecisionResult?
    /// Stage-1 answer when the call escalated.
    public var firstStage: DecisionResult?
    /// Present when the call carried a policy.
    public var evaluation: DecisionEvaluation?
    public var receipt: RouteReceipt
    public var error: DecisionDispatchError?

    public init(
        result: DecisionResult?,
        firstStage: DecisionResult? = nil,
        evaluation: DecisionEvaluation?,
        receipt: RouteReceipt,
        error: DecisionDispatchError? = nil
    ) {
        self.result = result
        self.firstStage = firstStage
        self.evaluation = evaluation
        self.receipt = receipt
        self.error = error
    }

    public var verdict: DecisionVerdict? {
        evaluation?.verdict
    }
}

extension ModelRegistryEntry {
    /// Whether `reference` names this entry by UUID, slug, canonical key, or display name.
    func isNamed(_ reference: String) -> Bool {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if let uuid = UUID(uuidString: trimmed), uuid == id { return true }
        if allSlugs.contains(trimmed) { return true }
        if providers.contains(where: { "\($0.providerId)/\($0.endpointModelId)" == trimmed }) { return true }
        if lifecycle.aliases.contains(trimmed) { return true }
        return canonicalModelKey == trimmed || displayName == trimmed
    }
}

extension ProviderFailoverClassification {
    /// Fallback happens only on availability-class errors. Quality is never a fallback reason.
    var isAvailabilityClass: Bool {
        switch self {
        case .transient, .rateLimited, .credentialExhausted, .modelNotFound:
            return true
        case .authError, .contextOverflow, .policyBlocked, .permanent:
            return false
        }
    }
}
