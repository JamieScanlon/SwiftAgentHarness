import Foundation
import Logging

/// Configuration for the `skill-filter` role: narrow many skills to a few for this turn.
public struct SkillFilterConfiguration: Sendable {
    public static let appliesQuestionID = "applies"
    public static let skillQuestionID = "skill"

    /// Bands for the `applies` question (P(yes) = some skill helps). A shortlist is offered only on `act`.
    public var policy: DecisionPolicy
    public var role: ModelRole
    /// At most this many skills in the shortlist.
    public var shortlistSize: Int
    /// A skill needs at least this share of the `skill` distribution to be listed.
    public var minimumShare: Double
    public var maxRequestCharacters: Int
    public var timeBudget: Duration

    public init(
        policy: DecisionPolicy,
        role: ModelRole = .skillFilter,
        shortlistSize: Int = 3,
        minimumShare: Double = 0.1,
        maxRequestCharacters: Int = 2_000,
        timeBudget: Duration = .seconds(1)
    ) {
        self.policy = policy
        self.role = role
        self.shortlistSize = max(1, shortlistSize)
        self.minimumShare = minimumShare
        self.maxRequestCharacters = max(64, maxRequestCharacters)
        self.timeBudget = timeBudget
    }
}

/// A skill the filter may choose.
public struct SkillCandidate: Sendable, Equatable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// Picks the skills most relevant to a request. The result is a per-turn hint injected after the cached prompt
/// prefix; the frozen skills index is never rewritten, so prompt caching is unaffected. Any non-`act` answer or
/// failure loads nothing extra.
public actor SkillFilterDecisionGate {
    private let dispatcher: any DecisionDispatching
    public nonisolated let configuration: SkillFilterConfiguration
    private let logger: Logger

    public init(dispatcher: any DecisionDispatching, configuration: SkillFilterConfiguration, logger: Logger? = nil) {
        self.dispatcher = dispatcher
        self.configuration = configuration
        self.logger = logger ?? Logger(label: "SwiftAgentHarness.ContextEngine.SkillFilter")
    }

    /// Skill names to suggest, most relevant first, or `nil` to add nothing.
    public func shortlist(
        userRequest: String,
        skills: [SkillCandidate],
        conversationID: UUID?,
        runID: UUID? = nil,
        rolePatches: RoleBindingPatches = .none
    ) async -> [String]? {
        guard skills.count >= 2, skills.count <= 255,
              !userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let outcome = await dispatcher.decide(
            Self.makeRequest(userRequest: userRequest, skills: skills, maxCharacters: configuration.maxRequestCharacters),
            role: configuration.role,
            policy: configuration.policy,
            context: DecisionCallContext(
                conversationID: conversationID, runID: runID, timeBudget: configuration.timeBudget, rolePatches: rolePatches
            )
        )
        guard case .verdict(.act, let accepted) = DecisionConsumerResult(outcome),
              case .choice(_, let probabilities)? = accepted.result?.answers[SkillFilterConfiguration.skillQuestionID]
        else { return nil }
        let names = probabilities
            .filter { $0.value >= configuration.minimumShare }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(configuration.shortlistSize)
            .map(\.key)
        return names.isEmpty ? nil : names
    }

    /// The per-turn hint for a shortlist.
    public static func reminder(for shortlist: [String]) -> String {
        "Skills most relevant to this request: \(shortlist.joined(separator: ", ")). " +
            "If one fits, load it with the skill tool before you start."
    }

    static func makeRequest(userRequest: String, skills: [SkillCandidate], maxCharacters: Int) -> DecisionRequest {
        DecisionRequest(
            state: .object(["user_request": .string(DecisionConsumerText.bounded(userRequest, maxCharacters: maxCharacters))]),
            questions: [
                DecisionQuestionItem(SkillFilterConfiguration.appliesQuestionID, .yesNo(
                    instructions: .string("Would one of the listed skills help the assistant handle this request?")
                )),
                DecisionQuestionItem(SkillFilterConfiguration.skillQuestionID, .choice(
                    instructions: .string("Which skill best fits this request?"),
                    options: skills.map { DecisionOption($0.name, .string($0.description)) }
                )),
            ]
        )
    }
}
