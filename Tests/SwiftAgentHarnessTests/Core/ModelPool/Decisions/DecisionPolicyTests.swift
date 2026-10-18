import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Decision signals")
struct DecisionSignalsTests {
    private func result(_ answers: [String: DecisionAnswer], calibrated: Bool = true, version: String = "v1") -> DecisionResult {
        DecisionResult(modelVersion: version, calibrated: calibrated, guarantee: calibrated ? .calibratedDistribution : .logprobs, answers: answers)
    }

    @Test("Yes-no signals use p = P(yes) and margin = |2p − 1|")
    func yesNo() {
        let signals = DecisionSignals.compute(.yesNo(pYes: 0.8))
        guard case .probability(let p, let margin) = signals else { Issue.record("expected probability"); return }
        #expect(p == 0.8)
        #expect(abs(margin - 0.6) < 1e-12)
    }

    @Test("Choice signals use top-1 and top-1 minus top-2, not vendor confidence")
    func choice() {
        // (0.6, 0.3, 0.1) and (0.6, 0.2, 0.2) share a chance-normalized vendor confidence but differ in margin.
        let a = DecisionSignals.compute(.choice(choice: "x", probabilities: ["x": 0.6, "y": 0.3, "z": 0.1]))
        let b = DecisionSignals.compute(.choice(choice: "x", probabilities: ["x": 0.6, "y": 0.2, "z": 0.2]))
        #expect(a.p == 0.6)
        #expect(abs(a.margin! - 0.3) < 1e-12)
        #expect(abs(b.margin! - 0.4) < 1e-12)
    }

    @Test("Score signals compute expected level and spread")
    func score() {
        let signals = DecisionSignals.compute(.score(expected: 1.0, probabilities: [0.25, 0.5, 0.25]))
        #expect(signals.expected == 1.0)
        #expect(abs(signals.spread! - 0.5.squareRoot()) < 1e-12)
    }

    @Test("Refusal, unavailable, and box answers have no signal")
    func noSignal() {
        #expect(DecisionSignals.compute(.refusal(reason: nil)) == .unavailable)
        #expect(DecisionSignals.compute(.unavailable(reason: .missingInResponse)) == .unavailable)
        #expect(DecisionSignals.compute(.box(DecisionBox(top: 0, left: 0, bottom: 1, right: 1), peak: nil)) == .unavailable)
    }

    @Test("Uncalibrated results are unavailable unless the policy is tuned on that exact emulator and accepts it")
    func uncalibratedGate() {
        let uncalibrated = result(["safe": .yesNo(pYes: 0.99)], calibrated: false, version: "chat-1")
        let strict = DecisionFixtures.gatePolicy(versions: ["chat-1"])
        let accepting = DecisionFixtures.gatePolicy(versions: ["chat-1"], acceptsUncalibrated: true)
        let acceptingOther = DecisionFixtures.gatePolicy(versions: ["other"], acceptsUncalibrated: true)
        #expect(DecisionSignals.compute(.yesNo(pYes: 0.99), result: uncalibrated, policy: strict) == .unavailable)
        #expect(DecisionSignals.compute(.yesNo(pYes: 0.99), result: uncalibrated, policy: acceptingOther) == .unavailable)
        #expect(DecisionSignals.compute(.yesNo(pYes: 0.99), result: uncalibrated, policy: accepting).p == 0.99)
    }
}

@Suite("Decision policy")
struct DecisionPolicyTests {
    private func result(_ pYes: Double, version: String = "v1", calibrated: Bool = true) -> DecisionResult {
        DecisionResult(
            modelVersion: version, calibrated: calibrated,
            guarantee: calibrated ? .calibratedDistribution : .logprobs,
            answers: ["safe": .yesNo(pYes: pYes)]
        )
    }

    @Test("Bands map probabilities to refuse, confirm, act")
    func bands() {
        let policy = DecisionFixtures.gatePolicy(versions: ["v1"])
        #expect(policy.evaluate(result(0.95)).verdict == .act)
        #expect(policy.evaluate(result(0.9)).verdict == .act)
        #expect(policy.evaluate(result(0.7)).verdict == .confirm)
        #expect(policy.evaluate(result(0.5)).verdict == .confirm)
        #expect(policy.evaluate(result(0.2)).verdict == .refuse)
        let evaluation = policy.evaluate(result(0.95))
        #expect(evaluation.reason == .band(.act))
        #expect(evaluation.value == 0.95)
        #expect(evaluation.modelVersion == "v1")
    }

    @Test("A value in a range gap resolves to onUnavailable, never act")
    func rangeGap() {
        let policy = DecisionPolicy(
            question: "safe",
            bands: ["v1": .ranges(refuse: DecisionRange(0, 0.2), act: DecisionRange(0.95, 1))],
            onUnavailable: .refuse
        )
        let evaluation = policy.evaluate(result(0.5))
        #expect(evaluation.verdict == .refuse)
        #expect(evaluation.reason == .rangeGap)
    }

