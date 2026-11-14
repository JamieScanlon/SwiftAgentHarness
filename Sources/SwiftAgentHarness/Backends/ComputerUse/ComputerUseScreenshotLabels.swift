import Foundation
import SwiftAgentKit
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
#if canImport(CoreText)
import CoreText
#endif

/// Element refs drawn onto the screenshot as short tags, so the model can tie what it sees to the ref it acts on.
/// The labeled copy goes only to the model: the observation keeps the raw pixels, and the image keeps the size
/// its geometry records, so coordinates still map back the same way.
enum ComputerUseScreenshotLabels {
    struct Tag: Sendable, Hashable {
        var ref: String
        /// The element's frame, in image pixels with a top-left origin.
        var element: DisplayRect
        /// Where the tag is drawn, in the same space.
        var label: DisplayRect
    }

    /// A few dozen: more tags crowd the screenshot past reading.
    static let maxTags = 40
    /// Larger elements are containers: windows, scroll areas, text areas filling the view. Tagging them adds clutter
    /// without telling the model which control is which.
    static let maxElementAreaFraction = 0.25
    /// Below this many pixels on either side an element is too small to mark.
    static let minElementSidePx = 3.0

    static func fontPx(forImageHeight height: Int) -> Double {
        min(16, max(10, Double(height) / 64))
    }

    /// Roles a model acts on. Everything else stays in the tree, untagged.
    static func isActionable(_ role: String) -> Bool {
        let role = role.lowercased()
        return ["button", "link", "textfield", "textbox", "searchbox", "searchfield", "combobox", "checkbox", "radio",
                "menuitem", "tab", "slider", "switch", "popup", "edittext", "option", "spinbutton", "textarea", "incrementor"]
            .contains { role.contains($0) }
    }

    /// Where the tags go: actionable elements on the screenshot, the focused one first, then those nearest the last
    /// action, then smaller ones. A tag that would cover one already placed is dropped; its element is still in the
    /// tree.
    static func tags(for observation: DisplayObservation, near lastAction: DisplayPoint? = nil) -> [Tag] {
        guard let image = observation.image, let elements = observation.tree?.elements, !elements.isEmpty else { return [] }
        let geometry = image.geometry
        let bounds = DisplayRect(x: 0, y: 0, width: Double(geometry.imageSize.width), height: Double(geometry.imageSize.height))
        let maxArea = bounds.width * bounds.height * maxElementAreaFraction
        let font = fontPx(forImageHeight: geometry.imageSize.height)

        let near = lastAction.map { geometry.toImage($0) }
        let candidates: [(ref: String, frame: DisplayRect, focused: Bool)] = elements.compactMap { ref, element in
            guard let frame = element.frame, isActionable(element.role) else { return nil }
            let origin = geometry.toImage(DisplayPoint(x: frame.minX, y: frame.minY))
            let corner = geometry.toImage(DisplayPoint(x: frame.maxX, y: frame.maxY))
            let pixels = DisplayRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
            guard pixels.width >= minElementSidePx, pixels.height >= minElementSidePx, pixels.width * pixels.height <= maxArea,
                  pixels.maxX > 0, pixels.maxY > 0, pixels.minX < bounds.maxX, pixels.minY < bounds.maxY
            else { return nil }
            return (ref, pixels, element.isFocused)
        }
        .sorted { lhs, rhs in
            if lhs.focused != rhs.focused { return lhs.focused }
            if let near {
                let (left, right) = (distance(lhs.frame, near), distance(rhs.frame, near))
                if left != right { return left < right }
            }
            let (left, right) = (lhs.frame.width * lhs.frame.height, rhs.frame.width * rhs.frame.height)
            return left != right ? left < right : refOrder(lhs.ref, rhs.ref)
        }

        var placed: [Tag] = []
        for candidate in candidates where placed.count < maxTags {
            let label = labelRect(for: candidate.ref, at: candidate.frame, fontPx: font, in: bounds)
            guard !placed.contains(where: { overlaps($0.label, label) }) else { continue }
            placed.append(Tag(ref: candidate.ref, element: candidate.frame, label: label))
        }
        return placed
    }

