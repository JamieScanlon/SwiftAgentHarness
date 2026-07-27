import Foundation

public final class StatusLineComponent: TUIComponent {
    public var phase: String
    public var modelName: String?
    public var tokenCount: Int?
    /// Model context window when known, so the token count reads as a proportion.
    public var contextLimitTokens: Int?
    public var showSpinner: Bool
    private let spinner = SpinnerComponent(label: "")

    public init(
        phase: String = "idle",
        modelName: String? = nil,
        tokenCount: Int? = nil,
        contextLimitTokens: Int? = nil,
        showSpinner: Bool = false
    ) {
        self.phase = phase
        self.modelName = modelName
        self.tokenCount = tokenCount
        self.contextLimitTokens = contextLimitTokens
        self.showSpinner = showSpinner
    }

    /// Advances the spinner one frame.
    ///
    /// Deliberately not called from `render`: a `render` with side effects is not
    /// idempotent, so the frame differed on every pass and the differential renderer
    /// could never reach its no-change fast path while a spinner was visible.
    public func advanceSpinner() {
        guard showSpinner else { return }
        spinner.tick()
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        var parts: [String] = []
        if showSpinner {
            // The glyph only — the label used to be set to `phase` and then `phase` was
            // appended again, rendering "⠋ … thinking".
            parts.append(ANSIStyle.dim(spinner.glyph))
        }
        parts.append(ANSIStyle.dim(phase))
        if let modelName, !modelName.isEmpty {
            parts.append(ANSIStyle.dim("·"))
            parts.append(modelName)
        }
        if let tokenCount {
            parts.append(ANSIStyle.dim("·"))
            if let contextLimitTokens, contextLimitTokens > 0 {
                parts.append(ANSIStyle.dim("\(tokenCount)/\(contextLimitTokens) tok"))
            } else {
                parts.append(ANSIStyle.dim("\(tokenCount) tok"))
            }
        }
        let line = parts.joined(separator: " ")
        return [ANSIStyle.finishLine(ANSITruncate.truncate(line, toWidth: width))]
    }

    public func invalidate() {}
}