    @Test("Answers from a version with no bands are untuned and conservative")
    func untunedVersion() {
        let policy = DecisionFixtures.gatePolicy(versions: ["v1"])
        let evaluation = policy.evaluate(result(0.99, version: "v2"))
        #expect(evaluation.verdict == .confirm)
        #expect(evaluation.reason == .untunedVersion)
    }

    @Test("Uncalibrated answers resolve to onUnavailable")
    func uncalibrated() {
        let policy = DecisionFixtures.gatePolicy(versions: ["chat-1"])
        let evaluation = policy.evaluate(result(0.99, version: "chat-1", calibrated: false))
        #expect(evaluation.verdict == .confirm)
        #expect(evaluation.reason == .uncalibrated)
        let accepting = DecisionFixtures.gatePolicy(versions: ["chat-1"], acceptsUncalibrated: true)
        #expect(accepting.evaluate(result(0.99, version: "chat-1", calibrated: false)).verdict == .act)
    }

    @Test("Refusals, missing answers, and errors take their conservative defaults")
    func conservativeDefaults() {
        var policy = DecisionFixtures.gatePolicy(versions: ["v1"])
        policy.onRefusal = .refuse
        policy.onError = .refuse
        let refused = DecisionResult(modelVersion: "v1", calibrated: true, guarantee: .calibratedDistribution, answers: ["safe": .refusal(reason: "no")])
        #expect(policy.evaluate(refused).verdict == .refuse)
        #expect(policy.evaluate(refused).reason == .refused)
        let missing = DecisionResult(modelVersion: "v1", calibrated: true, guarantee: .calibratedDistribution, answers: [:])
        #expect(policy.evaluate(missing).verdict == .confirm)
        #expect(policy.evaluate(missing).reason == .missingAnswer)
        let unavailable = DecisionResult(modelVersion: "v1", calibrated: true, guarantee: .calibratedDistribution, answers: ["safe": .unavailable(reason: .invalidDistribution)])
        #expect(policy.evaluate(unavailable).reason == .unavailableAnswer)
        #expect(policy.evaluateFailure().verdict == .refuse)
        #expect(policy.evaluateFailure().reason == .error)
    }

    @Test("Margin axis tests the margin instead of p")
    func marginAxis() {
        let policy = DecisionPolicy(
            question: "route",
            on: .margin,
            bands: ["v1": .ranges(confirm: DecisionRange(0, 0.3, upperOpen: true), act: DecisionRange(0.3, 1))]
        )
        let close = DecisionResult(modelVersion: "v1", calibrated: true, guarantee: .calibratedDistribution,
                                   answers: ["route": .choice(choice: "a", probabilities: ["a": 0.5, "b": 0.4, "c": 0.1])])
        let clear = DecisionResult(modelVersion: "v1", calibrated: true, guarantee: .calibratedDistribution,
                                   answers: ["route": .choice(choice: "a", probabilities: ["a": 0.8, "b": 0.1, "c": 0.1])])
        #expect(policy.evaluate(close).verdict == .confirm)
        #expect(policy.evaluate(clear).verdict == .act)
    }

    @Test("Score bands give a verdict per rounded expected level")
    func scoreLevels() {
        let policy = DecisionPolicy(question: "severity", bands: ["v1": .levels([.act, .confirm, .refuse])])
        func scored(_ expected: Double) -> DecisionResult {
            DecisionResult(modelVersion: "v1", calibrated: true, guarantee: .calibratedDistribution,
                           answers: ["severity": .score(expected: expected, probabilities: [0.2, 0.3, 0.5])])
        }
        #expect(policy.evaluate(scored(0.2)).verdict == .act)
        #expect(policy.evaluate(scored(1.4)).verdict == .confirm)
        #expect(policy.evaluate(scored(1.6)).verdict == .refuse)
        let short = DecisionPolicy(question: "severity", bands: ["v1": .levels([.act])])
        #expect(short.evaluate(scored(1.6)).reason == .rangeGap)
    }

    @Test("Load-time validation rejects overlapping and inverted ranges")
    func validation() throws {
        try DecisionFixtures.gatePolicy(versions: ["v1"]).validate()
        let overlapping = DecisionPolicy(question: "q", bands: ["v1": .ranges(confirm: DecisionRange(0.4, 0.8), act: DecisionRange(0.8, 1))])
        #expect(throws: DecisionPolicyValidationError.overlappingRanges(modelVersion: "v1")) { try overlapping.validate() }
        let touchingOpen = DecisionPolicy(question: "q", bands: ["v1": .ranges(confirm: DecisionRange(0.4, 0.8, upperOpen: true), act: DecisionRange(0.8, 1))])
        try touchingOpen.validate()
        let inverted = DecisionPolicy(question: "q", bands: ["v1": .ranges(act: DecisionRange(0.9, 0.1))])
        #expect(throws: DecisionPolicyValidationError.invertedRange(modelVersion: "v1")) { try inverted.validate() }
        let emptyLevels = DecisionPolicy(question: "q", bands: ["v1": .levels([])])
        #expect(throws: DecisionPolicyValidationError.emptyScoreLevels(modelVersion: "v1")) { try emptyLevels.validate() }
        let acceptsWithoutBands = DecisionPolicy(question: "q", bands: [:], acceptsUncalibrated: true)
        #expect(throws: DecisionPolicyValidationError.acceptsUncalibratedWithoutBands) { try acceptsWithoutBands.validate() }
    }

