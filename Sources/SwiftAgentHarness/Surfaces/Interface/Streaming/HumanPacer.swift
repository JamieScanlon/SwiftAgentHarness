import Foundation

/// Computes randomized inter-bubble delay for block streaming.
public struct HumanPacer: Sendable {
    public static let naturalMinMs = 800
    public static let naturalMaxMs = 2500

    private let config: PacingConfig
    private let randomUnit: @Sendable () -> Double

    public init(
        config: PacingConfig,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.config = config
        self.randomUnit = randomUnit
    }

    /// Delay before sending a block reply. Returns 0 for the first bubble, final reply, or tool summaries.
    public func delayMs(isFirstBlock: Bool, isFinalReply: Bool, isToolSummary: Bool) -> Int {
        if isFirstBlock || isFinalReply || isToolSummary {
            return 0
        }
        switch config.mode {
        case .off:
            return 0
        case .natural:
            let unit = randomUnit()
            let range = Double(Self.naturalMaxMs - Self.naturalMinMs)
            return Self.naturalMinMs + Int(unit * range)
        case .custom(let minMs, let maxMs):
            let low = min(minMs, maxMs)
            let high = max(minMs, maxMs)
            let unit = randomUnit()
            return low + Int(unit * Double(high - low))
        }
    }

    public func sleepIfNeeded(isFirstBlock: Bool, isFinalReply: Bool, isToolSummary: Bool) async {
        let ms = delayMs(isFirstBlock: isFirstBlock, isFinalReply: isFinalReply, isToolSummary: isToolSummary)
        guard ms > 0 else { return }
        try? await Task.sleep(for: .milliseconds(ms))
    }
}
