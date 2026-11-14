import Foundation
import Logging

/// One yes/no guardrail question. `yes` means the text violates it.
public struct GuardrailCheck: Sendable, Equatable {
    public var id: String
    public var instructions: String
    public var criteria: YesNoCriteria?

    public init(id: String, instructions: String, criteria: YesNoCriteria? = nil) {
        self.id = id
        self.instructions = instructions
        self.criteria = criteria
    }
}

public enum GuardrailDirection: String, Sendable {
    /// User input, before it enters the conversation.
    case inbound
    /// Structured output, before it is delivered to a surface.
    case outbound
}

public enum GuardrailVerdict: Sendable, Equatable {
    case pass
    /// Let it through and flag it for review (the spec's failure default).
    case review([String])
    /// Stop it.
    case block([String])
}

/// Configuration for the `guard` role's battery: several yes/no checks in one call, each with its own policy.
public struct GuardrailConfiguration: Sendable {
    public var inbound: [GuardrailCheck]
    public var outbound: [GuardrailCheck]
    /// Bands per check id on P(violation): `refuse` blocks, `confirm` flags for review, `act` passes.
    /// A check without a policy can only flag for review.
    public var policies: [String: DecisionPolicy]
    public var role: ModelRole
    public var maxCharacters: Int
    public var timeBudget: Duration

    public init(
        inbound: [GuardrailCheck] = [],
        outbound: [GuardrailCheck] = [],
        policies: [String: DecisionPolicy],
        role: ModelRole = .guardrail,
        maxCharacters: Int = 8_000,
        timeBudget: Duration = .seconds(2)
    ) {
        self.inbound = inbound
        self.outbound = outbound
        self.policies = policies
        self.role = role
        self.maxCharacters = max(64, maxCharacters)
        self.timeBudget = timeBudget
    }
}

/// Runs a direction's checks against one text in a single call and combines them in code: any `refuse` blocks,
/// any other non-`act` flags for review, all `act` passes. A failed call flags for review; an unbound role passes.
public actor GuardrailDecisionBattery {
    public struct Record: Sendable {
        public var direction: GuardrailDirection
        public var conversationID: UUID?
        public var verdict: GuardrailVerdict
        public var receiptSummary: String
        public var recordedAt: Date
    }

    private let dispatcher: any DecisionDispatching
    public nonisolated let configuration: GuardrailConfiguration
    private let logger: Logger
    private let recordCapacity: Int
    public private(set) var records: [Record] = []

    public init(
        dispatcher: any DecisionDispatching,
        configuration: GuardrailConfiguration,
        recordCapacity: Int = 200,
        logger: Logger? = nil
    ) {
        self.dispatcher = dispatcher
        self.configuration = configuration
        self.recordCapacity = max(1, recordCapacity)
        self.logger = logger ?? Logger(label: "SwiftAgentHarness.Guardrails")
    }

    public func evaluate(
        _ direction: GuardrailDirection,
        text: String,
        conversationID: UUID?,
        runID: UUID? = nil,
        rolePatches: RoleBindingPatches = .none
    ) async -> GuardrailVerdict {
        let checks = direction == .inbound ? configuration.inbound : configuration.outbound
        guard !checks.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .pass }
        let request = DecisionRequest(
            state: .object([
                "direction": .string(direction.rawValue),
                "text": .string(DecisionConsumerText.bounded(text, maxCharacters: configuration.maxCharacters)),
            ]),
            questions: checks.map { check in
                DecisionQuestionItem(check.id, .yesNo(instructions: .string(check.instructions), criteria: check.criteria))
            }
        )
        let outcome = await dispatcher.decide(
            request,
            role: configuration.role,
            policy: checks.lazy.compactMap { self.configuration.policies[$0.id] }.first,
            context: DecisionCallContext(
                conversationID: conversationID, runID: runID, timeBudget: configuration.timeBudget, rolePatches: rolePatches
            )
        )
        let verdict = Self.combine(outcome: outcome, checks: checks, policies: configuration.policies)
        record(direction, conversationID: conversationID, verdict: verdict, outcome: outcome)
        return verdict
    }

    static func combine(
        outcome: DecisionOutcome,
        checks: [GuardrailCheck],
        policies: [String: DecisionPolicy]
    ) -> GuardrailVerdict {
        switch DecisionConsumerResult(outcome) {
        case .layerOff:
            return .pass
        case .failed:
            return .review(checks.map(\.id))
        case .verdict(_, let accepted):
            guard let result = accepted.result else { return .review(checks.map(\.id)) }
            // The dispatcher forces the primary check to untuned when the answer can't be tied to a pinned
            // version (an echoed alias); then no other check can be trusted either.
            if accepted.evaluation?.reason == .untunedVersion {
                return .review(checks.map(\.id))
            }
            var blocked: [String] = []
            var flagged: [String] = []
            for check in checks {
                guard let policy = policies[check.id] else {
                    flagged.append(check.id)
                    continue
                }
                switch policy.evaluate(result).verdict {
                case .act: break
                case .confirm: flagged.append(check.id)
                case .refuse: blocked.append(check.id)
                }
            }
            if !blocked.isEmpty { return .block(blocked) }
            if !flagged.isEmpty { return .review(flagged) }
            return .pass
        }
    }

    private func record(_ direction: GuardrailDirection, conversationID: UUID?, verdict: GuardrailVerdict, outcome: DecisionOutcome) {
        switch verdict {
        case .pass:
            break
        case .review(let ids):
            logger.warning("guardrail \(direction.rawValue) review \(ids): \(outcome.receipt.summary)")
        case .block(let ids):
            logger.warning("guardrail \(direction.rawValue) blocked \(ids): \(outcome.receipt.summary)")
        }
        records.append(Record(
            direction: direction, conversationID: conversationID, verdict: verdict,
            receiptSummary: outcome.receipt.summary, recordedAt: Date()
        ))
        if records.count > recordCapacity {
            records.removeFirst(records.count - recordCapacity)
        }
    }

    /// The reply a blocked inbound message gets instead of a model turn.
    public static func blockedInboundReply(_ ids: [String]) -> String {
        "This message wasn't sent to the assistant because it matched a guardrail (\(ids.joined(separator: ", ")))."
    }
}