    @Test("Ranges treat non-finite values as outside")
    func rangeContains() {
        let range = DecisionRange(0, 1)
        #expect(range.contains(0))
        #expect(range.contains(1))
        #expect(!range.contains(.nan))
        #expect(!range.contains(.infinity))
        #expect(!DecisionRange(0, 1, lowerOpen: true).contains(0))
        #expect(!DecisionRange(0, 1, upperOpen: true).contains(1))
    }

    @Test("Policies round-trip through Codable")
    func codable() throws {
        let policy = DecisionFixtures.gatePolicy(
            versions: ["v1", "v2"],
            escalate: DecisionEscalation(to: "big", when: .any([.pBetween(0.4, 0.9), .refused()]))
        )
        let decoded = try JSONDecoder().decode(DecisionPolicy.self, from: JSONEncoder().encode(policy))
        #expect(decoded == policy)
    }
}

@Suite("Deferral conditions")
struct DeferralConditionTests {
    private func result(_ answers: [String: DecisionAnswer], calibrated: Bool = true) -> DecisionResult {
        DecisionResult(modelVersion: "v1", calibrated: calibrated, guarantee: .calibratedDistribution, answers: answers)
    }

    @Test("Probability, margin, band, and spread conditions test computed signals")
    func signalConditions() {
        let r = result(["safe": .yesNo(pYes: 0.6), "sev": .score(expected: 1, probabilities: [0.3, 0.4, 0.3])])
        #expect(DeferralCondition.pBelow(0.7, question: "safe").matches(r))
        #expect(!DeferralCondition.pBelow(0.5, question: "safe").matches(r))
        #expect(DeferralCondition.marginBelow(0.5, question: "safe").matches(r))
        #expect(DeferralCondition.pBetween(0.4, 0.8, question: "safe").matches(r))
        #expect(!DeferralCondition.pBetween(0.7, 0.8, question: "safe").matches(r))
        #expect(DeferralCondition.spreadAbove(0.5, question: "sev").matches(r))
        #expect(!DeferralCondition.spreadAbove(0.9, question: "sev").matches(r))
    }

    @Test("Without a question the default question is used; with neither, any question can match")
    func questionScope() {
        let r = result(["a": .yesNo(pYes: 0.99), "b": .yesNo(pYes: 0.1)])
        #expect(!DeferralCondition.pBelow(0.5).matches(r, defaultQuestion: "a"))
        #expect(DeferralCondition.pBelow(0.5).matches(r))
    }

    @Test("Missing, non-finite, or uncalibrated signals count as a match")
    func conservativeReading() {
        #expect(DeferralCondition.pBelow(0.5, question: "missing").matches(result([:])))
        #expect(DeferralCondition.pBelow(0.5, question: "q").matches(result(["q": .unavailable(reason: .missingInResponse)])))
        #expect(DeferralCondition.spreadAbove(9, question: "q").matches(result(["q": .yesNo(pYes: 0.9)])))
        #expect(DeferralCondition.pBelow(0.5, question: "q").matches(result(["q": .yesNo(pYes: 0.99)], calibrated: false)))
    }

    @Test("Refused and unavailable conditions match their answer kinds")
    func refusedAndUnavailable() {
        #expect(DeferralCondition.refused(question: "q").matches(result(["q": .refusal(reason: nil)])))
        #expect(!DeferralCondition.refused(question: "q").matches(result(["q": .yesNo(pYes: 0.5)])))
        #expect(DeferralCondition.unavailable(question: "q").matches(result(["q": .unavailable(reason: .invalidDistribution)])))
        #expect(DeferralCondition.unavailable(question: "q").matches(result(["q": .yesNo(pYes: 0.5)], calibrated: false)))
        #expect(!DeferralCondition.unavailable(question: "q").matches(result(["q": .yesNo(pYes: 0.5)])))
    }

    @Test("any / all combine conditions")
    func combinators() {
        let r = result(["q": .yesNo(pYes: 0.6)])
        #expect(DeferralCondition.any([.pBelow(0.1, question: "q"), .pBelow(0.7, question: "q")]).matches(r))
        #expect(!DeferralCondition.all([.pBelow(0.1, question: "q"), .pBelow(0.7, question: "q")]).matches(r))
        #expect(DeferralCondition.all([.pBelow(0.9, question: "q"), .pBelow(0.7, question: "q")]).matches(r))
        #expect(!DeferralCondition.all([]).matches(r))
    }
}
