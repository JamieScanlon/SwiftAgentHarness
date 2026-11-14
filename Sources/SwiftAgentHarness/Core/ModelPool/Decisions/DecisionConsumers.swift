import Foundation

/// The `decide` surface every consumer layer uses. ``ModelPoolDecisionDispatcher`` conforms; tests supply fakes.
public protocol DecisionDispatching: Sendable {
    func decide(
        _ request: DecisionRequest,
        role: ModelRole,
        policy: DecisionPolicy?,
        context: DecisionCallContext
    ) async -> DecisionOutcome

    /// Network-free check that the policy's bands cover a version the role's candidates serve.
    func validateBinding(role: ModelRole, policy: DecisionPolicy?) async -> DecisionBindingValidation

    /// Pre-connects and probes configured aliases for drift.
    func warm(role: ModelRole, request: DecisionRequest) async -> [DecisionAliasProbe]
}

public extension DecisionDispatching {
    func validateBinding(role: ModelRole, policy: DecisionPolicy?) async -> DecisionBindingValidation {
        DecisionBindingValidation(role: role, servedVersions: [], tunedVersions: [], problems: [])
    }

    func warm(role: ModelRole, request: DecisionRequest) async -> [DecisionAliasProbe] {
        []
    }
}

extension ModelPoolDecisionDispatcher: DecisionDispatching {}

/// How a consumer should read one dispatch: an unbound role turns the layer off, any other failure takes the
/// consumer's spec failure default, and only a successful call yields a verdict.
enum DecisionConsumerResult: Sendable {
    case verdict(DecisionVerdict, DecisionOutcome)
    case layerOff
    case failed(DecisionOutcome)

    init(_ outcome: DecisionOutcome) {
        if case .roleUnbound? = outcome.error {
            self = .layerOff
        } else if outcome.error != nil || outcome.result == nil {
            self = .failed(outcome)
        } else {
            self = .verdict(outcome.evaluation?.verdict ?? .confirm, outcome)
        }
    }
}

/// The optional `decide` consumers a host can turn on. Each is off when `nil`, and each falls back to its spec
/// failure default when its role is bound but the call fails. Model routing is not a consumer: it belongs to the
/// Model Pool (``ModelPoolTurnSelector`` and the dispatcher's rank stage).
public struct DecisionConsumers: Sendable {
    /// Memory: approves agent-written memory before it is stored. Failure default: don't write.
    public var memoryWriteGate: MemoryWriteDecisionGate?
    /// Context Engine: shortlists skills for the turn. Failure default: load nothing extra.
    public var skillFilter: SkillFilterDecisionGate?
    /// Conversation Manager / Interface: inbound and outbound guardrail battery. Failure default: review.
    public var guardrails: GuardrailDecisionBattery?
    /// Input provenance: warns on likely prompt injection in external tool output. Never blocks.
    public var injectionProbe: InjectionProbeDecisionGate?

    public init(
        memoryWriteGate: MemoryWriteDecisionGate? = nil,
        skillFilter: SkillFilterDecisionGate? = nil,
        guardrails: GuardrailDecisionBattery? = nil,
        injectionProbe: InjectionProbeDecisionGate? = nil
    ) {
        self.memoryWriteGate = memoryWriteGate
        self.skillFilter = skillFilter
        self.guardrails = guardrails
        self.injectionProbe = injectionProbe
    }

    public static let none = DecisionConsumers()
}

enum DecisionConsumerText {
    /// Keeps head and tail of long text so the decider sees both how something starts and how it ends.
    static func bounded(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters, maxCharacters > 1 else { return text }
        let head = maxCharacters * 2 / 3
        let tail = maxCharacters - head
        return String(text.prefix(head)) + "\n…\n" + String(text.suffix(tail))
    }
}
