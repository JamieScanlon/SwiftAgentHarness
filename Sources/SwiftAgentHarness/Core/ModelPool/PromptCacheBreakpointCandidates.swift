import Foundation
import SwiftAgentKit

enum PromptCacheBreakpointCandidates {
    static let defaultRollingWindowTokens = 4096

    static func build(input: PromptCachePlanningInput) -> [PromptCacheBreakpointCandidate] {
        let messages = input.messages
        guard !messages.isEmpty else { return [] }

        var candidates: [PromptCacheBreakpointCandidate] = []
        let injectedPrefixTokens = harnessInjectedPrefixTokenEstimate(messages: messages)
        let canonicalIndex = SystemPromptDispatchCodec.canonicalSystemMessageIndex(in: messages)

        if let canonicalIndex {
            let systemText = messages[canonicalIndex].content
            let stableText = SystemPromptStablePrefixAnalyzer.stablePrefixText(in: systemText)
            let stableTokens = tokenEstimate(for: stableText)
            let prefixThroughCanonical = nonInjectedInclusiveMessageIndex(
                messages: messages,
                through: canonicalIndex
            )
            candidates.append(
                PromptCacheBreakpointCandidate(
                    kind: .stableSystemPrefixEnd,
                    estimatedPrefixTokens: stableTokens + injectedPrefixTokens,
                    inclusiveMessageIndex: prefixThroughCanonical,
                    stableSystemPrefixCharacters: stableText.count
                )
            )
        }

        let stableSystemTokens = candidates.first(where: { $0.kind == .stableSystemPrefixEnd })?.estimatedPrefixTokens ?? injectedPrefixTokens
        let toolTokens = toolSchemaTokenEstimate(config: input.config)
        if toolTokens > 0 {
            candidates.append(
                PromptCacheBreakpointCandidate(
                    kind: .toolSchemasEnd,
                    estimatedPrefixTokens: stableSystemTokens + toolTokens,
                    inclusiveMessageIndex: candidates.first(where: { $0.kind == .stableSystemPrefixEnd })?.inclusiveMessageIndex,
                    stableSystemPrefixCharacters: nil
                )
            )
        }

        if let rolling = rollingConversationCandidate(
            messages: messages,
            injectedPrefixTokens: injectedPrefixTokens,
            stableSystemTokens: stableSystemTokens,
            toolTokens: toolTokens
        ) {
            candidates.append(rolling)
        }

        return candidates
    }

    private static func rollingConversationCandidate(
        messages: [Message],
        injectedPrefixTokens: Int,
        stableSystemTokens: Int,
        toolTokens: Int
    ) -> PromptCacheBreakpointCandidate? {
        let baseTokens = stableSystemTokens + toolTokens
        var accumulated = 0
        var inclusiveIndex: Int?
        var nonInjectedTurns = 0

        for index in messages.indices.reversed() {
            let message = messages[index]
            if HarnessInjectedMessageMetadata.isHarnessInjected(message) {
                continue
            }
            if message.role == .assistant || message.role == .user || message.role == .tool {
                nonInjectedTurns += 1
            }
            accumulated += tokenEstimate(for: message.content)
            inclusiveIndex = index
            if accumulated >= defaultRollingWindowTokens {
                break
            }
        }

        guard let inclusiveIndex, nonInjectedTurns > 1 else { return nil }
        let conversationBodyTokens = messages[inclusiveIndex...]
            .filter { !HarnessInjectedMessageMetadata.isHarnessInjected($0) }
            .reduce(0) { $0 + tokenEstimate(for: $1.content) }
        guard conversationBodyTokens >= 2048 else { return nil }

        return PromptCacheBreakpointCandidate(
            kind: .rollingConversation,
            estimatedPrefixTokens: baseTokens + conversationBodyTokens,
            inclusiveMessageIndex: inclusiveIndex,
            stableSystemPrefixCharacters: nil
        )
    }

    private static func harnessInjectedPrefixTokenEstimate(messages: [Message]) -> Int {
        messages
            .filter { HarnessInjectedMessageMetadata.isHarnessInjected($0) }
            .reduce(0) { $0 + tokenEstimate(for: $1.content) }
    }

    private static func nonInjectedInclusiveMessageIndex(messages: [Message], through index: Int) -> Int {
        for offset in (0...min(index, messages.count - 1)).reversed() {
            if !HarnessInjectedMessageMetadata.isHarnessInjected(messages[offset]) {
                return offset
            }
        }
        return min(index, messages.count - 1)
    }

