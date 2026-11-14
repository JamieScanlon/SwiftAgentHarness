import EasyJSON
import Foundation
import SwiftAgentKit

/// Emulates `decide` with a `generate` model when no decider is bound (or for kinds/languages the decider handles
/// poorly). Results are always `calibrated: false`, so policy treats them as unavailable unless it was tuned on
/// this exact emulating version.
public struct LLMEmulationDecisionCodec: Sendable {
    public enum Rung: String, Sendable, Codable, Hashable {
        /// One constrained-token answer per question, distribution read from top logprobs and renormalized.
        case logprobs
        /// Strict JSON schema with an enum per question; labels only, never a synthetic distribution.
        case schema

        var guarantee: OutputGuarantee {
            switch self {
            case .logprobs: return .logprobs
            case .schema: return .schemaStrict
            }
        }
    }

    /// Metadata key adapters use to surface top-logprob candidates for the first generated token:
    /// `[{"token": String, "logprob": Double}]`.
    public static let topLogprobsMetadataKey = "top_logprobs"
    static let maxLetterOptions = 26

    private let llm: any LLMProtocol
    public let rung: Rung
    public let modelVersion: String

    public init(llm: any LLMProtocol, rung: Rung, modelVersion: String? = nil) {
        self.llm = llm
        self.rung = rung
        self.modelVersion = modelVersion ?? llm.getModelName()
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        try request.validate()
        switch rung {
        case .schema:
            return try await decideWithSchema(request)
        case .logprobs:
            return try await decideWithLogprobs(request)
        }
    }

    // MARK: - Schema rung

