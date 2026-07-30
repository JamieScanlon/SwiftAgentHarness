import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Regression coverage for a downstream report in which an Anthropic turn persisted as an
/// empty assistant message stamped `finishReason: "stop"`, while the cached HTTP body for the
/// same request carried text deltas plus an `agent-skill-activate` `tool_use` block and
/// `stop_reason: tool_use`.
///
/// Two failure surfaces are pinned here: the SSE body must decode end-to-end into that text
/// and tool call, and a stream that yields nothing usable must fail loudly rather than
/// complete as a successful empty turn.
@Suite("Anthropic SSE empty-turn regression")
struct AnthropicSSEEmptyTurnRegressionTests {

    // MARK: - Fixture

    /// Wire body reconstructed from the reported conversation: a text block followed by an
    /// `agent-skill-activate` tool call, terminated by `stop_reason: tool_use`.
    private static let skillActivationSSEBody = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_01Fixture","type":"message","role":"assistant","model":"claude-haiku-4-5","content":[],"stop_reason":null,"usage":{"input_tokens":1842,"output_tokens":1,"cache_read_input_tokens":12000}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I can see the "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"'writing-plans' skill is available"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01SkillActivate","name":"agent-skill-activate","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"skill_name\\""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":":\\"writing-plans\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":64}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    private static func decodeEvents(
        from body: String,
        flushTrailingFrame: Bool = true
    ) -> [AnthropicStreamEvent] {
        var decoder = AnthropicSSEFrameDecoder()
        var events: [AnthropicStreamEvent] = []
        for line in body.components(separatedBy: "\n") {
            events.append(contentsOf: decoder.consume(line: line))
        }
        if flushTrailingFrame {
            events.append(contentsOf: decoder.flush())
        }
        return events
    }

    // MARK: - Harness

    private struct StubStreamSource: AnthropicStreamSourcing {
        let events: [AnthropicStreamEvent]

        func messageStream(
            apiURL: URL,
            apiKey: String,
            requestBody: Data,
            logger: Logger?
        ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
            let _ = (apiURL, apiKey, requestBody, logger)
            let events = self.events
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private func makeAdapter(events: [AnthropicStreamEvent]) async throws -> AnthropicLLM {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        return AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "dummy",
            model: "claude-haiku-4-5",
            capabilities: [.completion, .tools],
            systemPrompt: prompt,
            streamSource: StubStreamSource(events: events)
        )
    }

    private func consume(
        _ stream: AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error>
    ) async -> (results: [ModelStreamEvent], terminalError: Error?) {
        var results: [ModelStreamEvent] = []
        var terminal: Error?
        do {
            for try await element in stream {
                results.append(element)
            }
        } catch {
            terminal = error
        }
        return (results, terminal)
    }

    private func runStream(
        events: [AnthropicStreamEvent]
    ) async throws -> (results: [ModelStreamEvent], terminalError: Error?) {
        let adapter = try await makeAdapter(events: events)
        let stream = adapter.stream(
            [Message(id: UUID(), role: .user, content: "activate the writing-plans skill")],
            config: LLMRequestConfig(maxTokens: 1024)
        )
        return await consume(stream)
    }

    // MARK: - SSE decoding

    @Test("real skill-activation SSE body decodes to text deltas and a tool_use stop")
    func fixtureDecodesTextAndToolUse() {
        let events = Self.decodeEvents(from: Self.skillActivationSSEBody)

        let text = events.compactMap { event -> String? in
            if case .contentDelta(let delta) = event { return delta }
            return nil
        }.joined()
        #expect(text == "I can see the 'writing-plans' skill is available")

        let started = events.compactMap { event -> (String?, String?)? in
            if case .toolCallStarted(let id, let name, _) = event { return (id, name) }
            return nil
        }
        #expect(started.count == 1)
        #expect(started.first?.0 == "toolu_01SkillActivate")
        #expect(started.first?.1 == "agent-skill-activate")

        let fragments = events.compactMap { event -> String? in
            if case .toolInputDelta(_, _, let fragment) = event { return fragment }
            return nil
        }.joined()
        #expect(fragments == "{\"skill_name\":\"writing-plans\"}")

        let stopReasons = events.compactMap { event -> String? in
            if case .messageDelta(_, let stopReason) = event { return stopReason }
            return nil
        }
        #expect(stopReasons == ["tool_use"])
    }

    @Test("frame that ends without a trailing blank line is still emitted")
    func trailingFrameWithoutBlankLineIsFlushed() {
        let truncated = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"tail"}}
        """
        #expect(Self.decodeEvents(from: truncated, flushTrailingFrame: false).isEmpty)

        let flushed = Self.decodeEvents(from: truncated)
        guard flushed.count == 1, case .contentDelta(let text) = flushed[0] else {
            Issue.record("expected the buffered frame to flush, got \(flushed)")
            return
        }
        #expect(text == "tail")
    }

    // MARK: - Parser -> stream -> accumulator

    @Test("fixture survives parser, stream, and AssistantMessageAccumulator intact")
    func fixtureSurvivesFullPipeline() async throws {
        let (results, terminal) = try await runStream(events: Self.decodeEvents(from: Self.skillActivationSSEBody))
        #expect(terminal == nil)

        guard let last = results.last, case .complete(let final) = last else {
            Issue.record("expected terminal .complete, got \(results)")
            return
        }
        #expect(final.content == "I can see the 'writing-plans' skill is available")
        #expect(final.metadata?.finishReason == FinishReason.toolCalls.rawValue)

        var accumulator = AssistantMessageAccumulator()
        for result in results {
            accumulator.consume(result)
        }
        let envelope = accumulator.finalize()
        #expect(envelope.message.content == "I can see the 'writing-plans' skill is available")
        #expect(envelope.message.toolCalls.count == 1)

        let toolCall = try #require(envelope.message.toolCalls.first)
        #expect(toolCall.id == "toolu_01SkillActivate")
        #expect(toolCall.name == "agent-skill-activate")
        guard case .object(let arguments) = toolCall.arguments,
              case .string(let skillName)? = arguments["skill_name"] else {
            Issue.record("expected skill_name argument, got \(toolCall.arguments)")
            return
        }
        #expect(skillName == "writing-plans")
    }

    // MARK: - Degenerate streams must fail, not succeed empty

    private func expectDegenerate(
        _ terminal: Error?,
        kind: DegenerateStreamError.Kind
    ) -> DegenerateStreamError? {
        guard let failure = terminal as? DegenerateStreamError else {
            Issue.record("expected DegenerateStreamError terminal, got \(String(describing: terminal))")
            return nil
        }
        #expect(failure.kind == kind)
        #expect(failure.provider == "Anthropic")
        return failure
    }

    @Test("stream with no events fails instead of completing as an empty stop turn")
    func emptyStreamFails() async throws {
        let (results, terminal) = try await runStream(events: [])

        let failure = expectDegenerate(terminal, kind: .noEvents)
        #expect(failure?.detail.contains("no SSE events") == true)
        for result in results {
            if case .complete = result {
                Issue.record("contract violation: empty stream completed successfully")
            }
        }
    }

    @Test("announced tool_use block that assembles no call fails")
    func announcedToolUseBlockLostFails() async throws {
        // A block start whose name never arrived: announced, but nothing to invoke.
        let (results, terminal) = try await runStream(events: [
            .toolCallStarted(id: "toolu_01SkillActivate", name: nil, contentIndex: 0),
            .messageDelta(usage: nil, stopReason: "tool_use"),
            .messageStop,
        ])

        _ = expectDegenerate(terminal, kind: .announcedToolCallLost)
        for result in results {
            if case .complete = result {
                Issue.record("contract violation: dropped tool call completed successfully")
            }
        }
    }

    @Test("losing one of several announced tool calls fails even though the others survived")
    func partialToolCallLossFails() async throws {
        let (_, terminal) = try await runStream(events: [
            .toolCallStarted(id: "toolu_ok", name: "agent-skill-activate", contentIndex: 0),
            .toolInputDelta(id: nil, name: nil, fragment: "{\"skill_name\":\"writing-plans\"}"),
            .toolCallStarted(id: "toolu_lost", name: nil, contentIndex: 1),
            .messageDelta(usage: nil, stopReason: "tool_use"),
            .messageStop,
        ])

        let failure = expectDegenerate(terminal, kind: .announcedToolCallLost)
        #expect(failure?.detail.contains("2") == true)
    }

    @Test("stop_reason tool_use with no announced block completes: the field alone is not evidence")
    func unannouncedToolUseStopReasonStillCompletes() async throws {
        // Providers set stop_reason inconsistently, so a turn that streamed real text is not
        // failed on the field alone — only an announced-but-unassembled block is evidence.
        let (results, terminal) = try await runStream(events: [
            .contentDelta("I can see the 'writing-plans' skill is available"),
            .messageDelta(usage: nil, stopReason: "tool_use"),
            .messageStop,
        ])

        #expect(terminal == nil)
        guard let last = results.last, case .complete(let final) = last else {
            Issue.record("expected terminal .complete, got \(results)")
            return
        }
        #expect(final.content == "I can see the 'writing-plans' skill is available")
        #expect(final.toolCalls.isEmpty)
    }

    @Test("events arriving with no text, tools, or stop_reason fail")
    func eventsWithoutAnyOutcomeFail() async throws {
        let (_, terminal) = try await runStream(events: [.messageStop])

        let failure = expectDegenerate(terminal, kind: .noOutcome)
        #expect(failure?.detail.contains("stop_reason") == true)
    }

    @Test("provider-reported empty end_turn still completes successfully")
    func emptyEndTurnStillSucceeds() async throws {
        let (results, terminal) = try await runStream(events: [
            .messageDelta(usage: nil, stopReason: "end_turn"),
            .messageStop,
        ])

        #expect(terminal == nil)
        guard let last = results.last, case .complete(let final) = last else {
            Issue.record("expected terminal .complete, got \(results)")
            return
        }
        #expect(final.content.isEmpty)
        #expect(final.metadata?.finishReason == FinishReason.stop.rawValue)
    }

    @Test("empty max_tokens truncation completes and reports the length finish reason")
    func emptyMaxTokensTurnSucceeds() async throws {
        let (results, terminal) = try await runStream(events: [
            .messageDelta(usage: nil, stopReason: "max_tokens"),
            .messageStop,
        ])

        #expect(terminal == nil)
        guard let last = results.last, case .complete(let final) = last else {
            Issue.record("expected terminal .complete, got \(results)")
            return
        }
        #expect(final.metadata?.finishReason == FinishReason.length.rawValue)
    }
}

/// A degenerate stream is a response-shape failure, so it classifies on its own axis rather
/// than by widening ``LLMError/invalidResponse`` — which must stay terminal for SSE `error`
/// events and non-HTTP responses.
@Suite("DegenerateStreamError classification")
struct DegenerateStreamErrorClassificationTests {
    private static func error(_ kind: DegenerateStreamError.Kind) -> DegenerateStreamError {
        DegenerateStreamError(kind: kind, provider: "Anthropic", detail: "detail for \(kind.rawValue)")
    }

    @Test("every kind is transient, so a bounded retry can re-issue the call")
    func allKindsAreTransient() {
        for kind in [DegenerateStreamError.Kind.noEvents, .announcedToolCallLost, .noOutcome] {
            #expect(TransientErrorClassifier.classify(Self.error(kind)) == .transient)
        }
    }

    @Test("degenerate streams rotate to the next binding")
    func rotatesBindings() {
        #expect(BindingFailoverClassifier.classify(Self.error(.noEvents)) == .tryNextBinding)
    }

    @Test("LLMError.invalidResponse stays terminal for retry")
    func invalidResponseUnchanged() {
        #expect(TransientErrorClassifier.classify(LLMError.invalidResponse("SSE error")) == .terminal)
    }

    @Test("cancellation still wins over the degenerate classification")
    func cancellationStillTerminal() {
        #expect(TransientErrorClassifier.classify(CancellationError()) == .terminal)
        #expect(BindingFailoverClassifier.classify(CancellationError()) == .terminal)
    }

    @Test("the emitter does not relabel a degenerate stream as a network error")
    func emitterPreservesDegenerateType() async {
        var thrown: Error?
        let stream = AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> { continuation in
            let emitter = StreamCompletionEmitter(continuation: continuation)
            emitter.finishFailed(with: Self.error(.noEvents))
        }
        do {
            for try await _ in stream {}
        } catch {
            thrown = error
        }
        guard let degenerate = thrown as? DegenerateStreamError else {
            Issue.record("expected the emitter to pass DegenerateStreamError through, got \(String(describing: thrown))")
            return
        }
        #expect(degenerate.kind == .noEvents)
    }

    @Test("no retry-after hint is invented for a degenerate stream")
    func noRetryAfterHint() {
        #expect(TransientErrorClassifier.retryAfterSeconds(Self.error(.noEvents)) == nil)
        #expect(TransientErrorClassifier.isRateLimited(Self.error(.noEvents)) == false)
    }
}
