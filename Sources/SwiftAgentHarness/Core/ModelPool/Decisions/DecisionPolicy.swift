import Foundation

/// Signals the harness derives from a distribution itself; vendor `confidence` fields are never used (spec: `Signals`).
public enum DecisionSignals: Sendable, Equatable {
    /// yes-no: `p = P(yes)`; choice: `p` = top-1 probability. `margin` = top-1 − top-2 (yes-no: `|2p − 1|`).
    case probability(p: Double, margin: Double)
    /// Score: expected level and standard deviation over the level distribution.
    case score(expected: Double, spread: Double)
    case unavailable

    /// Computes signals for one answer. Uncalibrated results carry no usable probability unless the policy
    /// accepts uncalibrated answers *and* has bands tuned for that exact emulating version.
    public static func compute(
        _ answer: DecisionAnswer,
        result: DecisionResult,
        policy: DecisionPolicy
    ) -> DecisionSignals {
        if !result.calibrated && !(policy.acceptsUncalibrated && policy.bands[result.modelVersion] != nil) {
            return .unavailable
        }
        return compute(answer)
    }

    /// Signals from the distribution alone, without the calibration gate.
    public static func compute(_ answer: DecisionAnswer) -> DecisionSignals {
        switch answer {
        case .yesNo(let pYes):
            return .probability(p: pYes, margin: abs(2 * pYes - 1))
        case .choice(_, let probabilities):
            let sorted = probabilities.values.sorted(by: >)
            guard let top = sorted.first else { return .unavailable }
            return .probability(p: top, margin: top - (sorted.dropFirst().first ?? 0))
        case .score(let expected, let probabilities):
            let variance = probabilities.enumerated().reduce(0.0) { sum, item in
                sum + item.element * pow(Double(item.offset) - expected, 2)
            }
            return .score(expected: expected, spread: variance.squareRoot())
        case .box, .refusal, .unavailable:
            return .unavailable
        }
    }

    var p: Double? {
        if case .probability(let p, _) = self { return p }
        return nil
    }

    var margin: Double? {
        if case .probability(_, let margin) = self { return margin }
        return nil
    }

    var expected: Double? {
        if case .score(let expected, _) = self { return expected }
        return nil
    }

    var spread: Double? {
        if case .score(_, let spread) = self { return spread }
        return nil
    }
}

/// A probability interval. Bounds are inclusive unless marked open.
public struct DecisionRange: Sendable, Codable, Hashable {
    public var lower: Double
    public var upper: Double
    public var lowerOpen: Bool
    public var upperOpen: Bool

    public init(_ lower: Double, _ upper: Double, lowerOpen: Bool = false, upperOpen: Bool = false) {
        self.lower = lower
        self.upper = upper
        self.lowerOpen = lowerOpen
        self.upperOpen = upperOpen
    }

    public func contains(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        let aboveLower = lowerOpen ? value > lower : value >= lower
        let belowUpper = upperOpen ? value < upper : value <= upper
        return aboveLower && belowUpper
    }

    func overlaps(_ other: DecisionRange) -> Bool {
        if upper < other.lower || other.upper < lower { return false }
        if upper == other.lower { return !(upperOpen || other.lowerOpen) }
        if other.upper == lower { return !(other.upperOpen || lowerOpen) }
        return true
    }
}

/// What the harness does with an answer.
public enum DecisionVerdict: String, Sendable, Codable, Hashable {
    case act
    case confirm
    case refuse
}

/// Conservative verdicts only. There is deliberately no fail-open value.
public enum DecisionConservativeVerdict: String, Sendable, Codable, Hashable {
    case confirm
    case refuse

    public var verdict: DecisionVerdict {
        switch self {
        case .confirm: return .confirm
        case .refuse: return .refuse
        }
    }
}

/// Act / confirm / refuse bands for one model version (spec: `Bands`).
public enum DecisionBands: Sendable, Codable, Hashable {
    /// Ranges on `p` (yes-no / choice) or `margin`, per ``DecisionPolicy/on``.
    case ranges(refuse: DecisionRange? = nil, confirm: DecisionRange? = nil, act: DecisionRange? = nil)
    /// Score: verdict per rounded expected level.
    case levels([DecisionVerdict])
}

/// Which signal ranges test.
public enum DecisionSignalAxis: String, Sendable, Codable, Hashable {
    case p
    case margin
}

