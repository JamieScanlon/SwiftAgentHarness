import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

// MARK: - TriggerContentBuilder

@Suite("TriggerContentBuilder")
struct TriggerContentBuilderTests {

    @Test("triggerTag constant is [trigger]")
    func triggerTagConstant() {
        #expect(TriggerContentBuilder.triggerTag == "[trigger]")
    }

    @Test("buildFullContent starts with [trigger] and contains double newline then body")
    func buildFullContentFormat() {
        let body = "Hello world"
        let full = TriggerContentBuilder.buildFullContent(messageBody: body, triggerMetadata: ["name": "cron"], serverKeys: nil)
        #expect(full.hasPrefix("[trigger]"))
        #expect(full.contains("\n\n"))
        let parts = full.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        #expect(parts.count >= 2)
        let afterBlank = full.range(of: "\n\n")!.upperBound
        #expect(String(full[afterBlank...]) == body)
    }

    @Test("buildFullContent includes each metadata key=value pair on first line")
    func buildFullContentMetadataOnLine() {
        let meta = ["a": "1", "b": "2"]
        let full = TriggerContentBuilder.buildFullContent(messageBody: "x", triggerMetadata: meta, serverKeys: nil)
        #expect(full.contains("a=1") || full.contains("1"))
        #expect(full.contains("b=2") || full.contains("2"))
        #expect(full.contains(";"))
        #expect(full.hasPrefix("[trigger] "))
    }

    @Test("buildFullContent with serverKeys merges and includes received_at")
    func buildFullContentServerKeys() {
        let full = TriggerContentBuilder.buildFullContent(
            messageBody: "body",
            triggerMetadata: ["name": "test"],
            serverKeys: ["received_at": "2026-01-01T00:00:00Z"]
        )
        #expect(full.contains("received_at=2026-01-01T00:00:00Z"))
        #expect(full.contains("name=test") || full.contains("test"))
        let afterBlank = full.range(of: "\n\n")!.upperBound
        #expect(String(full[afterBlank...]) == "body")
    }

    @Test("buildFullContent with nil and empty metadata still produces valid trigger line")
    func buildFullContentEmptyMetadata() {
        let fullNil = TriggerContentBuilder.buildFullContent(messageBody: "x", triggerMetadata: nil, serverKeys: nil)
        #expect(fullNil.hasPrefix("[trigger]"))
        #expect(fullNil.contains("\n\n"))
        let fullEmpty = TriggerContentBuilder.buildFullContent(messageBody: "x", triggerMetadata: [:], serverKeys: nil)
        #expect(fullEmpty.hasPrefix("[trigger]"))
    }

    @Test("buildFullContent with only serverKeys produces valid content")
    func buildFullContentOnlyServerKeys() {
        let full = TriggerContentBuilder.buildFullContent(
            messageBody: "only body",
            triggerMetadata: nil,
            serverKeys: ["received_at": "2026-03-01T12:00:00Z"]
        )
        #expect(full.hasPrefix("[trigger]"))
        #expect(full.contains("received_at=2026-03-01T12:00:00Z"))
        let afterBlank = full.range(of: "\n\n")!.upperBound
        #expect(String(full[afterBlank...]) == "only body")
    }

    @Test("buildTriggerLine with pairs returns single line with key=value segments")
    func buildTriggerLine() {
        let line = TriggerContentBuilder.buildTriggerLine(pairs: ["k1": "v1", "k2": "v2"])
        #expect(line.hasPrefix("[trigger] "))
        #expect(line.contains("k1=v1"))
        #expect(line.contains("k2=v2"))
        #expect(line.contains(";"))
        #expect(line.contains("\n") == false)
    }

    @Test("buildTriggerLine with empty pairs returns only tag")
    func buildTriggerLineEmpty() {
        let line = TriggerContentBuilder.buildTriggerLine(pairs: [:])
        #expect(line == "[trigger]")
    }
}

// MARK: - Message+Trigger extensions (parse / read-side)

@Suite("Message+Trigger extensions")
struct MessageTriggerExtensionTests {

    @Test("Message.triggerMetadata parses first line when content starts with [trigger]")
    func messageTriggerMetadataParsed() {
        let content = "[trigger] a=b; c=d\n\nbody text"
        let msg = Message(id: UUID(), role: .user, content: content)
        #expect(msg.triggerMetadata != nil)
        #expect(msg.triggerMetadata?["a"] == "b")
        #expect(msg.triggerMetadata?["c"] == "d")
    }

    @Test("Message.messageBodyContent returns text after double newline for trigger content")
    func messageBodyContentTrigger() {
        let content = "[trigger] x=y\n\nhello"
        let msg = Message(id: UUID(), role: .user, content: content)
        #expect(msg.messageBodyContent == "hello")
    }

    @Test("Message.triggerMetadata is nil when content does not start with [trigger]")
    func messageTriggerMetadataNilForPlain() {
        let msg = Message(id: UUID(), role: .user, content: "plain user message")
        #expect(msg.triggerMetadata == nil)
    }

    @Test("Message.messageBodyContent returns full content when not trigger")
    func messageBodyContentPlain() {
        let content = "plain user message"
        let msg = Message(id: UUID(), role: .user, content: content)
        #expect(msg.messageBodyContent == content)
    }

    @Test("CachedMessage.triggerMetadata and messageBodyContent same behavior")
    func cachedMessageTriggerParsing() {
        let content = "[trigger] name=cron; type=scheduled\n\nreminder"
        let cached = CachedMessage(id: UUID(), role: MessageRole.user.rawValue, content: content, timestamp: Date(), toolCalls: [])
        #expect(cached.triggerMetadata?["name"] == "cron")
        #expect(cached.triggerMetadata?["type"] == "scheduled")
        #expect(cached.messageBodyContent == "reminder")
    }

