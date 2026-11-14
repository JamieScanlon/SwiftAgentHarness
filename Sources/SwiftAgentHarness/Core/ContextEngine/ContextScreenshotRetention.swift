import Foundation
import SwiftAgentKit

/// How many computer-use screenshots stay in the projected context.
public struct ScreenshotRetentionPolicy: Sendable, Equatable {
    /// Most recent screenshots always kept in full.
    public var keepRecent: Int
    /// Older screenshots are pruned this many at a time, so the projected prefix only changes once per batch.
    public var pruneBatch: Int
    /// Tools whose result images are screenshots.
    public var toolNames: Set<String>

    /// Keeps 3 and prunes 15 at a time: at most 17 screenshots per request, under the ~20-image count above which
    /// at least one vendor lowers its per-image size cap.
    public static let `default` = ScreenshotRetentionPolicy(keepRecent: 3, pruneBatch: 15)

    public init(keepRecent: Int, pruneBatch: Int, toolNames: Set<String> = ComputerUseToolProvider.screenToolNames) {
        self.keepRecent = max(0, keepRecent)
        self.pruneBatch = max(1, pruneBatch)
        self.toolNames = toolNames
    }

    /// The policy with any retention hints from the bound model's `computer-use` feature applied.
    public func adjusted(for support: ComputerUseModelSupport?) -> ScreenshotRetentionPolicy {
        guard let support else { return self }
        return ScreenshotRetentionPolicy(
            keepRecent: support.keepRecentScreenshots ?? keepRecent,
            pruneBatch: support.pruneEvery ?? pruneBatch,
            toolNames: toolNames
        )
    }
}

/// Projection-only screenshot pruning. Counts screenshots across the loop, not user turns, so it fires inside a
/// long single-turn computer-use run. The oldest are replaced by a marker plus the observation's one-line summary
/// in whole batches, so between batches the projected prefix is byte-stable and the prompt cache holds.
enum ContextScreenshotRetention {
    /// Pruned screenshots are marked `[screenshot o_7 pruned: com.apple.TextEdit "w1", step 12]`, written from the
    /// observation's header line with no model call.
    static let markerPrefix = "[screenshot "

    static func apply(
        messages: [Message],
        policy: ScreenshotRetentionPolicy,
        toolCallResolutionContext: [Message]
    ) -> (messages: [Message], transformationKind: CacheProjectionTransformationKind) {
        let calls = ContextCompactionToolResultPruning.toolCallIdToCallMap(
            resolutionContext: toolCallResolutionContext,
            messages: messages
        )
        var screenshots: [(message: Int, image: Int)] = []
        for (index, message) in messages.enumerated() where message.role == .tool && !message.images.isEmpty {
            guard let id = message.toolCallId, let name = calls[id]?.name,
                  policy.toolNames.contains(name.lowercased()) else { continue }
            screenshots.append(contentsOf: message.images.indices.map { (index, $0) })
        }
        let excess = screenshots.count - policy.keepRecent
        let pruneCount = excess > 0 ? (excess / policy.pruneBatch) * policy.pruneBatch : 0
        guard pruneCount > 0 else { return (messages, .cacheNeutral) }

        let pruned = Dictionary(grouping: screenshots.prefix(pruneCount), by: \.message)
            .mapValues { Set($0.map(\.image)) }
        var output = messages
        for (index, imageIndices) in pruned {
            var message = output[index]
            message.images = message.images.enumerated().filter { !imageIndices.contains($0.offset) }.map(\.element)
            message.content = marked(message.content, count: imageIndices.count)
            output[index] = message
        }
        return (output, .cacheEditing)
    }

    private static func marked(_ content: String, count: Int) -> String {
        guard !isMarked(content) else { return content }
        let header = content.split(separator: "\n", omittingEmptySubsequences: true).first { $0.hasPrefix("Observation ") }.map(String.init)
        let marker = Self.marker(header: header, count: count)
        return content.isEmpty ? marker : "\(marker)\n\(content)"
    }

    static func isMarked(_ content: String) -> Bool {
        content.contains(/\[screenshot \S+ pruned/)
    }

    /// The marker for a screenshot whose result header is `header`: its observation id, app, window, and step.
    static func marker(header: String?, count: Int) -> String {
        let tally = count == 1 ? "" : " (\(count) images)"
        guard let header else { return "\(markerPrefix)earlier pruned\(tally)]" }
        let id = header.firstMatch(of: /^Observation (\S+?)(?::|\s|$)/).map { String($0.output.1) } ?? "earlier"
        let app = header.firstMatch(of: /(?:— app | · )([A-Za-z0-9.\-_]+\.[A-Za-z0-9.\-_]+)/).map { String($0.output.1) }
        let window = header.firstMatch(of: /window (\S+?)(?:,|\s|$)/).map { String($0.output.1) }
        let step = header.firstMatch(of: /step (\d+)/).map { String($0.output.1) }
        var where_ = [app, window.map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
        if let step { where_ += where_.isEmpty ? "step \(step)" : ", step \(step)" }
        return "\(markerPrefix)\(id) pruned\(tally)\(where_.isEmpty ? "" : ": \(where_)")]"
    }
}
