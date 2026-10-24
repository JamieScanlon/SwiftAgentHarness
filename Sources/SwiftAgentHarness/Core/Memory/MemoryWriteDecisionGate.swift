import Foundation
import Logging

/// Configuration for the `memory-gate` role: "does this state a durable fact?" before agent memory is stored.
public struct MemoryWriteGateConfiguration: Sendable {
    public static let questionID = "durable"

    /// Bands for the `durable` question (P(yes) = durable). Only `act` lets the write through.
    public var policy: DecisionPolicy
    public var role: ModelRole
    /// Longest added text sent to the decider; head and tail are kept beyond this.
    public var maxCharacters: Int
    public var timeBudget: Duration

    public init(
        policy: DecisionPolicy,
        role: ModelRole = .memoryGate,
        maxCharacters: Int = 4_000,
        timeBudget: Duration = .seconds(2)
    ) {
        self.policy = policy
        self.role = role
        self.maxCharacters = max(64, maxCharacters)
        self.timeBudget = timeBudget
    }
}

public enum MemoryWriteDecision: Sendable, Equatable {
    case allow(reason: String)
    case deny(reason: String)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// Approves a candidate memory write. A write proceeds only on a calibrated `act`; any other answer or a failed
/// call means don't write (spec failure default). An unbound role turns the gate off.
public actor MemoryWriteDecisionGate {
    private let dispatcher: any DecisionDispatching
    public nonisolated let configuration: MemoryWriteGateConfiguration
    private let logger: Logger

    public init(
        dispatcher: any DecisionDispatching,
        configuration: MemoryWriteGateConfiguration,
        logger: Logger? = nil
    ) {
        self.dispatcher = dispatcher
        self.configuration = configuration
        self.logger = logger ?? Logger(label: "SwiftAgentHarness.Memory.WriteGate")
    }

    public func evaluate(
        path: String,
        priorContent: String?,
        newContent: String,
        conversationID: UUID?,
        runID: UUID? = nil,
        rolePatches: RoleBindingPatches = .none
    ) async -> MemoryWriteDecision {
        let added = Self.addedText(prior: priorContent, new: newContent)
        guard !added.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .allow(reason: "no added text")
        }
        let outcome = await dispatcher.decide(
            Self.makeRequest(path: path, addedText: added, maxCharacters: configuration.maxCharacters),
            role: configuration.role,
            policy: configuration.policy,
            context: DecisionCallContext(
                conversationID: conversationID, runID: runID, timeBudget: configuration.timeBudget, rolePatches: rolePatches
            )
        )
        switch DecisionConsumerResult(outcome) {
        case .layerOff:
            return .allow(reason: "memory gate off")
        case .verdict(.act, let outcome):
            return .allow(reason: outcome.receipt.summary)
        case .verdict(let verdict, let outcome):
            logger.info("memory write declined (\(verdict.rawValue)): \(outcome.receipt.summary)")
            return .deny(reason: "not judged a durable fact (\(verdict.rawValue))")
        case .failed(let outcome):
            logger.warning("memory gate failed, not writing: \(outcome.receipt.summary)")
            return .deny(reason: "memory gate unavailable")
        }
    }

    /// The text a write adds: everything for a new file, or what differs from the prior content for an edit.
    static func addedText(prior: String?, new: String) -> String {
        guard let prior, !prior.isEmpty else { return new }
        let priorChars = Array(prior)
        let newChars = Array(new)
        var start = 0
        while start < priorChars.count, start < newChars.count, priorChars[start] == newChars[start] { start += 1 }
        var priorEnd = priorChars.count
        var newEnd = newChars.count
        while priorEnd > start, newEnd > start, priorChars[priorEnd - 1] == newChars[newEnd - 1] {
            priorEnd -= 1
            newEnd -= 1
        }
        return String(newChars[start..<newEnd])
    }

    static func makeRequest(path: String, addedText: String, maxCharacters: Int) -> DecisionRequest {
        DecisionRequest(
            state: .object([
                "memory_file": .string(URL(fileURLWithPath: path).lastPathComponent),
                "added_text": .string(DecisionConsumerText.bounded(addedText, maxCharacters: maxCharacters)),
            ]),
            questions: [
                DecisionQuestionItem(MemoryWriteGateConfiguration.questionID, .yesNo(
                    instructions: .string("Does the added text state a durable fact worth remembering across sessions?"),
                    criteria: YesNoCriteria(
                        yes: .string("it records a stable preference, a decision, or a lasting fact about the user, the project, or their tools"),
                        no: .string("it is transient task detail, a guess, a restatement of the conversation, or instructions to the assistant")
                    )
                )),
            ]
        )
    }
}

struct MemoryWriteGateDeniedError: Error, CustomStringConvertible {
    let reason: String

    var description: String {
        "Memory write declined by the memory gate: \(reason). Save only durable facts."
    }
}