    @Test("CachedMessage.messageBodyContent returns full content when not trigger")
    func cachedMessageBodyPlain() {
        let content = "just plain text"
        let cached = CachedMessage(id: UUID(), role: MessageRole.user.rawValue, content: content, timestamp: Date(), toolCalls: [])
        #expect(cached.triggerMetadata == nil)
        #expect(cached.messageBodyContent == content)
    }

    @Test("TriggerContentBuilder.parse round-trip with buildFullContent")
    func parseRoundTrip() {
        let body = "test body"
        let meta = ["a": "1", "b": "2"]
        let full = TriggerContentBuilder.buildFullContent(messageBody: body, triggerMetadata: meta, serverKeys: ["received_at": "2026-01-01T00:00:00Z"])
        let (parsedMeta, parsedBody) = TriggerContentBuilder.parse(content: full)
        #expect(parsedBody == body)
        #expect(parsedMeta?["a"] == "1")
        #expect(parsedMeta?["b"] == "2")
        #expect(parsedMeta?["received_at"] == "2026-01-01T00:00:00Z")
    }
}

// MARK: - TriggerMessageRequest

@Suite("TriggerMessageRequest")
struct TriggerMessageRequestTests {

    @Test("TriggerMessageRequest requires conversationID and message")
    func decodesRequiredFields() throws {
        let json = """
        {"conversationID": "550e8400-e29b-41d4-a716-446655440000", "message": "hello"}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(TriggerMessageRequest.self, from: data)
        #expect(decoded.message == "hello")
        #expect(decoded.conversationID == "550e8400-e29b-41d4-a716-446655440000")
        #expect(decoded.triggerMetadata == nil)
        #expect(decoded.imageNames == nil)
    }

    @Test("TriggerMessageRequest fails decode when conversationID is missing")
    func decodeFailsWhenConversationIDMissing() throws {
        let json = """
        {"message": "hello"}
        """
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TriggerMessageRequest.self, from: data)
        }
    }

    @Test("TriggerMessageRequest decodes with triggerMetadata object")
    func decodesTriggerMetadata() throws {
        let json = """
        {"conversationID": "550e8400-e29b-41d4-a716-446655440000", "message": "hi", "triggerMetadata": {"name": "cron", "type": "scheduled"}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(TriggerMessageRequest.self, from: data)
        #expect(decoded.message == "hi")
        #expect(decoded.triggerMetadata?["name"] == "cron")
        #expect(decoded.triggerMetadata?["type"] == "scheduled")
    }

    @Test("TriggerMessageRequest decodes with conversationID and imageNames")
    func decodesOptionalFields() throws {
        let json = """
        {"message": "m", "conversationID": "550e8400-e29b-41d4-a716-446655440000", "imageNames": ["a.png"], "includeTools": false}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(TriggerMessageRequest.self, from: data)
        #expect(decoded.conversationID == "550e8400-e29b-41d4-a716-446655440000")
        #expect(decoded.imageNames?.count == 1)
        #expect(decoded.imageNames?[0] == "a.png")
        #expect(decoded.includeTools == false)
    }
}

// MARK: - System prompt trigger paragraph

@Suite("SystemPrompt — Trigger message paragraph")
struct SystemPromptTriggerParagraphTests {

    @Test("Generated system prompt contains trigger paragraph")
    func containsTriggerParagraph() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("[trigger]"))
        #expect(result.contains("key-value") || result.contains("key value"))
        #expect(result.contains("cron") || result.contains("automation") || result.contains("Zapier"))
    }
}

// MARK: - Trigger endpoint contract (content shape as built by API layer)

@Suite("Trigger API content shape")
struct TriggerAPIContentShapeTests {

    @Test("Full content built as by REST trigger endpoint has correct format")
    func restTriggerContentShape() {
        let request = TriggerMessageRequest(
            conversationID: "550e8400-e29b-41d4-a716-446655440000",
            message: "Remind me to water plants",
            triggerMetadata: ["name": "WeatherWatcher", "type": "cron"],
            imageNames: nil,
            includeTools: true,
            includeAgents: true
        )
        let receivedAt = ISO8601DateFormatter().string(from: Date())
        let fullContent = TriggerContentBuilder.buildFullContent(
            messageBody: request.message,
            triggerMetadata: request.triggerMetadata,
            serverKeys: ["received_at": receivedAt]
        )
        #expect(fullContent.hasPrefix("[trigger]"))
        #expect(fullContent.contains("received_at="))
        #expect(fullContent.contains("name=WeatherWatcher") || fullContent.contains("WeatherWatcher"))
        #expect(fullContent.contains("\n\n"))
        let bodyStart = fullContent.range(of: "\n\n")!.upperBound
        #expect(String(fullContent[bodyStart...]) == "Remind me to water plants")
    }

    @Test("Full content built as by WebSocket send_trigger_message has correct format")
    func websocketTriggerContentShape() {
        let message = "Event: no rain in a week"
        let triggerMetadata: [String: String]? = ["source": "script", "type": "event"]
        let receivedAt = ISO8601DateFormatter().string(from: Date())
        let fullContent = TriggerContentBuilder.buildFullContent(
            messageBody: message,
            triggerMetadata: triggerMetadata,
            serverKeys: ["received_at": receivedAt]
        )
        #expect(fullContent.hasPrefix("[trigger]"))
        #expect(fullContent.contains("source=script") || fullContent.contains("script"))
        #expect(fullContent.contains("received_at="))
        let bodyStart = fullContent.range(of: "\n\n")!.upperBound
        #expect(String(fullContent[bodyStart...]) == message)
    }
}
