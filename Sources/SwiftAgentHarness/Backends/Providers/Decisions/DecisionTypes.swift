import EasyJSON
import Foundation

/// Instructions, criteria, options, and levels may be a string, a JSON object, or a JSON array (spec: `Entry`).
public typealias DecisionEntry = JSON

/// An image referenced by key from state, instructions, or criteria (spec: `ImageAsset`).
public struct DecisionImageAsset: Sendable, Codable, Hashable {
    public enum MediaType: String, Sendable, Codable, Hashable {
        case png = "image/png"
        case jpeg = "image/jpeg"

        /// Short format name used by the SystemOne `assets` encoding.
        public var formatName: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }
    }

    public var mediaType: MediaType
    public var data: Data

    public init(mediaType: MediaType, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }

    public var dataURL: String {
        "data:\(mediaType.rawValue);base64,\(data.base64EncodedString())"
    }
}

/// Criteria for a yes/no question.
public struct YesNoCriteria: Sendable, Codable, Hashable {
    public var yes: DecisionEntry?
    public var no: DecisionEntry?

    public init(yes: DecisionEntry? = nil, no: DecisionEntry? = nil) {
        self.yes = yes
        self.no = no
    }

    public static func == (lhs: YesNoCriteria, rhs: YesNoCriteria) -> Bool {
        CanonicalJSON.data(lhs) == CanonicalJSON.data(rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CanonicalJSON.data(self))
    }
}

/// One option of a `choice` question. Order is significant and frozen per policy.
public struct DecisionOption: Sendable, Codable, Hashable {
    public var id: String
    public var entry: DecisionEntry?

    public init(_ id: String, _ entry: DecisionEntry? = nil) {
        self.id = id
        self.entry = entry
    }

    public static func == (lhs: DecisionOption, rhs: DecisionOption) -> Bool {
        CanonicalJSON.data(lhs) == CanonicalJSON.data(rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CanonicalJSON.data(self))
    }
}

/// A closed question about the request's state (spec: `Question`). There is no extraction or generation kind.
public enum DecisionQuestion: Sendable, Codable, Hashable {
    case yesNo(instructions: DecisionEntry, criteria: YesNoCriteria? = nil)
    /// 2…255 options.
    case choice(instructions: DecisionEntry, options: [DecisionOption])
    /// 2…10 levels, ordered low → high.
    case score(instructions: DecisionEntry, levels: [DecisionEntry])
    /// Locate something in an image asset.
    case box(instructions: DecisionEntry)

    public var kind: DecisionQuestionKind {
        switch self {
        case .yesNo: return .yesNo
        case .choice: return .choice
        case .score: return .score
        case .box: return .box
        }
    }

    public var instructions: DecisionEntry {
        switch self {
        case .yesNo(let instructions, _), .choice(let instructions, _),
             .score(let instructions, _), .box(let instructions):
            return instructions
        }
    }

    public static func == (lhs: DecisionQuestion, rhs: DecisionQuestion) -> Bool {
        CanonicalJSON.data(lhs) == CanonicalJSON.data(rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CanonicalJSON.data(self))
    }
}

public enum DecisionQuestionKind: String, Sendable, Codable, Hashable, CaseIterable {
    case yesNo = "yes-no"
    case choice
    case score
    case box
}

/// A question keyed by the caller's id. Ids are not sent to the model in the reference dialect.
public struct DecisionQuestionItem: Sendable, Codable, Hashable {
    public var id: String
    public var question: DecisionQuestion

    public init(_ id: String, _ question: DecisionQuestion) {
        self.id = id
        self.question = question
    }
}

public enum DecisionRequestValidationError: Error, Sendable, Equatable {
    case noQuestions
    case emptyQuestionID
    case duplicateQuestionID(String)
    case optionCount(questionID: String, count: Int)
    case duplicateOptionID(questionID: String, optionID: String)
    case emptyOptionID(questionID: String)
    case levelCount(questionID: String, count: Int)
    case boxWithoutImageAsset(questionID: String)
}

/// Normalized `decide` request (spec: `DecisionRequest`). Keep evidence in ``state`` and judgments in ``questions``.
public struct DecisionRequest: Sendable, Codable, Hashable {
    public var state: JSON
    public var assets: [String: DecisionImageAsset]
    /// Ordered; codecs keep order and ids stable.
    public var questions: [DecisionQuestionItem]

