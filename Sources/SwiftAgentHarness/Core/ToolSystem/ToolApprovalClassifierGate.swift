import EasyJSON
import Foundation
import SwiftAgentKit

/// The `decide` surface the classifier gate needs. ``ModelPoolDecisionDispatcher`` conforms.
public protocol ToolApprovalDecisionDispatching: Sendable {
    func decide(
        _ request: DecisionRequest,
        role: ModelRole,
        policy: DecisionPolicy?,
        context: DecisionCallContext
    ) async -> DecisionOutcome
}

extension ModelPoolDecisionDispatcher: ToolApprovalDecisionDispatching {}

/// Configuration for classifier-assisted gating (the `gatekeeper` role between the rules and the human).
public struct ToolApprovalClassifierConfiguration: Sendable {
    public static let questionID = "verdict"
    public static let clearOption = "clear"
    public static let cautionOption = "caution"

    /// Bands for the `verdict` question, keyed by the gatekeeper version that answers. Only `act` approves.
    public var policy: DecisionPolicy
    public var role: ModelRole
    /// Most recent trusted user messages included in the state.
    public var maxUserMessages: Int
    public var maxCharactersPerMessage: Int
    /// Calls whose serialized arguments exceed this go to the human; arguments are never truncated.
    public var maxArgumentCharacters: Int
    /// Total budget for the classifier call; the gate is on the latency path of every gated call.
    public var timeBudget: Duration
    public var allowElevatedTools: Bool
    /// Tools the classifier never approves (exiting plan mode is a human review of the plan).
    public var excludedToolNames: Set<String>
    /// User messages with no trust stamp are low-trust by default and stay out of the state.
    public var includeUnstampedUserMessages: Bool

    public init(
        policy: DecisionPolicy,
        role: ModelRole = .gatekeeper,
        maxUserMessages: Int = 3,
        maxCharactersPerMessage: Int = 2_000,
        maxArgumentCharacters: Int = 4_000,
        timeBudget: Duration = .seconds(2),
        allowElevatedTools: Bool = false,
        excludedToolNames: Set<String> = [ModeTransitionToolProvider.exitPlanModeToolName],
        includeUnstampedUserMessages: Bool = false
    ) {
        self.policy = policy
        self.role = role
        self.maxUserMessages = max(1, maxUserMessages)
        self.maxCharactersPerMessage = max(1, maxCharactersPerMessage)
        self.maxArgumentCharacters = max(1, maxArgumentCharacters)
        self.timeBudget = timeBudget
        self.allowElevatedTools = allowElevatedTools
        self.excludedToolNames = Set(excludedToolNames.map { ToolNamePolicyNormalization.canonical($0) })
        self.includeUnstampedUserMessages = includeUnstampedUserMessages
    }
}

/// One gated call as the classifier sees it. Tool outputs are deliberately absent: they are the injection channel.
public struct ToolApprovalClassifierInput: Sendable {
    public var conversationID: UUID
    public var accountID: UUID?
    public var toolName: String
    public var arguments: JSON
    public var route: ToolApprovalRoute
    public var isElevated: Bool
    /// The conversation transcript; only trusted user-role messages are read from it.
    public var transcript: [Message]

    public init(
        conversationID: UUID,
        accountID: UUID? = nil,
        toolName: String,
        arguments: JSON,
        route: ToolApprovalRoute,
        isElevated: Bool,
        transcript: [Message]
    ) {
        self.conversationID = conversationID
        self.accountID = accountID
        self.toolName = toolName
        self.arguments = arguments
        self.route = route
        self.isElevated = isElevated
        self.transcript = transcript
    }
}

public enum ToolApprovalClassifierAskReason: String, Sendable, Equatable {
    case parentRoute = "parent-route"
    case elevatedTool = "elevated-tool"
    case excludedTool = "excluded-tool"
    case noTrustedUserRequest = "no-trusted-user-request"
    case argumentsTooLarge = "arguments-too-large"
    case caution
    case notInActBand = "not-in-act-band"
    case uncalibrated
    case failed
}

public enum ToolApprovalClassifierOutcome: Sendable {
    /// Convert this one *ask* into *allow-once*. Never a durable grant.
    case allowOnce(reason: String, receipt: RouteReceipt)
    /// Leave the call with the human.
    case ask(ToolApprovalClassifierAskReason, receipt: RouteReceipt?)

    public var isAllowOnce: Bool {
        if case .allowOnce = self { return true }
        return false
    }
}

/// What the gate sent and decided, kept so misclassifications can be debugged.
public struct ToolApprovalClassifierRecord: Sendable {
    public var conversationID: UUID
    public var toolName: String
    public var request: DecisionRequest?
    public var outcome: ToolApprovalClassifierOutcome
    public var recordedAt: Date
}

