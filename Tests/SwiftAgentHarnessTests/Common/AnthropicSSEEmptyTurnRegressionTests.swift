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

    /// Drives the decoder exactly as the transport does — one byte at a time — so these tests
    /// exercise the real framing path. The previous line-based helper fed blank separators that
    /// `URLSession.AsyncBytes.lines` never delivers, which is how a green suite hid DEF-135.
    private static func decodeEvents(
        from body: String,
        flushTrailingFrame: Bool = true
    ) -> (events: [AnthropicStreamEvent], decoder: AnthropicSSEFrameDecoder) {
        var decoder = AnthropicSSEFrameDecoder()
        var events: [AnthropicStreamEvent] = []
        for byte in Array(body.utf8) {
            events.append(contentsOf: decoder.consume(byte))
        }
        if flushTrailingFrame {
            events.append(contentsOf: decoder.flush())
        }
        return (events, decoder)
    }

    private static func text(in events: [AnthropicStreamEvent]) -> String {
        events.compactMap { event -> String? in
            if case .contentDelta(let delta) = event { return delta }
            return nil
        }.joined()
    }

    private static func toolFragments(in events: [AnthropicStreamEvent]) -> String {
        events.compactMap { event -> String? in
            if case .toolInputDelta(_, _, let fragment) = event { return fragment }
            return nil
        }.joined()
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
        let (events, _) = Self.decodeEvents(from: Self.skillActivationSSEBody)

        #expect(Self.text(in: events) == "I can see the 'writing-plans' skill is available")
        #expect(Self.toolFragments(in: events) == "{\"skill_name\":\"writing-plans\"}")

        let started = events.compactMap { event -> (String?, String?)? in
            if case .toolCallStarted(let id, let name, _) = event { return (id, name) }
            return nil
        }
        #expect(started.count == 1)
        #expect(started.first?.0 == "toolu_01SkillActivate")
        #expect(started.first?.1 == "agent-skill-activate")

        let stopReasons = events.compactMap { event -> String? in
            if case .messageDelta(_, let stopReason) = event { return stopReason }
            return nil
        }
        #expect(stopReasons == ["tool_use"])
    }

    @Test("frames flush as they arrive, not all at end of body")
    func framesFlushIncrementally() {
        // The DEF-135 signature was frames=1: every payload merged into a single trailing frame.
        let (_, decoder) = Self.decodeEvents(from: Self.skillActivationSSEBody, flushTrailingFrame: false)
        #expect(decoder.frameCount > 1)
        #expect(decoder.unparseableFrameCount == 0)
    }

    @Test("a CRLF body decodes identically and is flagged")
    func crlfBodyDecodesIdentically() {
        let crlfBody = Self.skillActivationSSEBody.replacingOccurrences(of: "\n", with: "\r\n")
        let (events, decoder) = Self.decodeEvents(from: crlfBody)

        #expect(decoder.sawCarriageReturn)
        #expect(decoder.unparseableFrameCount == 0)
        #expect(decoder.frameCount > 1)
        #expect(Self.text(in: events) == "I can see the 'writing-plans' skill is available")
        #expect(Self.toolFragments(in: events) == "{\"skill_name\":\"writing-plans\"}")
    }

    @Test("an LF body is not flagged as carriage-returned")
    func lfBodyNotFlagged() {
        let (_, decoder) = Self.decodeEvents(from: Self.skillActivationSSEBody)
        #expect(decoder.sawCarriageReturn == false)
    }

    @Test("frame that ends without a trailing blank line is still emitted")
    func trailingFrameWithoutBlankLineIsFlushed() {
        let truncated = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"tail"}}
        """
        #expect(Self.decodeEvents(from: truncated, flushTrailingFrame: false).events.isEmpty)

        let (flushed, _) = Self.decodeEvents(from: truncated)
        guard flushed.count == 1, case .contentDelta(let text) = flushed[0] else {
            Issue.record("expected the buffered frame to flush, got \(flushed)")
            return
        }
        #expect(text == "tail")
    }

    @Test("a non-SSE body reports unparseable frames rather than silent emptiness")
    func nonSSEBodyIsAttributable() {
        // What an error envelope or a non-streaming JSON response looks like coming back 200.
        let (events, decoder) = Self.decodeEvents(from: "data: {\"not\": \"an\", \"event\"\n\n")
        #expect(events.isEmpty)
        #expect(decoder.frameCount == 1)
        #expect(decoder.unparseableFrameCount == 1)
    }

    @Test("the splitter emits byte lines, so no Swift String newline semantics are involved")
    func splitterEmitsByteLines() {
        // Guards the grapheme trap directly: "\r\n" is ONE Swift Character, so any String-level
        // newline split leaves a CRLF frame whole. Framing must stay in bytes.
        var splitter = SSEFrameSplitter()
        var frames: [SSEFrame] = []
        for byte in Array("event: a\r\ndata: 1\r\n\r\nevent: b\ndata: 2\n\n".utf8) {
            if let frame = splitter.consume(byte) { frames.append(frame) }
        }
        #expect(frames.count == 2)
        #expect(splitter.sawCarriageReturn)
        #expect(frames.first?.lines.count == 2)
        #expect(frames.first.map { String(decoding: $0.lines[0], as: UTF8.self) } == "event: a")
        #expect(frames.last.map { String(decoding: $0.lines[1], as: UTF8.self) } == "data: 2")
    }

    @Test("multiple data lines in one frame concatenate per the SSE grammar")
    func multiLineDataFrameConcatenates() {
        let body = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\ndata: \"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"split\"}}\n\n"
        let (events, decoder) = Self.decodeEvents(from: body)
        #expect(decoder.unparseableFrameCount == 0)
        #expect(Self.text(in: events) == "split")
    }

    @Test("leading and repeated blank separators do not produce empty frames")
    func blankSeparatorsAreNotFrames() {
        let body = "\n\n" + Self.skillActivationSSEBody + "\n\n"
        let (events, decoder) = Self.decodeEvents(from: body)
        #expect(decoder.unparseableFrameCount == 0)
        #expect(Self.text(in: events) == "I can see the 'writing-plans' skill is available")
    }

    // MARK: - Parser -> stream -> accumulator

    @Test("fixture survives parser, stream, and AssistantMessageAccumulator intact")
    func fixtureSurvivesFullPipeline() async throws {
        let (results, terminal) = try await runStream(events: Self.decodeEvents(from: Self.skillActivationSSEBody).events)
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

    @Test("localizedDescription carries the detail, not Foundation's placeholder")
    func localizedDescriptionCarriesDetail() {
        let failure = Self.error(.noEvents)
        #expect(failure.localizedDescription == failure.detail)
        #expect(failure.localizedDescription.contains("error 1") == false)
    }

    @Test("attempt annotation preserves the concrete type and shows in the description")
    func attemptAnnotationPreservesType() {
        let annotated = Self.error(.noEvents).annotatedWithAttempts(3)
        guard let degenerate = annotated as? DegenerateStreamError else {
            Issue.record("annotation must not wrap away the concrete type, got \(annotated)")
            return
        }
        #expect(degenerate.kind == .noEvents)
        #expect(degenerate.attempts == 3)
        #expect(degenerate.localizedDescription.contains("after 3 attempts"))
        // A single attempt is the un-retried case and reads as noise.
        let once = Self.error(.noEvents).annotatedWithAttempts(1)
        #expect((once as? DegenerateStreamError)?.localizedDescription == Self.error(.noEvents).detail)
    }

    @Test("bridged NSError code distinguishes the kinds")
    func nsErrorCodeDistinguishesKinds() {
        #expect(Self.error(.noEvents).errorCode == 1)
        #expect(Self.error(.announcedToolCallLost).errorCode == 2)
        #expect(Self.error(.noOutcome).errorCode == 3)
        let info = Self.error(.noOutcome).errorUserInfo
        #expect(info["kind"] as? String == "noOutcome")
        #expect(info["provider"] as? String == "Anthropic")
    }

    @Test("RetryAfterRateLimitError also describes itself")
    func rateLimitErrorDescribesItself() {
        // Asserts the hint and the absence of Foundation's placeholder, not the underlying
        // error's own wording, which SwiftAgentKit owns.
        let hinted = RetryAfterRateLimitError(retryAfterSeconds: 7.0)
        #expect(hinted.localizedDescription.contains("retry after 7.0s"))
        #expect(hinted.localizedDescription.contains("error 1") == false)
        #expect(RetryAfterRateLimitError(retryAfterSeconds: nil).localizedDescription.isEmpty == false)
    }

    @Test("a non-streaming response with no content blocks fails instead of returning empty")
    func nonStreamingEmptyResponseFails() {
        // parseMessageResponse feeds compaction summarisation and memory recall, where an empty
        // result silently loses context rather than surfacing anything.
        let failure = DegenerateResponseGuard.failure(
            provider: "Anthropic",
            kind: .emptyResponse,
            text: "",
            toolCalls: [],
            providerReportedStop: false
        )
        #expect(failure?.kind == .emptyResponse)
        #expect(failure?.errorCode == 4)
        // A provider-reported stop with no content stays a legitimate empty turn.
        #expect(DegenerateResponseGuard.failure(
            provider: "Anthropic",
            text: "",
            toolCalls: [],
            providerReportedStop: true
        ) == nil)
    }

    @Test("the shared guard passes any turn that produced something")
    func sharedGuardPassesProductiveTurns() {
        #expect(DegenerateResponseGuard.failure(
            provider: "OpenAI", text: "hi", toolCalls: [], providerReportedStop: false) == nil)
        #expect(DegenerateResponseGuard.failure(
            provider: "OpenAI", text: "", toolCalls: [ToolCall(name: "x", arguments: .object([:]), id: "1")],
            providerReportedStop: false) == nil)
        #expect(DegenerateResponseGuard.failure(
            provider: "OpenAI", text: "", toolCalls: [], sawReasoning: true,
            providerReportedStop: false) == nil)
    }

    @Test("body diagnostics summarise shape only, never content")
    func diagnosticsAreShapeOnly() {
        let diagnostics = AnthropicStreamBodyDiagnostics(
            statusCode: 200,
            contentType: "application/json",
            bodyBytes: 412,
            frameCount: 0,
            unparseableFrameCount: 0,
            eventCount: 0,
            sawCarriageReturn: true,
            droppedOversizedFrame: false
        )
        let summary = diagnostics.summary
        #expect(summary.contains("status=200"))
        #expect(summary.contains("contentType=application/json"))
        #expect(summary.contains("bytes=412"))
        #expect(summary.contains("frames=0"))
        #expect(summary.contains("unparseable=0"))
        #expect(summary.contains("cr=true"))
        #expect(summary.contains("\n") == false)
    }

    @Test("no retry-after hint is invented for a degenerate stream")
    func noRetryAfterHint() {
        #expect(TransientErrorClassifier.retryAfterSeconds(Self.error(.noEvents)) == nil)
        #expect(TransientErrorClassifier.isRateLimited(Self.error(.noEvents)) == false)
    }
}