    public init(state: JSON, assets: [String: DecisionImageAsset] = [:], questions: [DecisionQuestionItem]) {
        self.state = state
        self.assets = assets
        self.questions = questions
    }

    public var questionKinds: Set<DecisionQuestionKind> {
        Set(questions.map(\.question.kind))
    }

    public var maxOptionCount: Int {
        questions.map { item -> Int in
            if case .choice(_, let options) = item.question { return options.count }
            return 0
        }.max() ?? 0
    }

    /// `[min, max]` score level count across score questions, or `nil` when there are none.
    public var scoreLevelRange: ClosedRange<Int>? {
        let counts = questions.compactMap { item -> Int? in
            if case .score(_, let levels) = item.question { return levels.count }
            return nil
        }
        guard let low = counts.min(), let high = counts.max() else { return nil }
        return low...high
    }

    public func validate() throws {
        guard !questions.isEmpty else { throw DecisionRequestValidationError.noQuestions }
        var seen = Set<String>()
        for item in questions {
            guard !item.id.isEmpty else { throw DecisionRequestValidationError.emptyQuestionID }
            guard seen.insert(item.id).inserted else {
                throw DecisionRequestValidationError.duplicateQuestionID(item.id)
            }
            switch item.question {
            case .yesNo:
                break
            case .choice(_, let options):
                guard (2...255).contains(options.count) else {
                    throw DecisionRequestValidationError.optionCount(questionID: item.id, count: options.count)
                }
                var optionIDs = Set<String>()
                for option in options {
                    guard !option.id.isEmpty else {
                        throw DecisionRequestValidationError.emptyOptionID(questionID: item.id)
                    }
                    guard optionIDs.insert(option.id).inserted else {
                        throw DecisionRequestValidationError.duplicateOptionID(questionID: item.id, optionID: option.id)
                    }
                }
            case .score(_, let levels):
                guard (2...10).contains(levels.count) else {
                    throw DecisionRequestValidationError.levelCount(questionID: item.id, count: levels.count)
                }
            case .box:
                guard !assets.isEmpty else {
                    throw DecisionRequestValidationError.boxWithoutImageAsset(questionID: item.id)
                }
            }
        }
    }

    /// Stable hash input for the `(modelVersion, request hash)` response cache.
    public var canonicalData: Data {
        CanonicalJSON.data(self)
    }

    public static func == (lhs: DecisionRequest, rhs: DecisionRequest) -> Bool {
        lhs.canonicalData == rhs.canonicalData
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalData)
    }
}

/// Normalized bounding box, fractions of the image edge.
public struct DecisionBox: Sendable, Codable, Hashable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public enum DecisionUnavailableReason: String, Sendable, Codable, Hashable {
    case emulatedNoProbability = "emulated-no-probability"
    case missingInResponse = "missing-in-response"
    case invalidDistribution = "invalid-distribution"
}

/// A typed answer (spec: `Answer`). Typed answers keep the full distribution.
public enum DecisionAnswer: Sendable, Codable, Hashable {
    case yesNo(pYes: Double)
    case choice(choice: String, probabilities: [String: Double])
    /// `expected = Σ i·p_i` over zero-based levels.
    case score(expected: Double, probabilities: [Double])
    case box(DecisionBox, peak: Double?)
    /// The model declined this question. A refusal is an answer.
    case refusal(reason: String?)
    /// `advisoryLabel` carries the emulation schema rung's label. It is never a probability.
    case unavailable(reason: DecisionUnavailableReason, advisoryLabel: String? = nil)

    public var kind: String {
        switch self {
        case .yesNo: return DecisionQuestionKind.yesNo.rawValue
        case .choice: return DecisionQuestionKind.choice.rawValue
        case .score: return DecisionQuestionKind.score.rawValue
        case .box: return DecisionQuestionKind.box.rawValue
        case .refusal: return "refusal"
        case .unavailable: return "unavailable"
        }
    }
}

