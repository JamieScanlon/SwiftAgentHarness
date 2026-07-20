import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Active memory query modes and prompt styles")
struct ActiveMemoryQueryModeTests {
    private let now = Date()

    private func user(_ text: String, id: UUID = UUID()) -> Message {
        Message(id: id, role: .user, content: text, timestamp: now)
    }

    private func assistant(_ text: String, id: UUID = UUID()) -> Message {
        Message(id: id, role: .assistant, content: text, timestamp: now)
    }

    @Test("message mode returns latest user only")
    func messageModeLatestOnly() {
        let messages = [
            user("first option is Grafana"),
            assistant("Noted."),
            user("what about the second one?")
        ]
        let payload = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: nil,
            mode: .message,
            recentUserTurns: 2,
            recentAssistantTurns: 1,
            recentUserChars: 220,
            recentAssistantChars: 180
        )
        #expect(payload == "what about the second one?")
        #expect(payload?.contains("Grafana") == false)
    }

    @Test("recent default includes capped prior user and assistant turns with latest last")
    func recentDefaultIncludesPriorTail() throws {
        let messages = [
            user("compare Prometheus and Grafana"),
            assistant("Prometheus scrapes; Grafana visualizes."),
            user("what about the second one?")
        ]
        let payload = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: nil,
            mode: .recent,
            recentUserTurns: 2,
            recentAssistantTurns: 1,
            recentUserChars: 220,
            recentAssistantChars: 180
        )
        #expect(payload != nil)
        let text = try #require(payload)
        #expect(text.contains("[prior user] compare Prometheus and Grafana"))
        #expect(text.contains("[prior assistant] Prometheus scrapes; Grafana visualizes."))
        #expect(text.hasSuffix("[latest user] what about the second one?"))
        let latestRange = try #require(text.range(of: "[latest user]"))
        let priorRange = try #require(text.range(of: "[prior user]"))
        #expect(priorRange.lowerBound < latestRange.lowerBound)
    }

    @Test("pronoun follow-up payload contains antecedent turn text")
    func pronounFollowUpSeesAntecedent() {
        let messages = [
            user("I like the blue theme and the green theme"),
            assistant("Two themes noted."),
            user("what about the second one?")
        ]
        let payload = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: nil,
            config: .default
        )
        #expect(payload?.contains("blue theme and the green theme") == true)
        #expect(payload?.contains("what about the second one?") == true)
    }

    @Test("prior injected memory-context does not appear in recent tail")
    func stripInjectedFromPriorTail() {
        let contaminated = """
        \(HarnessInjectedMessagePrefixes.activeMemoryRecall)
        \(MemoryContextFencer.fence("SECRET_STANDING_NOTE"))
        compare Prometheus and Grafana
        """
        let messages = [
            user(contaminated),
            assistant("ok"),
            user("what about the second one?")
        ]
        let payload = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: nil,
            mode: .recent,
            recentUserTurns: 2,
            recentAssistantTurns: 1,
            recentUserChars: 220,
            recentAssistantChars: 180
        )
        #expect(payload?.contains("SECRET_STANDING_NOTE") == false)
        #expect(payload?.contains("<memory-context>") == false)
        #expect(payload?.contains(HarnessInjectedMessagePrefixes.activeMemoryRecall) == false)
        #expect(payload?.contains("compare Prometheus and Grafana") == true)
    }

    @Test("harness-injected messages are skipped in the recent tail")
    func skipsHarnessInjectedMessages() {
        let injected = HarnessInjectedMessageMetadata.systemMessage(
            id: UUID(),
            content: "SHOULD_NOT_APPEAR_IN_TAIL"
        )
        let messages = [
            user("real prior"),
            injected,
            assistant("assistant prior"),
            user("latest")
        ]
        let payload = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: nil,
            mode: .recent,
            recentUserTurns: 2,
            recentAssistantTurns: 1,
            recentUserChars: 220,
            recentAssistantChars: 180
        )
        #expect(payload?.contains("SHOULD_NOT_APPEAR_IN_TAIL") == false)
        #expect(payload?.contains("real prior") == true)
        #expect(payload?.contains("assistant prior") == true)
    }

    @Test("strict vs balanced situational system prompts differ by style language")
    func promptStylesDiffer() {
        let balanced = ActiveMemoryPreReplyPrompts.prompts(
            for: .situational,
            query: "q",
            promptStyle: .balanced
        ).system
        let strict = ActiveMemoryPreReplyPrompts.prompts(
            for: .situational,
            query: "q",
            promptStyle: .strict
        ).system
        #expect(balanced.contains("Style (balanced)"))
        #expect(strict.contains("Style (strict)"))
        #expect(strict.lowercased().contains("prefer none"))
        #expect(balanced.contains("NONE"))
        #expect(strict.contains("NONE"))
        #expect(balanced != strict)
    }

    @Test("loader clamps recent turn and char knobs")
    func loaderClampsRecentKnobs() {
        let low = MemoryConfigurationLoader.load(fromMemoryObject: [
            "activeMemoryRecentUserTurns": -1,
            "activeMemoryRecentAssistantTurns": -5,
            "activeMemoryRecentUserChars": 10,
            "activeMemoryRecentAssistantChars": 10
        ])
        #expect(low.activeMemoryRecentUserTurns == 0)
        #expect(low.activeMemoryRecentAssistantTurns == 0)
        #expect(low.activeMemoryRecentUserChars == 40)
        #expect(low.activeMemoryRecentAssistantChars == 40)

        let high = MemoryConfigurationLoader.load(fromMemoryObject: [
            "activeMemoryRecentUserTurns": 99,
            "activeMemoryRecentAssistantTurns": 99,
            "activeMemoryRecentUserChars": 5000,
            "activeMemoryRecentAssistantChars": 5000,
            "activeMemoryQueryMode": "message",
            "activeMemoryPromptStyle": "strict"
        ])
        #expect(high.activeMemoryRecentUserTurns == 4)
        #expect(high.activeMemoryRecentAssistantTurns == 3)
        #expect(high.activeMemoryRecentUserChars == 1_000)
        #expect(high.activeMemoryRecentAssistantChars == 1_000)
        #expect(high.activeMemoryQueryMode == .message)
        #expect(high.activeMemoryPromptStyle == .strict)

        let defaults = MemoryConfigurationLoader.load(fromMemoryObject: [:])
        #expect(defaults.activeMemoryQueryMode == .recent)
        #expect(defaults.activeMemoryPromptStyle == .balanced)
        #expect(defaults.activeMemoryRecentUserTurns == 2)
        #expect(defaults.activeMemoryRecentAssistantTurns == 1)
        #expect(defaults.activeMemoryRecentUserChars == 220)
        #expect(defaults.activeMemoryRecentAssistantChars == 180)
    }

    @Test("full mode uses bounded window larger than recent defaults")
    func fullModeBoundedWindow() throws {
        var messages: [Message] = []
        for i in 0..<25 {
            messages.append(user("user-\(i)"))
            messages.append(assistant("assistant-\(i)"))
        }
        messages.append(user("latest"))
        let payload = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: nil,
            mode: .full,
            recentUserTurns: 2,
            recentAssistantTurns: 1,
            recentUserChars: 220,
            recentAssistantChars: 180
        )
        let text = try #require(payload)
        #expect(text.contains("[latest user] latest"))
        #expect(text.contains("user-24"))
        #expect(text.contains("user-5"))
        #expect(!text.contains("user-0"))
        let priorUserCount = text.components(separatedBy: "[prior user]").count - 1
        let priorAssistantCount = text.components(separatedBy: "[prior assistant]").count - 1
        #expect(priorUserCount == ActiveMemorySituationalQueryBuilder.fullModeMaxUserTurns)
        #expect(priorAssistantCount == ActiveMemorySituationalQueryBuilder.fullModeMaxAssistantTurns)
    }
}