/// Condition under which a cascade escalates (spec: `DeferralCondition`). Tested on computed signals only.
public indirect enum DeferralCondition: Sendable, Codable, Hashable {
    case pBelow(Double, question: String? = nil)
    case marginBelow(Double, question: String? = nil)
    /// Ambiguous band for yes-no.
    case pBetween(Double, Double, question: String? = nil)
    case spreadAbove(Double, question: String? = nil)
    case refused(question: String? = nil)
    case unavailable(question: String? = nil)
    case any([DeferralCondition])
    case all([DeferralCondition])

    /// Whether `result` should escalate. A missing or non-finite signal counts as a match (the conservative reading).
    /// Without an explicit question the condition applies to `defaultQuestion`; with neither, to every question.
    public func matches(_ result: DecisionResult, defaultQuestion: String? = nil) -> Bool {
        switch self {
        case .any(let conditions):
            return conditions.contains { $0.matches(result, defaultQuestion: defaultQuestion) }
        case .all(let conditions):
            return !conditions.isEmpty && conditions.allSatisfy { $0.matches(result, defaultQuestion: defaultQuestion) }
        case .pBelow(let threshold, let question):
            return test(result, question ?? defaultQuestion) { signals in
                signals.p.map { $0 < threshold }
            }
        case .marginBelow(let threshold, let question):
            return test(result, question ?? defaultQuestion) { signals in
                signals.margin.map { $0 < threshold }
            }
        case .pBetween(let low, let high, let question):
            return test(result, question ?? defaultQuestion) { signals in
                signals.p.map { $0 >= low && $0 <= high }
            }
        case .spreadAbove(let threshold, let question):
            return test(result, question ?? defaultQuestion) { signals in
                signals.spread.map { $0 > threshold }
            }
        case .refused(let question):
            return answers(result, question ?? defaultQuestion).contains {
                if case .refusal = $0 { return true }
                return false
            }
        case .unavailable(let question):
            if !result.calibrated { return true }
            return answers(result, question ?? defaultQuestion).contains {
                if case .unavailable = $0 { return true }
                return false
            }
        }
    }

    private func answers(_ result: DecisionResult, _ question: String?) -> [DecisionAnswer?] {
        if let question { return [result.answers[question]] }
        return result.answers.keys.sorted().map { result.answers[$0] }
    }

    /// Uncalibrated answers have no usable signal, so they count as missing.
    private func test(
        _ result: DecisionResult,
        _ question: String?,
        _ predicate: (DecisionSignals) -> Bool?
    ) -> Bool {
        answers(result, question).contains { answer in
            guard let answer, result.calibrated else { return true }
            let signals = DecisionSignals.compute(answer)
            guard let outcome = predicate(signals) else { return true }
            return outcome
        }
    }
}

/// One escalation stage, declared on the consuming policy (spec: `DecisionPolicy.escalate`).
public struct DecisionEscalation: Sendable, Codable, Hashable {
    /// Model id or slug of the escalation target.
    public var to: String
    public var when: DeferralCondition

    public init(to: String, when: DeferralCondition) {
        self.to = to
        self.when = when
    }
}

public enum DecisionPolicyValidationError: Error, Sendable, Equatable {
    case overlappingRanges(modelVersion: String)
    case invertedRange(modelVersion: String)
    case emptyScoreLevels(modelVersion: String)
    case acceptsUncalibratedWithoutBands
}

/// Thresholds and conservative defaults for one question (spec: `DecisionPolicy`).
public struct DecisionPolicy: Sendable, Codable, Hashable {
    public var question: String
    public var on: DecisionSignalAxis
    /// Keyed by the version that answered: primary, escalation target, and every fallback.
    public var bands: [String: DecisionBands]
    /// Only meaningful with bands tuned for that exact emulating version.
    public var acceptsUncalibrated: Bool
    /// Also used for untuned versions and range gaps. Never `act`.
    public var onUnavailable: DecisionConservativeVerdict
    public var onRefusal: DecisionConservativeVerdict
    /// Gates fail closed.
    public var onError: DecisionConservativeVerdict
    public var escalate: DecisionEscalation?

    public init(
        question: String,
        on: DecisionSignalAxis = .p,
        bands: [String: DecisionBands],
        acceptsUncalibrated: Bool = false,
        onUnavailable: DecisionConservativeVerdict = .confirm,
        onRefusal: DecisionConservativeVerdict = .confirm,
        onError: DecisionConservativeVerdict = .confirm,
        escalate: DecisionEscalation? = nil
    ) {
        self.question = question
        self.on = on
        self.bands = bands
        self.acceptsUncalibrated = acceptsUncalibrated
        self.onUnavailable = onUnavailable
        self.onRefusal = onRefusal
        self.onError = onError
        self.escalate = escalate
    }

