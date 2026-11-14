import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Decision request and answer types")
struct DecisionTypesTests {
    @Test("Request validation enforces ids, option counts, level counts, and image assets for box")
    func validation() throws {
        try DecisionFixtures.yesNoRequest(["a", "b"]).validate()
        #expect(throws: DecisionRequestValidationError.noQuestions) {
            try DecisionRequest(state: .string("s"), questions: []).validate()
        }
        #expect(throws: DecisionRequestValidationError.duplicateQuestionID("a")) {
            try DecisionFixtures.yesNoRequest(["a", "a"]).validate()
        }
        #expect(throws: DecisionRequestValidationError.emptyQuestionID) {
            try DecisionFixtures.yesNoRequest([""]).validate()
        }
        let oneOption = DecisionRequest(state: .string("s"), questions: [
            DecisionQuestionItem("c", .choice(instructions: .string("?"), options: [DecisionOption("only")])),
        ])
        #expect(throws: DecisionRequestValidationError.optionCount(questionID: "c", count: 1)) { try oneOption.validate() }
        let tooManyOptions = DecisionRequest(state: .string("s"), questions: [
            DecisionQuestionItem("c", .choice(instructions: .string("?"), options: (0..<256).map { DecisionOption("o\($0)") })),
        ])
        #expect(throws: DecisionRequestValidationError.optionCount(questionID: "c", count: 256)) { try tooManyOptions.validate() }
        let dupOption = DecisionRequest(state: .string("s"), questions: [
            DecisionQuestionItem("c", .choice(instructions: .string("?"), options: [DecisionOption("x"), DecisionOption("x")])),
        ])
        #expect(throws: DecisionRequestValidationError.duplicateOptionID(questionID: "c", optionID: "x")) { try dupOption.validate() }
        let elevenLevels = DecisionRequest(state: .string("s"), questions: [
            DecisionQuestionItem("s", .score(instructions: .string("?"), levels: (0..<11).map { .string("\($0)") })),
        ])
        #expect(throws: DecisionRequestValidationError.levelCount(questionID: "s", count: 11)) { try elevenLevels.validate() }
        let boxNoImage = DecisionRequest(state: .string("s"), questions: [DecisionQuestionItem("b", .box(instructions: .string("find")))])
        #expect(throws: DecisionRequestValidationError.boxWithoutImageAsset(questionID: "b")) { try boxNoImage.validate() }
    }

    @Test("Requests summarize kinds, options, and score levels for the hard filter")
    func summaries() {
        let request = DecisionRequest(state: .string("s"), questions: [
            DecisionQuestionItem("y", .yesNo(instructions: .string("?"))),
            DecisionQuestionItem("c", .choice(instructions: .string("?"), options: [DecisionOption("a"), DecisionOption("b"), DecisionOption("c")])),
            DecisionQuestionItem("s", .score(instructions: .string("?"), levels: [.string("lo"), .string("hi")])),
        ])
        #expect(request.questionKinds == [.yesNo, .choice, .score])
        #expect(request.maxOptionCount == 3)
        #expect(request.scoreLevelRange == 2...2)
        #expect(DecisionFixtures.yesNoRequest().scoreLevelRange == nil)
    }

    @Test("Canonical data is independent of object key order")
    func canonicalHash() {
        let a = DecisionRequest(state: .object(["x": .integer(1), "y": .string("z")]), questions: DecisionFixtures.yesNoRequest().questions)
        let b = DecisionRequest(state: .object(["y": .string("z"), "x": .integer(1)]), questions: DecisionFixtures.yesNoRequest().questions)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != DecisionFixtures.yesNoRequest())
    }

    @Test("Every requested id gets an answer; missing ids become missing-in-response")
    func reconcileMissing() {
        let request = DecisionFixtures.yesNoRequest(["a", "b"])
        let answers = DecisionAnswerValidator.reconcile(request: request, raw: ["a": .yesNo(pYes: 0.3), "extra": .yesNo(pYes: 1)])
        #expect(answers["a"] == .yesNo(pYes: 0.3))
        #expect(answers["b"] == .unavailable(reason: .missingInResponse))
        #expect(answers["extra"] == nil)
    }

    @Test("Invalid distributions are never renormalized")
    func invalidDistributions() {
        let choice = DecisionQuestion.choice(instructions: .string("?"), options: [DecisionOption("a"), DecisionOption("b")])
        let invalid = DecisionAnswer.unavailable(reason: .invalidDistribution)
        #expect(DecisionAnswerValidator.validate(.choice(choice: "a", probabilities: ["a": 0.8, "b": 0.5]), for: choice) == invalid)
        #expect(DecisionAnswerValidator.validate(.choice(choice: "b", probabilities: ["a": 0.8, "b": 0.2]), for: choice) == invalid)
        #expect(DecisionAnswerValidator.validate(.choice(choice: "a", probabilities: ["a": 1.0]), for: choice) == invalid)
        #expect(DecisionAnswerValidator.validate(.choice(choice: "a", probabilities: ["a": .nan, "b": 0.5]), for: choice) == invalid)
        #expect(DecisionAnswerValidator.validate(.choice(choice: "a", probabilities: ["a": 0.805, "b": 0.2]), for: choice)
            == .choice(choice: "a", probabilities: ["a": 0.805, "b": 0.2]))

        let yesNo = DecisionQuestion.yesNo(instructions: .string("?"))
        #expect(DecisionAnswerValidator.validate(.yesNo(pYes: 1.3), for: yesNo) == invalid)
        #expect(DecisionAnswerValidator.validate(.yesNo(pYes: -0.1), for: yesNo) == invalid)
        #expect(DecisionAnswerValidator.validate(.yesNo(pYes: 0.4), for: yesNo) == .yesNo(pYes: 0.4))

        let score = DecisionQuestion.score(instructions: .string("?"), levels: [.string("0"), .string("1"), .string("2")])
        #expect(DecisionAnswerValidator.validate(.score(expected: 1, probabilities: [0.5, 0.5]), for: score) == invalid)
        #expect(DecisionAnswerValidator.validate(.score(expected: 3, probabilities: [0.2, 0.3, 0.5]), for: score) == invalid)
        #expect(DecisionAnswerValidator.validate(.score(expected: 1.3, probabilities: [0.2, 0.3, 0.5]), for: score)
            == .score(expected: 1.3, probabilities: [0.2, 0.3, 0.5]))

        let box = DecisionQuestion.box(instructions: .string("?"))
        #expect(DecisionAnswerValidator.validate(.box(DecisionBox(top: 0.6, left: 0, bottom: 0.4, right: 1), peak: nil), for: box) == invalid)
    }

    @Test("Kind mismatches are invalid; refusals and unavailable answers pass through")
    func kindMismatch() {
        let yesNo = DecisionQuestion.yesNo(instructions: .string("?"))
        #expect(DecisionAnswerValidator.validate(.score(expected: 0, probabilities: [1, 0]), for: yesNo)
            == .unavailable(reason: .invalidDistribution))
        #expect(DecisionAnswerValidator.validate(.refusal(reason: "policy"), for: yesNo) == .refusal(reason: "policy"))
        #expect(DecisionAnswerValidator.validate(.unavailable(reason: .emulatedNoProbability, advisoryLabel: "yes"), for: yesNo)
            == .unavailable(reason: .emulatedNoProbability, advisoryLabel: "yes"))
    }

    @Test("Usage adds and keeps nil when both sides are unknown")
    func usageAddition() {
        let sum = DecisionUsage(inputTokens: 10, outputTokens: nil) + DecisionUsage(inputTokens: 5, outputTokens: nil, cachedInputTokens: 2)
        #expect(sum.inputTokens == 15)
        #expect(sum.outputTokens == nil)
        #expect(sum.cachedInputTokens == 2)
    }

    @Test("Expected level is Σ i·p_i")
    func expectedLevel() {
        #expect(abs(DecisionAnswerValidator.expectedLevel([0.2, 0.3, 0.5]) - 1.3) < 1e-12)
    }
}