    private static func distance(_ frame: DisplayRect, _ point: DisplayPoint) -> Double {
        let dx = frame.center.x - point.x, dy = frame.center.y - point.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The screenshot with its tags drawn, the same size and format. `nil` when there is nothing to tag, the bitmap
    /// doesn't match the recorded geometry, or the platform can't draw.
    static func labeled(_ observation: DisplayObservation, near lastAction: DisplayPoint? = nil) -> ToolResultImage? {
        #if canImport(ImageIO) && canImport(CoreText)
        guard let image = observation.image, let data = image.data, let screenshot = ComputerUseImageEncoding.decode(data),
              screenshot.width == image.geometry.imageSize.width, screenshot.height == image.geometry.imageSize.height
        else { return nil }
        let tags = tags(for: observation, near: lastAction)
        guard !tags.isEmpty, let drawn = draw(tags, on: screenshot) else { return nil }
        let jpeg = image.mediaType == "image/jpeg"
        guard let encoded = ComputerUseImageEncoding.encode(drawn, as: jpeg ? .jpeg : .png) else { return nil }
        return ToolResultImage(data: encoded, mediaType: jpeg ? "image/jpeg" : "image/png", width: drawn.width, height: drawn.height)
        #else
        return nil
        #endif
    }

    // MARK: - Layout

    private static func labelRect(for ref: String, at element: DisplayRect, fontPx: Double, in bounds: DisplayRect) -> DisplayRect {
        let width = Double(ref.count) * fontPx * 0.62 + 6
        let height = fontPx + 4
        // Inside the element's top-left corner when it fits, otherwise just above it.
        var y = element.height >= height * 1.5 ? element.minY : element.minY - height
        if y < bounds.minY { y = element.minY }
        let x = min(max(element.minX, bounds.minX), bounds.maxX - width)
        return DisplayRect(x: x, y: min(max(y, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    private static func overlaps(_ a: DisplayRect, _ b: DisplayRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    private static func refOrder(_ lhs: String, _ rhs: String) -> Bool {
        let (left, right) = (Int(lhs.drop { !$0.isNumber }), Int(rhs.drop { !$0.isNumber }))
        if let left, let right, left != right { return left < right }
        return lhs < rhs
    }

    // MARK: - Drawing

    #if canImport(ImageIO) && canImport(CoreText)
    private static func draw(_ tags: [Tag], on screenshot: CGImage) -> CGImage? {
        let (width, height) = (screenshot.width, screenshot.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(screenshot, in: CGRect(x: 0, y: 0, width: width, height: height))
        let fontPx = fontPx(forImageHeight: height)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontPx, nil)
        let tagColor = CGColor(red: 0.86, green: 0.08, blue: 0.24, alpha: 1)
        let outline = CGColor(red: 0.86, green: 0.08, blue: 0.24, alpha: 0.7)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

        // CoreGraphics draws bottom-up; tag rects are top-down.
        func flipped(_ rect: DisplayRect) -> CGRect {
            CGRect(x: rect.x, y: Double(height) - rect.y - rect.height, width: rect.width, height: rect.height)
        }

        context.setLineWidth(1.5)
        context.setStrokeColor(outline)
        for tag in tags {
            context.stroke(flipped(tag.element).insetBy(dx: 0.75, dy: 0.75))
        }
        for tag in tags {
            let box = flipped(tag.label)
            context.setFillColor(tagColor)
            context.fill(box)
            let text = NSAttributedString(string: tag.ref, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
            ])
            let line = CTLineCreateWithAttributedString(text)
            let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: box.midX - textWidth / 2, y: box.minY + (box.height - fontPx) / 2 + fontPx * 0.2)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
    #endif
}