/// Usage for `decide` calls. Only input tokens are billed; output tokens are informational.
public struct DecisionUsage: Sendable, Codable, Hashable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }

    public static func + (lhs: DecisionUsage, rhs: DecisionUsage) -> DecisionUsage {
        func add(_ a: Int?, _ b: Int?) -> Int? {
            if a == nil && b == nil { return nil }
            return (a ?? 0) + (b ?? 0)
        }
        return DecisionUsage(
            inputTokens: add(lhs.inputTokens, rhs.inputTokens),
            outputTokens: add(lhs.outputTokens, rhs.outputTokens),
            cachedInputTokens: add(lhs.cachedInputTokens, rhs.cachedInputTokens)
        )
    }
}

/// Normalized `decide` result (spec: `DecisionResult`).
public struct DecisionResult: Sendable, Codable, Hashable {
    /// The versioned id that answered, never the alias.
    public var modelVersion: String
    /// `false` for LLM-emulated answers.
    public var calibrated: Bool
    /// Which guarantee rung produced the answers.
    public var guarantee: OutputGuarantee
    /// One answer per requested question id.
    public var answers: [String: DecisionAnswer]
    public var usage: DecisionUsage
    /// Vendor request ids (one per wire request when the codec split the questions).
    public var requestIDs: [String]

    public init(
        modelVersion: String,
        calibrated: Bool,
        guarantee: OutputGuarantee,
        answers: [String: DecisionAnswer],
        usage: DecisionUsage = DecisionUsage(),
        requestIDs: [String] = []
    ) {
        self.modelVersion = modelVersion
        self.calibrated = calibrated
        self.guarantee = guarantee
        self.answers = answers
        self.usage = usage
        self.requestIDs = requestIDs
    }

    public var requestID: String? {
        requestIDs.first
    }
}

/// Enforces "every requested id gets an answer" and distribution validity on raw codec output.
public enum DecisionAnswerValidator {
    public static let sumTolerance = 0.01

    /// Maps raw decoded answers onto the request: missing ids become `missing-in-response`, invalid distributions
    /// and kind mismatches become `invalid-distribution`, and ids the request did not ask about are dropped.
    public static func reconcile(
        request: DecisionRequest,
        raw: [String: DecisionAnswer]
    ) -> [String: DecisionAnswer] {
        var answers: [String: DecisionAnswer] = [:]
        for item in request.questions {
            guard let answer = raw[item.id] else {
                answers[item.id] = .unavailable(reason: .missingInResponse)
                continue
            }
            answers[item.id] = validate(answer, for: item.question)
        }
        return answers
    }

    public static func validate(_ answer: DecisionAnswer, for question: DecisionQuestion) -> DecisionAnswer {
        let invalid = DecisionAnswer.unavailable(reason: .invalidDistribution)
        switch (answer, question) {
        case (.refusal, _), (.unavailable, _):
            return answer
        case (.yesNo(let pYes), .yesNo):
            return isProbability(pYes) ? answer : invalid
        case (.choice(let choice, let probabilities), .choice(_, let options)):
            let optionIDs = Set(options.map(\.id))
            guard Set(probabilities.keys) == optionIDs,
                  isDistribution(Array(probabilities.values)),
                  let chosen = probabilities[choice],
                  let top = probabilities.values.max(),
                  chosen >= top
            else { return invalid }
            return answer
        case (.score(let expected, let probabilities), .score(_, let levels)):
            guard probabilities.count == levels.count,
                  isDistribution(probabilities),
                  expected.isFinite,
                  expected >= 0, expected <= Double(levels.count - 1)
            else { return invalid }
            return answer
        case (.box(let box, _), .box):
            let edges = [box.top, box.left, box.bottom, box.right]
            guard edges.allSatisfy(isProbability), box.top <= box.bottom, box.left <= box.right else { return invalid }
            return answer
        default:
            return invalid
        }
    }

    static func isProbability(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1
    }

    static func isDistribution(_ values: [Double]) -> Bool {
        guard !values.isEmpty, values.allSatisfy(isProbability) else { return false }
        return abs(values.reduce(0, +) - 1) <= sumTolerance
    }

    /// `Σ i·p_i` over zero-based levels.
    public static func expectedLevel(_ probabilities: [Double]) -> Double {
        probabilities.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
    }
}
