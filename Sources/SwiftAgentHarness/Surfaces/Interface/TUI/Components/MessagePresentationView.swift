import Foundation

/// Renders a portable ``MessagePresentation`` natively in the terminal.
///
/// This is the payoff for the terminal's position on the capability ladder: it owns a raw
/// character grid, so it can render every portable block type except `select` (which needs
/// an interactive widget the transcript has no room for) rather than degrading the whole
/// presentation to `textFallback()`.
public enum MessagePresentationTerminalRenderer: Sendable {
    /// What a terminal transcript can render natively.
    public static let capabilities = SurfacePresentationCapabilities(
        supported: true,
        buttons: true,
        selects: false,
        context: true,
        divider: true
    )

    public static func render(_ presentation: MessagePresentation, width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines: [String] = []

        if let title = presentation.title, !title.isEmpty {
            let styled = ANSIStyle.bold(TUITextSanitizer.sanitizeSingleLine(title))
            lines.append(contentsOf: ANSIWrap.wrap(tonePrefix(presentation.tone) + styled, width: width))
        }

        for block in SurfacePresentationFilter.nativeBlocks(from: presentation.blocks, capabilities: capabilities) {
            lines.append(contentsOf: render(block: block, width: width))
        }

        // A presentation whose blocks are all unsupported still has to say something.
        if lines.isEmpty {
            lines.append(contentsOf: ANSIWrap.wrap(
                TUITextSanitizer.sanitizeMultiline(presentation.textFallback()),
                width: width
            ))
        }
        return lines
    }

    private static func render(block: MessageBlock, width: Int) -> [String] {
        switch block {
        case .text(let value):
            return ANSIWrap.wrap(TUITextSanitizer.sanitizeMultiline(value), width: width)

        case .context(let value):
            return ANSIWrap.wrap(ANSIStyle.dim(TUITextSanitizer.sanitizeMultiline(value)), width: width)

        case .divider:
            return [ANSIStyle.finishLine(ANSIStyle.dim(String(repeating: "─", count: width)))]

        case .buttons(let buttons):
            guard !buttons.isEmpty else { return [] }
            let rendered = buttons
                .map { button in styled(label: button.label, style: button.style) }
                .joined(separator: " ")
            return [ANSIStyle.finishLine(ANSITruncate.truncate(rendered, toWidth: width))]

        case .select(let options, let label):
            // Not in `capabilities`, so normally filtered out before reaching here; kept
            // as a text degradation for callers that render blocks directly.
            var lines: [String] = []
            if let label, !label.isEmpty {
                lines.append(contentsOf: ANSIWrap.wrap(ANSIStyle.dim(label), width: width))
            }
            for option in options {
                lines.append(ANSIStyle.finishLine(
                    ANSITruncate.truncate("  • \(option.label)", toWidth: width)
                ))
            }
            return lines
        }
    }

    private static func styled(label: String, style: ApprovalButtonStyle) -> String {
        let text = "[ \(TUITextSanitizer.sanitizeSingleLine(label)) ]"
        switch style {
        case .primary: return ANSIStyle.bold(text)
        case .danger: return ANSIStyle.color(text, fg: 203)
        case .default: return text
        }
    }

    private static func tonePrefix(_ tone: MessageTone?) -> String {
        guard let tone else { return "" }
        switch tone {
        case .info: return ANSIStyle.color("ℹ ", fg: 39)
        case .success: return ANSIStyle.color("✔ ", fg: 46)
        case .warning: return ANSIStyle.color("▲ ", fg: 214)
        case .error: return ANSIStyle.color("✖ ", fg: 203)
        }
    }
}

/// Presentation-rendering slot for the terminal surface.
public struct TUIPresentationRenderer: SurfacePresentationRendering {
    public let presentationCapabilities: SurfacePresentationCapabilities

    /// A terminal has no wire limit — it owns its own display and repaints freely. The
    /// value is large rather than `Int.max` so chunker arithmetic stays well-defined.
    public let textChunkLimit: Int

    public init(
        presentationCapabilities: SurfacePresentationCapabilities = MessagePresentationTerminalRenderer.capabilities,
        textChunkLimit: Int = 1_000_000
    ) {
        self.presentationCapabilities = presentationCapabilities
        self.textChunkLimit = textChunkLimit
    }

    public func renderPresentation(_ presentation: MessagePresentation) -> SurfaceRenderedPayload {
        SurfacePresentationFilter.render(presentation, capabilities: presentationCapabilities)
    }
}
