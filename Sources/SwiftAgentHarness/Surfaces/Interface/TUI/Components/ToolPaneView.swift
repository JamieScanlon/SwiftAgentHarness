import Foundation

public final class ToolPaneViewComponent: TUIComponent {
    public var toolName: String?
    public var argumentsFragment: String
    public var output: String

    public init(toolName: String? = nil, argumentsFragment: String = "", output: String = "") {
        self.toolName = toolName
        self.argumentsFragment = argumentsFragment
        self.output = output
    }

    public func updateToolCall(name: String?, fragment: String?) {
        if let name { toolName = name }
        if let fragment { argumentsFragment += fragment }
        invalidate()
    }

    public func setOutput(_ text: String) {
        output = text
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    public func render(width: Int) -> [String] {
        let title = toolName.map { ANSIStyle.bold("⚙ \($0)") } ?? ANSIStyle.dim("⚙ tool")
        var lines = [ANSIStyle.finishLine(ANSITruncate.truncate(title, toWidth: width))]
        if !argumentsFragment.isEmpty {
            lines.append(ANSIStyle.finishLine(ANSITruncate.truncate(ANSIStyle.dim("args: \(argumentsFragment)"), toWidth: width)))
        }
        if !output.isEmpty {
            lines.append(contentsOf: ANSIWrap.wrap(output, width: width))
        }
        return lines
    }
}
