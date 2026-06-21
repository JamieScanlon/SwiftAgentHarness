import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("StreamCompletionEmitter (.complete-once invariant + cancellation/error rewrap)")
struct StreamCompletionEmitterTests {

    // Helper: collect every result yielded by the emitter into an array, capturing the
    // terminal error if one occurs.
    private func collect(
        _ build: @escaping (StreamCompletionEmitter) -> Void
    ) async -> (results: [StreamResult<LLMResponse, LLMResponse>], terminalError: Error?) {
        var results: [StreamResult<LLMResponse, LLMResponse>] = []
        var terminal: Error?
        let stream = AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> { continuation in
            let emitter = StreamCompletionEmitter(continuation: continuation)
            build(emitter)
        }
        do {
            for try await element in stream {
                results.append(element)
            }
        } catch {
            terminal = error
        }
        return (results, terminal)
    }

    // MARK: - Success

    @Test("success path: yields .stream then .complete then finishes; no error")
    func successYieldsStreamThenComplete() async {
        let (results, terminal) = await collect { emitter in
            emitter.yieldStream(LLMResponse(content: "hi", toolCalls: []))
            emitter.finishSuccess(with: LLMResponse(content: "hello", toolCalls: []))
        }
        #expect(terminal == nil)
        #expect(results.count == 2)
        if case .stream(let chunk) = results[0] {
            #expect(chunk.content == "hi")
        } else {
            Issue.record("expected first result to be .stream, got \(results[0])")
        }
        if case .complete(let final) = results[1] {
            #expect(final.content == "hello")
        } else {
            Issue.record("expected second result to be .complete, got \(results[1])")
        }
    }

    // MARK: - .complete-once invariant

    /// The contract documents that calling `finishSuccess` twice traps via
    /// `assertionFailure` in DEBUG and silently no-ops in release. Asserting
    /// the no-op behavior under DEBUG would crash the test process (the trap
    /// is the intended outcome there), so this test runs in release builds
    /// only. Under DEBUG, the trap is exercised implicitly by every adapter
    /// path: any future regression that calls `finishSuccess` twice would
    /// crash an existing contract test instead of silently passing.
    #if !DEBUG
    @Test("calling finishSuccess twice does not yield a second .complete (release no-op)")
    func finishSuccessIsIdempotentInRelease() async {
        let (results, terminal) = await collect { emitter in
            emitter.finishSuccess(with: LLMResponse(content: "first", toolCalls: []))
            emitter.finishSuccess(with: LLMResponse(content: "second", toolCalls: []))
        }
        #expect(terminal == nil)
        #expect(results.count == 1)
        if case .complete(let final) = results[0] {
            #expect(final.content == "first")
        } else {
            Issue.record("expected single .complete, got \(results[0])")
        }
    }
    #endif

    // MARK: - Cancellation

    @Test("finishCancelled finishes the stream with CancellationError; no .complete")
    func finishCancelledThrows() async {
        let (results, terminal) = await collect { emitter in
            emitter.yieldStream(LLMResponse(content: "partial", toolCalls: []))
            emitter.finishCancelled()
        }
        #expect(results.count == 1)
        if case .stream = results[0] {} else {
            Issue.record("expected only a .stream chunk before cancel, got \(results[0])")
        }
        #expect(terminal is CancellationError)
    }

    // MARK: - Failure

    @Test("finishFailed with LLMError rethrows raw without wrapping")
    func finishFailedWithLLMErrorRethrowsRaw() async {
        let (_, terminal) = await collect { emitter in
            emitter.finishFailed(with: LLMError.timeout)
        }
        guard let err = terminal as? LLMError else {
            Issue.record("expected LLMError terminal, got \(String(describing: terminal))")
            return
        }
        switch err {
        case .timeout: break
        default: Issue.record("expected .timeout, got \(err)")
        }
    }

    @Test("finishFailed wraps unknown errors as LLMError.networkError(_:)")
    func finishFailedWrapsUnknownAsNetworkError() async {
        struct BoundaryError: Error {}
        let (_, terminal) = await collect { emitter in
            emitter.finishFailed(with: BoundaryError())
        }
        guard let err = terminal as? LLMError else {
            Issue.record("expected LLMError terminal, got \(String(describing: terminal))")
            return
        }
        switch err {
        case .networkError: break
        default: Issue.record("expected .networkError, got \(err)")
        }
    }

    @Test("finishFailed with CancellationError surfaces as CancellationError (not wrapped)")
    func finishFailedCancellationStaysRaw() async {
        let (_, terminal) = await collect { emitter in
            emitter.finishFailed(with: CancellationError())
        }
        #expect(terminal is CancellationError)
    }
}
