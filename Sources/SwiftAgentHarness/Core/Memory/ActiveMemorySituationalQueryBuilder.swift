import Foundation
import SwiftAgentKit

/// Builds the situational active-memory query payload from conversation messages.
enum ActiveMemorySituationalQueryBuilder: Sendable {
    /// Hard cap for ``ActiveMemoryQueryMode/full`` so situational timeouts stay bounded.
    static let fullModeMaxUserTurns = 20
    static let fullModeMaxAssistantTurns = 20

    static func build(
        messages: [Message],
        anchorUserMessageID: UUID?,
        mode: ActiveMemoryQueryMode,
        recentUserTurns: Int,
        recentAssistantTurns: Int,
        recentUserChars: Int,
        recentAssistantChars: Int
    ) -> String? {
        guard let latest = resolveLatestUser(from: messages, anchorUserMessageID: anchorUserMessageID) else {
            return nil
        }
        let latestText = sanitizeAndTruncate(latest.content, maxChars: recentUserChars)
        guard !latestText.isEmpty else { return nil }

        switch mode {
        case .message:
            return latestText
        case .recent:
            return assemble(
                messages: messages,
                latest: latest,
                latestText: latestText,
                maxPriorUser: recentUserTurns,
                maxPriorAssistant: recentAssistantTurns,
                userChars: recentUserChars,
                assistantChars: recentAssistantChars
            )
        case .full:
            return assemble(
                messages: messages,
                latest: latest,
                latestText: latestText,
                maxPriorUser: fullModeMaxUserTurns,
                maxPriorAssistant: fullModeMaxAssistantTurns,
                userChars: recentUserChars,
                assistantChars: recentAssistantChars
            )
        }
    }

    /// Convenience using ``MemoryConfiguration`` knobs.
    static func build(
        messages: [Message],
        anchorUserMessageID: UUID?,
        config: MemoryConfiguration
    ) -> String? {
        build(
            messages: messages,
            anchorUserMessageID: anchorUserMessageID,
            mode: config.activeMemoryQueryMode,
            recentUserTurns: config.activeMemoryRecentUserTurns,
            recentAssistantTurns: config.activeMemoryRecentAssistantTurns,
            recentUserChars: config.activeMemoryRecentUserChars,
            recentAssistantChars: config.activeMemoryRecentAssistantChars
        )
    }

    private static func assemble(
        messages: [Message],
        latest: Message,
        latestText: String,
        maxPriorUser: Int,
        maxPriorAssistant: Int,
        userChars: Int,
        assistantChars: Int
    ) -> String {
        guard maxPriorUser > 0 || maxPriorAssistant > 0 else { return latestText }

        var priorNewestFirst: [(label: String, text: String)] = []
        var userCount = 0
        var assistantCount = 0
        var seenLatest = false

        for message in messages.reversed() {
            if !seenLatest {
                if message.id == latest.id {
                    seenLatest = true
                }
                continue
            }
            if HarnessInjectedMessageMetadata.isHarnessInjected(message) { continue }
            switch message.role {
            case .user where userCount < maxPriorUser:
                let text = sanitizeAndTruncate(message.content, maxChars: userChars)
                if !text.isEmpty {
                    priorNewestFirst.append(("[prior user]", text))
                    userCount += 1
                }
            case .assistant where assistantCount < maxPriorAssistant:
                let text = sanitizeAndTruncate(message.content, maxChars: assistantChars)
                if !text.isEmpty {
                    priorNewestFirst.append(("[prior assistant]", text))
                    assistantCount += 1
                }
            default:
                continue
            }
            if userCount >= maxPriorUser, assistantCount >= maxPriorAssistant {
                break
            }
        }

        var lines = priorNewestFirst.reversed().map { "\($0.label) \($0.text)" }
        lines.append("[latest user] \(latestText)")
        return lines.joined(separator: "\n")
    }

    private static func resolveLatestUser(
        from messages: [Message],
        anchorUserMessageID: UUID?
    ) -> Message? {
        if let anchorUserMessageID,
           let anchored = messages.first(where: { $0.id == anchorUserMessageID && $0.role == .user }),
           !anchored.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return anchored
        }
        return messages.last(where: {
            $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    private static func sanitizeAndTruncate(_ content: String, maxChars: Int) -> String {
        let stripped = MemoryContextFencer.stripInjectedRecallArtifacts(content)
        let limit = max(1, maxChars)
        guard stripped.count > limit else { return stripped }
        return String(stripped.prefix(limit))
    }
}
