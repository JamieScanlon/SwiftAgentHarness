import Foundation

public final class StatusLineComponent: TUIComponent {
    public var phase: String
    public var modelName: String?
    public var tokenCount: Int?
    public var showSpinner: Bool
    private let spinner = SpinnerComponent(label: "")

    public init(phase: String = "idle", modelName: String? = nil, tokenCount: Int? = nil, showSpinner: Bool = false) {
        self.phase = phase
        self.modelName = modelName
        self.tokenCount = tokenCount
        self.showSpinner = showSpinner
    }

    public func render(width: Int) -> [String] {
        var parts: [String] = []
        if showSpinner {
            spinner.label = phase
            spinner.tick()
            parts.append(spinner.render(width: 3).first ?? "")
        }
        parts.append(ANSIStyle.dim(phase))
        if let modelName, !modelName.isEmpty {
            parts.append(ANSIStyle.dim("·"))
            parts.append(modelName)
        }
        if let tokenCount {
            parts.append(ANSIStyle.dim("·"))
            parts.append(ANSIStyle.dim("\(tokenCount) tok"))
        }
        let line = parts.joined(separator: " ")
        return [ANSIStyle.finishLine(ANSITruncate.truncate(line, toWidth: width))]
    }

    public func invalidate() {}
}