    /// Load-time validation: ranges must be well-formed and disjoint, so a misconfigured policy can over-ask
    /// but never over-act.
    public func validate() throws {
        if acceptsUncalibrated && bands.isEmpty {
            throw DecisionPolicyValidationError.acceptsUncalibratedWithoutBands
        }
        for (version, band) in bands {
            switch band {
            case .ranges(let refuse, let confirm, let act):
                let ranges = [refuse, confirm, act].compactMap { $0 }
                if ranges.contains(where: { $0.lower > $0.upper }) {
                    throw DecisionPolicyValidationError.invertedRange(modelVersion: version)
                }
                for i in ranges.indices {
                    for j in ranges.indices where j > i && ranges[i].overlaps(ranges[j]) {
                        throw DecisionPolicyValidationError.overlappingRanges(modelVersion: version)
                    }
                }
            case .levels(let levels):
                if levels.isEmpty { throw DecisionPolicyValidationError.emptyScoreLevels(modelVersion: version) }
            }
        }
    }

    /// Model versions this policy is tuned for; a threshold-bearing role may only fall back among these.
    public var tunedVersions: Set<String> {
        Set(bands.keys)
    }

    /// Turns one result into a verdict. Evaluation order is conservative: refuse, then confirm, then act.
    public func evaluate(_ result: DecisionResult) -> DecisionEvaluation {
        let version = result.modelVersion
        guard let answer = result.answers[question] else {
            return DecisionEvaluation(verdict: onUnavailable.verdict, reason: .missingAnswer, modelVersion: version)
        }
        if case .refusal = answer {
            return DecisionEvaluation(verdict: onRefusal.verdict, reason: .refused, modelVersion: version)
        }
        let signals = DecisionSignals.compute(answer, result: result, policy: self)
        if signals == .unavailable {
            let reason: DecisionEvaluation.Reason = result.calibrated ? .unavailableAnswer : .uncalibrated
            return DecisionEvaluation(verdict: onUnavailable.verdict, reason: reason, modelVersion: version)
        }
        guard let band = bands[version] else {
            return DecisionEvaluation(
                verdict: onUnavailable.verdict, reason: .untunedVersion, modelVersion: version, signals: signals
            )
        }
        switch band {
        case .ranges(let refuse, let confirm, let act):
            let value: Double?
            switch on {
            case .p: value = signals.p
            case .margin: value = signals.margin
            }
            guard let value, value.isFinite else {
                return DecisionEvaluation(
                    verdict: onUnavailable.verdict, reason: .unavailableAnswer, modelVersion: version, signals: signals
                )
            }
            for (verdict, range) in [(DecisionVerdict.refuse, refuse), (.confirm, confirm), (.act, act)] {
                if let range, range.contains(value) {
                    return DecisionEvaluation(
                        verdict: verdict, reason: .band(verdict), modelVersion: version, signals: signals, value: value
                    )
                }
            }
            return DecisionEvaluation(
                verdict: onUnavailable.verdict, reason: .rangeGap, modelVersion: version, signals: signals, value: value
            )
        case .levels(let levels):
            guard let expected = signals.expected, expected.isFinite else {
                return DecisionEvaluation(
                    verdict: onUnavailable.verdict, reason: .unavailableAnswer, modelVersion: version, signals: signals
                )
            }
            let level = Int(expected.rounded())
            guard levels.indices.contains(level) else {
                return DecisionEvaluation(
                    verdict: onUnavailable.verdict, reason: .rangeGap, modelVersion: version,
                    signals: signals, value: expected
                )
            }
            let verdict = levels[level]
            return DecisionEvaluation(
                verdict: verdict, reason: .band(verdict), modelVersion: version, signals: signals, value: expected
            )
        }
    }

    /// Verdict when the call failed outright (timeout, 5xx, no candidate). Never `act`.
    public func evaluateFailure() -> DecisionEvaluation {
        DecisionEvaluation(verdict: onError.verdict, reason: .error, modelVersion: nil)
    }
}

/// A verdict plus why, for receipts and "why was this approved" explanations.
public struct DecisionEvaluation: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case band(DecisionVerdict)
        case rangeGap
        case untunedVersion
        case uncalibrated
        case unavailableAnswer
        case missingAnswer
        case refused
        case error
    }

    public var verdict: DecisionVerdict
    public var reason: Reason
    public var modelVersion: String?
    public var signals: DecisionSignals?
    /// The signal value tested against the bands, when one was.
    public var value: Double?

    public init(
        verdict: DecisionVerdict,
        reason: Reason,
        modelVersion: String?,
        signals: DecisionSignals? = nil,
        value: Double? = nil
    ) {
        self.verdict = verdict
        self.reason = reason
        self.modelVersion = modelVersion
        self.signals = signals
        self.value = value
    }
}
