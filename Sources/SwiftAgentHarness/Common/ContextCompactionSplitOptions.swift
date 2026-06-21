import Foundation

public struct ContextCompactionSplitOptions: Sendable, Equatable {
    public var headMinMessageCount: Int
    public var tailMinMessageCount: Int
    public var tailTokenBudget: Int
    public var charactersPerToken: Double

    public init(
        headMinMessageCount: Int = 3,
        tailMinMessageCount: Int = 6,
        tailTokenBudget: Int = 33_400,
        charactersPerToken: Double = 4.0
    ) {
        self.headMinMessageCount = max(0, headMinMessageCount)
        self.tailMinMessageCount = max(0, tailMinMessageCount)
        self.tailTokenBudget = max(1, tailTokenBudget)
        self.charactersPerToken = max(0.5, charactersPerToken)
    }

    public static func specDefaults(
        proactiveThresholdTokens: Int,
        charactersPerToken: Double = 4.0,
        tailTokenBudgetFraction: Double = 0.2
    ) -> ContextCompactionSplitOptions {
        let fraction = max(0, min(1, tailTokenBudgetFraction))
        return ContextCompactionSplitOptions(
            headMinMessageCount: 3,
            tailMinMessageCount: 6,
            tailTokenBudget: max(1, Int(floor(Double(proactiveThresholdTokens) * fraction))),
            charactersPerToken: charactersPerToken
        )
    }
}