/// Classifier-assisted permission gating over the `gatekeeper` decide role.
///
/// The gate only ever runs after the rules have produced *ask*, so deny rules and the killswitch have already won.
/// It approves one call (`allow-once`) when a calibrated answer picks `clear` inside the policy's act band, and in
/// every other case — unbound role, timeout, error, refusal, uncalibrated or untuned answer, `caution` — it asks.
public actor ToolApprovalClassifierGate {
    private let dispatcher: any ToolApprovalDecisionDispatching
    public nonisolated let configuration: ToolApprovalClassifierConfiguration
    private let recordCapacity: Int
    public private(set) var records: [ToolApprovalClassifierRecord] = []

    public init(
        dispatcher: any ToolApprovalDecisionDispatching,
        configuration: ToolApprovalClassifierConfiguration,
        recordCapacity: Int = 200
    ) {
        self.dispatcher = dispatcher
        self.configuration = configuration
        self.recordCapacity = max(1, recordCapacity)
    }

    public func evaluate(_ input: ToolApprovalClassifierInput) async -> ToolApprovalClassifierOutcome {
        let canonicalTool = ToolNamePolicyNormalization.canonical(input.toolName)
        if input.route != .user {
            return record(input, request: nil, .ask(.parentRoute, receipt: nil))
        }
        if input.isElevated && !configuration.allowElevatedTools {
            return record(input, request: nil, .ask(.elevatedTool, receipt: nil))
        }
        if configuration.excludedToolNames.contains(canonicalTool) {
            return record(input, request: nil, .ask(.excludedTool, receipt: nil))
        }
        let userRequests = Self.trustedUserRequests(in: input.transcript, configuration: configuration)
        if userRequests.isEmpty {
            return record(input, request: nil, .ask(.noTrustedUserRequest, receipt: nil))
        }
        if CanonicalJSON.data(input.arguments).count > configuration.maxArgumentCharacters {
            return record(input, request: nil, .ask(.argumentsTooLarge, receipt: nil))
        }

        let request = Self.makeRequest(userRequests: userRequests, toolName: input.toolName, arguments: input.arguments)
        let outcome = await dispatcher.decide(
            request,
            role: configuration.role,
            policy: configuration.policy,
            context: DecisionCallContext(
                conversationID: input.conversationID,
                accountID: input.accountID,
                timeBudget: configuration.timeBudget
            )
        )
        return record(input, request: request, Self.interpret(outcome))
    }

    /// Allow only on all three: a calibrated result, the `clear` option chosen, and the policy's `act` verdict.
    /// Choice bands test the top-1 probability without naming the option, so the option is checked here.
    static func interpret(_ outcome: DecisionOutcome) -> ToolApprovalClassifierOutcome {
        let receipt = outcome.receipt
        guard outcome.error == nil, let result = outcome.result, let evaluation = outcome.evaluation else {
            return .ask(.failed, receipt: receipt)
        }
        guard result.calibrated else {
            return .ask(.uncalibrated, receipt: receipt)
        }
        guard case .choice(let choice, let probabilities)? = result.answers[ToolApprovalClassifierConfiguration.questionID] else {
            return .ask(.failed, receipt: receipt)
        }
        guard choice == ToolApprovalClassifierConfiguration.clearOption else {
            return .ask(.caution, receipt: receipt)
        }
        guard evaluation.verdict == .act else {
            return .ask(.notInActBand, receipt: receipt)
        }
        let p = probabilities[ToolApprovalClassifierConfiguration.clearOption] ?? evaluation.value ?? 0
        let reason = "classifier: clear p=\(String(format: "%.3f", p)) model=\(result.modelVersion) band=act receipt=\(receipt.callID.uuidString)"
        return .allowOnce(reason: reason, receipt: receipt)
    }

    /// Most recent trusted user-role messages, oldest first, each truncated. Harness-injected and low-trust
    /// messages never enter the state.
    static func trustedUserRequests(
        in transcript: [Message],
        configuration: ToolApprovalClassifierConfiguration
    ) -> [String] {
        let trusted = transcript.filter { message in
            guard message.role == .user, !HarnessInjectedMessageMetadata.isHarnessInjected(message) else { return false }
            let raw = MessageInputTrustCodec.sanitizedInputTrustRaw(message.inputTrustRaw)
            if raw == nil { return configuration.includeUnstampedUserMessages }
            return MessageInputTrustCodec.safePolicyClass(raw: raw) == .trusted
        }
        return trusted.suffix(configuration.maxUserMessages).compactMap { message in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return text.count > configuration.maxCharactersPerMessage
                ? String(text.prefix(configuration.maxCharactersPerMessage)) + "…"
                : text
        }
    }

    /// One state, one `choice` over {clear, caution}. Evidence in the state; the judgment in the question.
    public static func makeRequest(userRequests: [String], toolName: String, arguments: JSON) -> DecisionRequest {
        DecisionRequest(
            state: .object([
                "user_request": .array(userRequests.map { .string($0) }),
                "proposed_call": .object([
                    "tool": .string(toolName),
                    "arguments": arguments,
                ]),
            ]),
            questions: [
                DecisionQuestionItem(
                    ToolApprovalClassifierConfiguration.questionID,
                    .choice(
                        instructions: .string(
                            "Would the user predictably approve this exact tool call, given only what they asked for?"
                        ),
                        options: [
                            DecisionOption(
                                ToolApprovalClassifierConfiguration.clearOption,
                                .string("The call directly serves the user's request and has no effects beyond it.")
                            ),
                            DecisionOption(
                                ToolApprovalClassifierConfiguration.cautionOption,
                                .string("The call goes beyond the request, is destructive or irreversible, touches credentials or external parties, or its intent is unclear.")
                            ),
                        ]
                    )
                ),
            ]
        )
    }

    private func record(
        _ input: ToolApprovalClassifierInput,
        request: DecisionRequest?,
        _ outcome: ToolApprovalClassifierOutcome
    ) -> ToolApprovalClassifierOutcome {
        records.append(ToolApprovalClassifierRecord(
            conversationID: input.conversationID,
            toolName: input.toolName,
            request: request,
            outcome: outcome,
            recordedAt: Date()
        ))
        if records.count > recordCapacity {
            records.removeFirst(records.count - recordCapacity)
        }
        return outcome
    }
}