    private static func toolSchemaTokenEstimate(config: LLMRequestConfig) -> Int {
        guard !config.availableTools.isEmpty else { return 0 }
        var total = 0
        for tool in config.availableTools {
            total += tokenEstimate(for: tool.name)
            total += tokenEstimate(for: tool.description)
            if let schema = config.toolParameterSchemasByName[tool.name] {
                total += tokenEstimate(for: String(describing: schema))
            } else {
                for param in tool.parameters {
                    total += tokenEstimate(for: param.name)
                    total += tokenEstimate(for: param.description)
                    total += tokenEstimate(for: param.type)
                }
            }
        }
        return total
    }

    static func tokenEstimate(for text: String) -> Int {
        max(0, Int(ceil(Double(text.count) / 4.0)))
    }

    static func derivedStablePrefixMessageCount(
        messages: [Message],
        breakpoints: [PromptCacheBreakpointCandidate],
        strategy: PromptCacheStrategy
    ) -> Int? {
        if let rollingIndex = breakpoints.first(where: { $0.kind == .rollingConversation })?.inclusiveMessageIndex {
            if let rollingCount = countNonInjectedMessages(
                through: rollingIndex,
                in: messages,
                strategy: strategy
            ) {
                return rollingCount
            }
        }
        return leadingStableMessageCount(messages: messages, strategy: strategy)
    }

    private static func countNonInjectedMessages(
        through index: Int,
        in messages: [Message],
        strategy: PromptCacheStrategy
    ) -> Int? {
        var count = 0
        for (offset, message) in messages.enumerated() {
            if HarnessInjectedMessageMetadata.isHarnessInjected(message) {
                continue
            }
            count += 1
            if offset >= index {
                break
            }
        }
        guard count >= 2 else { return nil }
        let cap = strategy == .conservative ? 4 : 8
        return min(count, cap)
    }

    private static func leadingStableMessageCount(
        messages: [Message],
        strategy: PromptCacheStrategy
    ) -> Int? {
        var count = 0
        for message in messages {
            if HarnessInjectedMessageMetadata.isHarnessInjected(message) {
                continue
            }
            switch message.role {
            case .system, .user:
                count += 1
            case .assistant, .tool:
                return finalizeMessageCount(count, strategy: strategy)
            }
        }
        return finalizeMessageCount(count, strategy: strategy)
    }

    private static func finalizeMessageCount(_ count: Int, strategy: PromptCacheStrategy) -> Int? {
        guard count >= 2 else { return nil }
        let cap = strategy == .conservative ? 4 : 8
        return min(count, cap)
    }

    static func stablePrefixTokenEstimate(from breakpoints: [PromptCacheBreakpointCandidate]) -> Int? {
        guard let maxTokens = breakpoints.map(\.estimatedPrefixTokens).max(), maxTokens > 0 else {
            return nil
        }
        return maxTokens
    }
}

enum SystemPromptStablePrefixAnalyzer {
    static func stablePrefixText(in fullSystemText: String) -> String {
        let marker = ProviderPromptContribution.cacheBoundaryMarker
        var searchStart = fullSystemText.startIndex
        var markerRanges: [Range<String.Index>] = []
        while searchStart < fullSystemText.endIndex,
              let range = fullSystemText.range(of: marker, range: searchStart..<fullSystemText.endIndex) {
            markerRanges.append(range)
            searchStart = range.upperBound
        }
        guard let volatileBoundary = volatileBoundaryMarkerRange(in: fullSystemText, markerRanges: markerRanges) else {
            return fullSystemText
        }
        return String(fullSystemText[..<volatileBoundary.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func volatileSuffixText(in fullSystemText: String) -> String {
        let marker = ProviderPromptContribution.cacheBoundaryMarker
        var searchStart = fullSystemText.startIndex
        var markerRanges: [Range<String.Index>] = []
        while searchStart < fullSystemText.endIndex,
              let range = fullSystemText.range(of: marker, range: searchStart..<fullSystemText.endIndex) {
            markerRanges.append(range)
            searchStart = range.upperBound
        }
        guard let volatileBoundary = volatileBoundaryMarkerRange(in: fullSystemText, markerRanges: markerRanges) else {
            return ""
        }
        return String(fullSystemText[volatileBoundary.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func volatileBoundaryMarkerRange(
        in text: String,
        markerRanges: [Range<String.Index>]
    ) -> Range<String.Index>? {
        guard !markerRanges.isEmpty else { return nil }
        if markerRanges.count >= 2 {
            return markerRanges[markerRanges.count - 1]
        }
        let after = text[markerRanges[0].upperBound...]
        return looksVolatile(after) ? markerRanges[0] : nil
    }

    private static func looksVolatile(_ suffix: Substring) -> Bool {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("Today is ") { return true }
        if trimmed.contains("# Tools") || trimmed.contains("## Tools") { return true }
        if trimmed.contains("# Attachments") || trimmed.contains("## Attachments") { return true }
        if trimmed.contains("# Additional Requirements") { return true }
        if trimmed.contains("# Dynamic Additions") { return true }
        return false
    }
}
