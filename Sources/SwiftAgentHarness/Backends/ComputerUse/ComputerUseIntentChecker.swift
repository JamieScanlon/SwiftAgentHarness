import EasyJSON
import Foundation

public struct ComputerUseIntentCheckConfiguration: Sendable {
    public static let questionID = "consistent"

    /// Bands for the `consistent` question. Only `act` lets an interact action through without confirmation.
    public var policy: DecisionPolicy
    public var role: ModelRole
    /// Prior actions included in the state, most recent last.
    public var maxHistory: Int
    public var timeBudget: Duration

    public init(
        policy: DecisionPolicy,
        role: ModelRole = .guardrail,
        maxHistory: Int = 10,
        timeBudget: Duration = .seconds(3)
    ) {
        self.policy = policy
        self.role = role
        self.maxHistory = max(0, maxHistory)
        self.timeBudget = timeBudget
    }
}

/// Everything the intent check may see. The screenshot, screen text, and on-screen labels are deliberately absent:
/// they are attacker-controllable and are the injection channel.
public struct ComputerUseIntentCheckInput: Sendable {
    public var conversationID: UUID?
    public var runID: UUID?
    public var accountID: UUID?
    public var userRequest: [String]
    /// Text history of prior actions, built from harness-derived identifiers.
    public var history: [ComputerUseProposedAction]
    public var proposed: ComputerUseProposedAction
    public var rolePatches: RoleBindingPatches

    public init(
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        accountID: UUID? = nil,
        userRequest: [String],
        history: [ComputerUseProposedAction],
        proposed: ComputerUseProposedAction,
        rolePatches: RoleBindingPatches = .none
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.accountID = accountID
        self.userRequest = userRequest
        self.history = history
        self.proposed = proposed
        self.rolePatches = rolePatches
    }
}

public enum ComputerUseIntentVerdict: Sendable {
    case consistent(receipt: RouteReceipt)
    /// A mismatch or an unavailable verdict. Never silently allowed.
    case confirm(reason: String, receipt: RouteReceipt?)
    /// No `guard` binding. Interact actions on shared targets are confirmed instead.
    case unbound

    public var summary: String {
        switch self {
        case .consistent: return "consistent with the task"
        case .confirm(let reason, _): return "needs confirmation: \(reason)"
        case .unbound: return "no intent checker bound"
        }
    }
}

/// Per-action intent alignment on the `guard` decide role: is this action consistent with what the user asked for?
public actor ComputerUseIntentChecker {
    private let dispatcher: any DecisionDispatching
    public nonisolated let configuration: ComputerUseIntentCheckConfiguration

    public init(dispatcher: any DecisionDispatching, configuration: ComputerUseIntentCheckConfiguration) {
        self.dispatcher = dispatcher
        self.configuration = configuration
    }

    public func evaluate(_ input: ComputerUseIntentCheckInput) async -> ComputerUseIntentVerdict {
        let requests = input.userRequest
            .map { ComputerUseSecrets.redacting($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !requests.isEmpty else {
            return .confirm(reason: "no user request to check against", receipt: nil)
        }
        let request = Self.makeRequest(
            userRequest: requests,
            history: Array(input.history.suffix(configuration.maxHistory)),
            proposed: input.proposed
        )
        let outcome = await dispatcher.decide(
            request,
            role: configuration.role,
            policy: configuration.policy,
            context: DecisionCallContext(
                conversationID: input.conversationID,
                runID: input.runID,
                accountID: input.accountID,
                timeBudget: configuration.timeBudget,
                rolePatches: input.rolePatches
            )
        )
        return Self.interpret(outcome)
    }

    static func interpret(_ outcome: DecisionOutcome) -> ComputerUseIntentVerdict {
        if case .roleUnbound? = outcome.error { return .unbound }
        if let error = outcome.error {
            return .confirm(reason: "intent check failed: \(error)", receipt: outcome.receipt)
        }
        guard let evaluation = outcome.evaluation else {
            return .confirm(reason: "intent check returned no verdict", receipt: outcome.receipt)
        }
        guard evaluation.verdict == .act else {
            return .confirm(reason: "intent check verdict \(evaluation.verdict.rawValue)", receipt: outcome.receipt)
        }
        return .consistent(receipt: outcome.receipt)
    }

    public static func makeRequest(
        userRequest: [String],
        history: [ComputerUseProposedAction],
        proposed: ComputerUseProposedAction
    ) -> DecisionRequest {
        var action: [String: JSON] = ["kind": .string(proposed.kind)]
        if let app = proposed.app { action["app"] = .string(app) }
        if let domain = proposed.domain { action["domain"] = .string(domain) }
        if let role = proposed.elementRole { action["element_role"] = .string(role) }
        return DecisionRequest(
            state: .object([
                "user_request": .array(userRequest.map { .string($0) }),
                "prior_actions": .array(history.map { .string($0.summary) }),
                "proposed_action": .object(action),
            ]),
            questions: [
                DecisionQuestionItem(
                    ComputerUseIntentCheckConfiguration.questionID,
                    .yesNo(instructions: .string(
                        "Is the proposed computer action consistent with what the user asked for, given the actions so far?"
                    ))
                ),
            ]
        )
    }
}
