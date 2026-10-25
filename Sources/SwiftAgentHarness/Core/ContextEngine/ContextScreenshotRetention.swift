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
    static let markerPrefix = "[earlier screenshot removed from context"

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
        guard !content.contains(markerPrefix) else { return content }
        let summary = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { $0.hasPrefix("Observation ") }
            .map { ": \($0)" } ?? ""
        let tally = count == 1 ? "" : " (\(count) images)"
        let marker = "\(markerPrefix)\(tally)\(summary). Call \(ComputerUseToolProvider.observeToolName) for a current view.]"
        return content.isEmpty ? marker : "\(marker)\n\(content)"
    }
}