    private func decideWithSchema(_ request: DecisionRequest) async throws -> DecisionResult {
        var properties: [String: JSON] = [:]
        var required: [JSON] = []
        for item in request.questions {
            guard let labels = Self.labels(for: item.question) else { continue }
            properties[item.id] = .object(["type": .string("string"), "enum": .array(labels.map { .string($0) })])
            required.append(.string(item.id))
        }
        let schema: JSON = .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required),
            "additionalProperties": .boolean(false),
        ])
        let messages = [
            Message(id: UUID(), role: .system, content: Self.systemPrompt),
            Message(id: UUID(), role: .user, content: Self.schemaPrompt(for: request)),
        ]
        let config = LLMRequestConfig(
            temperature: 0,
            stream: false,
            responseFormat: .jsonSchema(name: "decision_answers", schema: schema)
        )
        let response = try await llm.send(messages, config: config)
        let parsed = Self.extractJSONObject(response.content)
        var raw: [String: DecisionAnswer] = [:]
        for item in request.questions {
            guard let labels = Self.labels(for: item.question) else {
                raw[item.id] = .unavailable(reason: .emulatedNoProbability)
                continue
            }
            guard let label = parsed?[wire: item.id]?.wireString else { continue }
            raw[item.id] = .unavailable(
                reason: .emulatedNoProbability,
                advisoryLabel: labels.contains(label) ? label : nil
            )
        }
        return DecisionResult(
            modelVersion: modelVersion,
            calibrated: false,
            guarantee: .schemaStrict,
            answers: DecisionAnswerValidator.reconcile(request: request, raw: raw),
            usage: Self.usage(from: response)
        )
    }

    // MARK: - Logprobs rung

    private func decideWithLogprobs(_ request: DecisionRequest) async throws -> DecisionResult {
        var raw: [String: DecisionAnswer] = [:]
        var usage = DecisionUsage()
        for item in request.questions {
            guard let tokens = Self.tokens(for: item.question) else {
                raw[item.id] = .unavailable(reason: .emulatedNoProbability)
                continue
            }
            let messages = [
                Message(id: UUID(), role: .system, content: Self.systemPrompt),
                Message(id: UUID(), role: .user, content: Self.tokenPrompt(state: request.state, item: item, tokens: tokens)),
            ]
            let config = LLMRequestConfig(
                maxTokens: 1,
                temperature: 0,
                stream: false,
                additionalParameters: .object(["logprobs": .boolean(true), "top_logprobs": .integer(20)])
            )
            let response = try await llm.send(messages, config: config)
            usage = usage + Self.usage(from: response)
            raw[item.id] = Self.answer(from: response, question: item.question, tokens: tokens)
        }
        return DecisionResult(
            modelVersion: modelVersion,
            calibrated: false,
            guarantee: .logprobs,
            answers: DecisionAnswerValidator.reconcile(request: request, raw: raw),
            usage: usage
        )
    }

    static func answer(from response: LLMResponse, question: DecisionQuestion, tokens: [String]) -> DecisionAnswer {
        guard let candidates = response.metadata?.modelMetadata?[wire: topLogprobsMetadataKey]?.wireArray else {
            return .unavailable(reason: .emulatedNoProbability, advisoryLabel: label(forToken: response.content, question: question, tokens: tokens))
        }
        var mass = Array(repeating: 0.0, count: tokens.count)
        for candidate in candidates {
            guard let token = candidate[wire: "token"]?.wireString, let logprob = candidate[wire: "logprob"]?.wireNumber,
                  let index = tokens.firstIndex(of: token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            else { continue }
            mass[index] += exp(logprob)
        }
        let total = mass.reduce(0, +)
        guard total > 0, total.isFinite else {
            return .unavailable(reason: .emulatedNoProbability, advisoryLabel: label(forToken: response.content, question: question, tokens: tokens))
        }
        let distribution = mass.map { $0 / total }
        switch question {
        case .yesNo:
            return .yesNo(pYes: distribution[0])
        case .choice(_, let options):
            var probabilities: [String: Double] = [:]
            for (index, option) in options.enumerated() { probabilities[option.id] = distribution[index] }
            let top = distribution.indices.max { distribution[$0] < distribution[$1] }!
            return .choice(choice: options[top].id, probabilities: probabilities)
        case .score:
            return .score(expected: DecisionAnswerValidator.expectedLevel(distribution), probabilities: distribution)
        case .box:
            return .unavailable(reason: .emulatedNoProbability)
        }
    }

    // MARK: - Prompting

    static let systemPrompt = """
    You answer closed questions about the provided state. Judge only from the state. \
    Answer each question with exactly one of the allowed labels and nothing else.
    """

    /// Legal single tokens per question kind: Y/N, A…Z for choices, 0…9 for score levels.
    static func tokens(for question: DecisionQuestion) -> [String]? {
        switch question {
        case .yesNo:
            return ["Y", "N"]
        case .choice(_, let options):
            guard options.count <= maxLetterOptions else { return nil }
            return options.indices.map { String(UnicodeScalar(UInt8(65 + $0))) }
        case .score(_, let levels):
            return levels.indices.map(String.init)
        case .box:
            return nil
        }
    }

    /// Schema enum labels per question kind.
    static func labels(for question: DecisionQuestion) -> [String]? {
        switch question {
        case .yesNo: return ["yes", "no"]
        case .choice(_, let options): return options.map(\.id)
        case .score(_, let levels): return levels.indices.map(String.init)
        case .box: return nil
        }
    }

    static func label(forToken content: String, question: DecisionQuestion, tokens: [String]) -> String? {
        let token = content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let index = tokens.firstIndex(of: token), let labels = labels(for: question) else { return nil }
        return labels[index]
    }

    static func tokenPrompt(state: JSON, item: DecisionQuestionItem, tokens: [String]) -> String {
        var lines = ["State:", DecisionEntryText.text(state), "", "Question: \(DecisionEntryText.text(item.question.instructions))"]
        switch item.question {
        case .yesNo(_, let criteria):
            if let yes = criteria?.yes { lines.append("Answer Y if: \(DecisionEntryText.text(yes))") }
            if let no = criteria?.no { lines.append("Answer N if: \(DecisionEntryText.text(no))") }
            lines.append("Reply with Y or N.")
        case .choice(_, let options):
            for (index, option) in options.enumerated() {
                let detail = option.entry.map { " — \(DecisionEntryText.text($0))" } ?? ""
                lines.append("\(tokens[index]): \(option.id)\(detail)")
            }
            lines.append("Reply with one letter: \(tokens.joined(separator: ", ")).")
        case .score(_, let levels):
            for (index, level) in levels.enumerated() {
                lines.append("\(index): \(DecisionEntryText.text(level))")
            }
            lines.append("Reply with one digit: \(tokens.joined(separator: ", ")).")
        case .box:
            break
        }
        return lines.joined(separator: "\n")
    }

    static func schemaPrompt(for request: DecisionRequest) -> String {
        var lines = ["State:", DecisionEntryText.text(request.state), "", "Questions:"]
        for item in request.questions {
            lines.append("- \(item.id): \(DecisionEntryText.text(item.question.instructions))")
            switch item.question {
            case .yesNo(_, let criteria):
                if let yes = criteria?.yes { lines.append("  yes if: \(DecisionEntryText.text(yes))") }
                if let no = criteria?.no { lines.append("  no if: \(DecisionEntryText.text(no))") }
                lines.append("  labels: yes, no")
            case .choice(_, let options):
                for option in options {
                    let detail = option.entry.map { ": \(DecisionEntryText.text($0))" } ?? ""
                    lines.append("  \(option.id)\(detail)")
                }
            case .score(_, let levels):
                for (index, level) in levels.enumerated() {
                    lines.append("  \(index): \(DecisionEntryText.text(level))")
                }
            case .box:
                lines.append("  (not answerable)")
            }
        }
        lines.append("")
        lines.append("Return a JSON object mapping each question id to its label.")
        return lines.joined(separator: "\n")
    }

    static func extractJSONObject(_ content: String) -> JSON? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try? DecisionResponseParsing.parse(Data(trimmed.utf8)), json.wireObject != nil {
            return json
        }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else { return nil }
        return try? DecisionResponseParsing.parse(Data(trimmed[start...end].utf8))
    }

    static func usage(from response: LLMResponse) -> DecisionUsage {
        DecisionUsage(
            inputTokens: response.metadata?.promptTokens,
            outputTokens: response.metadata?.completionTokens
        )
    }
}
