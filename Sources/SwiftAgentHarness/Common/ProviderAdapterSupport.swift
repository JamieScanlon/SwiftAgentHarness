//
//  Shared internal helpers used by every `LLMProtocol` adapter to satisfy the
//  ``AdapterContract``.
//
//  Members:
//
//  - ``FinishReason`` — canonical finish-reason vocabulary plus per-provider
//    mappers (Ollama / OpenAI / LM Studio / Anthropic raw strings → `FinishReason`).
//  - ``ToolCallAccumulator`` — dedupes tool calls received via the three observed
//    transport shapes (Ollama final-list dedupe on `done`, LM Studio + OpenAI
//    index-keyed deltas, OpenAI name+args fragment fallback).
//  - ``StreamCompletionEmitter`` — single source of truth for the
//    `.complete`-once invariant on the streaming path (yield `.complete` then
//    `finish()` exactly once on success; throw `CancellationError` on cancel;
//    wrap unknown errors as `LLMError.networkError(_:)` on failure).
//  - ``LMStudioErrorMapping`` — typed `LLMError` mapping for the three LM Studio
//    `NSError` sites the contract replaces (request encoding failure, SSE error
//    event, no-valid-choices). Mirrors `OllamaHTTPStatusMapping` ergonomics.
//

import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Marker namespace anchoring the helper layer that backs ``AdapterContract``.
///
/// Helper types are top-level for ergonomics; this namespace exists so test
/// suites and adapter file headers can cite a single symbol when documenting
/// the contract layering.
enum ProviderAdapterSupport {}

// MARK: - FinishReason

/// Canonical finish-reason vocabulary surfaced on `LLMMetadata.finishReason`.
///
/// Each adapter routes its provider-shaped raw string (Ollama: `done_reason`;
/// OpenAI / LM Studio: `choice.finish_reason`; Anthropic: `stop_reason`) through
/// the matching `from*` mapper before storing the canonical raw value on
/// `LLMMetadata`. Downstream consumers (`TransientErrorClassifier`,
/// `HarnessRuntimeSession`, telemetry) see a stable vocabulary regardless of provider.
///
/// Unknown / unmapped raw values fall through to ``FinishReason/unknown`` so
/// callers always receive a defined case (no `nil` data on success paths).
enum FinishReason: String, Sendable, Equatable {
    /// Natural stop (model emitted EOS / stop sequence).
    case stop
    /// Hit the configured `max_tokens` / `num_predict` ceiling.
    case length
    /// Produced one or more tool calls and is yielding control to the caller.
    case toolCalls = "tool_calls"
    /// Provider-side content moderation halted the response.
    case contentFilter = "content_filter"
    /// Cancelled (consumer cancelled the consuming `Task`).
    case cancelled
    /// Provider-reported error mid-stream.
    case error
    /// Provider returned a finish-reason value the contract does not yet
    /// recognise; surfaced as-is so downstream consumers can log it without
    /// classifying it.
    case unknown

    /// Maps Ollama `done_reason` (e.g. `"stop"`, `"length"`, `"load"`) to the
    /// canonical vocabulary. `nil` raw → ``FinishReason/unknown``.
    static func fromOllama(_ raw: String?) -> FinishReason {
        guard let raw, !raw.isEmpty else { return .unknown }
        switch raw.lowercased() {
        case "stop": return .stop
        case "length": return .length
        case "tool_calls", "toolcalls": return .toolCalls
        case "content_filter": return .contentFilter
        case "cancel", "cancelled", "canceled": return .cancelled
        case "error": return .error
        default: return .unknown
        }
    }

    /// Maps OpenAI `choice.finish_reason` (`"stop"`, `"length"`, `"tool_calls"`,
    /// `"content_filter"`, `"function_call"`) to the canonical vocabulary.
    static func fromOpenAI(_ raw: String?) -> FinishReason {
        guard let raw, !raw.isEmpty else { return .unknown }
        switch raw.lowercased() {
        case "stop": return .stop
        case "length": return .length
        case "tool_calls", "function_call": return .toolCalls
        case "content_filter": return .contentFilter
        default: return .unknown
        }
    }

    /// Maps LM Studio `choice.finish_reason` (OpenAI-shaped: `"stop"`,
    /// `"length"`, `"tool_calls"`) to the canonical vocabulary.
    static func fromLMStudio(_ raw: String?) -> FinishReason {
        guard let raw, !raw.isEmpty else { return .unknown }
        switch raw.lowercased() {
        case "stop": return .stop
        case "length": return .length
        case "tool_calls", "function_call": return .toolCalls
        case "content_filter": return .contentFilter
        default: return .unknown
        }
    }

    /// Maps Anthropic Messages `stop_reason` (`"end_turn"`, `"max_tokens"`,
    /// `"stop_sequence"`, `"tool_use"`, `"refusal"`) to the canonical vocabulary.
    static func fromAnthropic(_ raw: String?) -> FinishReason {
        guard let raw, !raw.isEmpty else { return .unknown }
        switch raw.lowercased() {
        case "end_turn", "stop_sequence": return .stop
        case "max_tokens": return .length
        case "tool_use": return .toolCalls
        case "refusal": return .contentFilter
        default: return .unknown
        }
    }
}

// MARK: - ToolCallAccumulator

/// Dedupes tool calls accumulated mid-stream so the `.complete` value carries a
/// single canonical `[ToolCall]` regardless of the transport-side pattern.
///
/// Three ingest shapes are supported:
///
/// - ``ingestFinalList(_:)`` — Ollama's `/api/chat` resends the full tool list
///   on every chunk (notably on the `done` chunk). Calling this multiple times
///   with identical lists is idempotent.
/// - ``ingestIndexed(index:idDelta:nameDelta:argumentsDelta:)`` — LM Studio and
///   OpenAI both expose tool-call deltas keyed by an `index` so name / arguments
///   accumulate across SSE chunks.
/// - ``ingestNameAndArgs(id:name:argumentsFragment:)`` — OpenAI's per-delta
///   `tool_calls[]` lacks a stable `index` in some SDK versions; this fallback
///   merges by `(name, arguments)` once name is known.
///
/// ``finalize()`` collapses everything into a single `[ToolCall]`, deduping by
/// `id` first (when present) and falling back to `(name, arguments)` to catch
/// repeats that lost their id (Ollama). When a final list is present it is
/// processed first and wins on id collision; indexed and fragment entries fill
/// gaps only.
struct ToolCallAccumulator {

    /// Indexed entries (LM Studio / OpenAI delta path).
    private var indexed: [Int: PartialIndexedCall] = [:]

    /// Final lists ingested verbatim (Ollama). We keep the latest non-empty
    /// list and dedupe per id / `(name, arguments)` against the indexed pool.
    private var finalList: [ToolCall] = []
    private var hasFinalList = false

    /// Name+args fragment entries (OpenAI fallback). Keyed by id when present,
    /// else by name. Kept separate from `indexed` so the two paths cannot
    /// double-count the same logical call.
    private var byIdOrName: [String: PartialNamedCall] = [:]

    /// Key of the most recent name-bearing fragment; used to attach args-only
    /// deltas that omit id and name (LM Studio second SSE chunk).
    private var lastOpenFragmentKey: String?

    private struct PartialIndexedCall {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    private struct PartialNamedCall {
        var id: String?
        var name: String
        var arguments: String = ""
    }

    init() {}

    /// Ingest a complete tool list (Ollama `done`-chunk path). Idempotent: the
    /// most recent non-empty list wins.
    mutating func ingestFinalList(_ calls: [ToolCall]) {
        guard !calls.isEmpty else { return }
        finalList = calls
        hasFinalList = true
    }

    /// Ingest an index-keyed delta. Subsequent calls for the same `index`
    /// accumulate name (last-non-nil wins) and arguments (concatenated).
    mutating func ingestIndexed(
        index: Int,
        idDelta: String? = nil,
        nameDelta: String? = nil,
        argumentsDelta: String? = nil
    ) {
        var entry = indexed[index] ?? PartialIndexedCall()
        if let idDelta, !idDelta.isEmpty {
            entry.id = idDelta
        }
        if let nameDelta, !nameDelta.isEmpty {
            entry.name = nameDelta
        }
        if let argumentsDelta, !argumentsDelta.isEmpty {
            entry.arguments += argumentsDelta
        }
        indexed[index] = entry
    }

    /// Ingest a name+args fragment (OpenAI fallback). Repeated calls with the
    /// same `id` (or, if `id` is nil, the same `name`) accumulate arguments.
    /// Args-only deltas without a name merge into the entry keyed by `id` or
    /// ``lastOpenFragmentKey`` when present.
    mutating func ingestNameAndArgs(
        id: String?,
        name: String?,
        argumentsFragment: String?
    ) {
        if let name, !name.isEmpty {
            let key: String = id?.isEmpty == false ? id! : "name:\(name)"
            var entry = byIdOrName[key] ?? PartialNamedCall(id: id, name: name)
            if let id, !id.isEmpty { entry.id = id }
            entry.name = name
            if let argumentsFragment, !argumentsFragment.isEmpty {
                entry.arguments += argumentsFragment
            }
            byIdOrName[key] = entry
            lastOpenFragmentKey = key
            return
        }

        guard let argumentsFragment, !argumentsFragment.isEmpty else { return }

        if let id, !id.isEmpty, var entry = byIdOrName[id] {
            entry.arguments += argumentsFragment
            byIdOrName[id] = entry
            lastOpenFragmentKey = id
            return
        }

        if let key = lastOpenFragmentKey, var entry = byIdOrName[key] {
            entry.arguments += argumentsFragment
            byIdOrName[key] = entry
        }
    }

    /// Collapse all ingested deltas into a single deduped `[ToolCall]`.
    ///
    /// Dedupe priority:
    /// 1. Final list (when present) is authoritative and processed first.
    /// 2. Indexed and name+args fragments fill only ids / name+args not yet seen.
    /// 3. When an entry lacks an `id`, equality is judged by `(name, arguments)`.
    func finalize() -> [ToolCall] {
        var ordered: [ToolCall] = []
        var seenIds: Set<String> = []
        var seenNameArgs: Set<String> = []

        func appendIfNew(_ call: ToolCall) {
            if let id = call.id, !id.isEmpty {
                if seenIds.contains(id) { return }
                seenIds.insert(id)
                let key = nameArgsKey(name: call.name, arguments: call.arguments)
                seenNameArgs.insert(key)
                ordered.append(call)
                return
            }
            let key = nameArgsKey(name: call.name, arguments: call.arguments)
            if seenNameArgs.contains(key) { return }
            seenNameArgs.insert(key)
            ordered.append(call)
        }

        if hasFinalList {
            for call in finalList {
                appendIfNew(call)
            }
        }

        for index in indexed.keys.sorted() {
            guard let entry = indexed[index], let name = entry.name else {
                continue
            }
            let parsedArgs = Self.parseArguments(entry.arguments)
            let resolvedId = entry.id ?? UUID().uuidString
            appendIfNew(ToolCall(name: name, arguments: parsedArgs, id: resolvedId))
        }

        for entry in byIdOrName.values {
            let parsedArgs = Self.parseArguments(entry.arguments)
            let resolvedId = entry.id ?? UUID().uuidString
            appendIfNew(ToolCall(name: entry.name, arguments: parsedArgs, id: resolvedId))
        }

        return ordered
    }

    private func nameArgsKey(name: String, arguments: JSON) -> String {
        let argsString: String
        if let data = try? JSONEncoder().encode(arguments),
           let s = String(data: data, encoding: .utf8) {
            argsString = s
        } else {
            argsString = ""
        }
        return "\(name)|\(argsString)"
    }

    /// Parses an arguments JSON string into the EasyJSON shape used by `ToolCall`.
    /// Empty / unparseable input collapses to `.object([:])` to match the prior
    /// per-adapter behavior.
    private static func parseArguments(_ jsonString: String) -> JSON {
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSON.self, from: data)
        else {
            return .object([:])
        }
        return json
    }
}

// MARK: - DegenerateResponseGuard

/// Shared "did this turn deliver anything?" check for provider adapters.
///
/// Every adapter previously ended its stream with an unconditional `finishSuccess` (or, worse, a
/// bare `continuation.finish()`), so a turn that produced nothing was indistinguishable from a
/// model that chose to say nothing. That is the DEF-135 shape; this centralises the rule so the
/// adapters cannot drift apart on it.
///
/// A turn is legitimately empty only when the provider *reported a terminal stop reason* —
/// `end_turn` with no text is rare but real. Anything else with no text, no tool calls, and no
/// reasoning is a failure.
enum DegenerateResponseGuard {
    static func failure(
        provider: String,
        kind: DegenerateStreamError.Kind = .noOutcome,
        text: String,
        toolCalls: [ToolCall],
        sawReasoning: Bool = false,
        providerReportedStop: Bool,
        detail: String? = nil
    ) -> DegenerateStreamError? {
        guard text.isEmpty, toolCalls.isEmpty, !sawReasoning else { return nil }
        guard !providerReportedStop else { return nil }
        return DegenerateStreamError(
            kind: kind,
            provider: provider,
            detail: detail ?? "\(provider) stream produced no text, tool calls, or finish reason"
        )
    }
}

// MARK: - StreamCompletionEmitter

/// Single source of truth for the `.complete`-once invariant on the streaming
/// path. Wraps an `AsyncThrowingStream` continuation and exposes the four
/// terminal moves an adapter is allowed to make.
///
/// - Success: ``finishSuccess(with:)`` yields `.complete` exactly once and then
///   calls `continuation.finish()`. A second call traps in DEBUG and silently
///   no-ops in release so a misbehaving adapter cannot double-publish.
/// - Cancellation: ``finishCancelled()`` finishes the stream with
///   `CancellationError`. No `.complete` is yielded.
/// - Failure: ``finishFailed(with:)`` finishes the stream with the supplied
///   error. `LLMError` instances pass through unchanged; everything else is
///   wrapped as `LLMError.networkError(_:)` so `TransientErrorClassifier` can
///   recurse.
///
/// `.stream` chunks go through ``yieldStream(_:)`` for symmetry; the emitter
/// does not attempt to validate chunk content.
struct StreamCompletionEmitter {

    typealias Continuation = AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error>.Continuation

    let continuation: Continuation

    /// Tracks whether `finishSuccess` already ran, so the contract's
    /// `.complete`-once invariant can be enforced.
    private let didCompleteBox: DidCompleteBox

    init(continuation: Continuation) {
        self.continuation = continuation
        self.didCompleteBox = DidCompleteBox()
    }

    /// Yields a streaming chunk to the consumer. Pass-through; no validation.
    func yieldStream(_ chunk: LLMResponse) {
        continuation.yield(.stream(chunk))
    }

    /// Yields the final `.complete(LLMResponse)` and finishes the stream
    /// successfully. Calling this more than once traps in DEBUG and is a
    /// silent no-op in release.
    func finishSuccess(with final: LLMResponse) {
        if didCompleteBox.markCompleted() {
            assertionFailure("StreamCompletionEmitter.finishSuccess called more than once; the AdapterContract guarantees `.complete`-once.")
            return
        }
        continuation.yield(.complete(final))
        continuation.finish()
    }

    /// Finishes the stream with `CancellationError`. The contract forbids
    /// emitting a `.complete` on the cancellation path; this method does not
    /// touch the `didComplete` flag.
    func finishCancelled() {
        continuation.finish(throwing: CancellationError())
    }

    /// Finishes the stream with the supplied error. `LLMError`, `CancellationError`, and
    /// ``DegenerateStreamError`` pass through unchanged; every other `Error` is wrapped as
    /// `LLMError.networkError(_:)`.
    ///
    /// ``DegenerateStreamError`` is exempt from the wrap because the response arrived fine —
    /// it was its *shape* that was unusable. Relabelling it `.networkError` would both mislead
    /// anything that inspects the terminal error and bury the kind that callers need to tell a
    /// truncated stream apart from a dropped connection.
    func finishFailed(with error: Error) {
        if error is CancellationError {
            continuation.finish(throwing: CancellationError())
            return
        }
        if let llmError = error as? LLMError {
            continuation.finish(throwing: llmError)
            return
        }
        if let degenerate = error as? DegenerateStreamError {
            continuation.finish(throwing: degenerate)
            return
        }
        continuation.finish(throwing: LLMError.networkError(error))
    }

    /// Reference holder so ``StreamCompletionEmitter`` can stay a `struct`
    /// while the `.complete`-once flag is shared across copies handed to nested
    /// closures.
    /// Use of @unchecked Sendable is valid here
    final class DidCompleteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var didComplete = false

        /// Returns `true` if completion was already recorded (i.e. this is a
        /// duplicate call), `false` on first call.
        func markCompleted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if didComplete { return true }
            didComplete = true
            return false
        }
    }
}

// MARK: - LMStudioErrorMapping

/// Maps the three LM Studio `NSError` failure sites the contract replaces to
/// typed ``LLMError`` cases. Mirrors `OllamaHTTPStatusMapping` ergonomics so
/// `TransientErrorClassifier` can classify LM Studio failures the same way.
///
/// Per-HTTP-status precision (e.g. distinguishing 408 / 429 / 5xx surfaced
/// through `RestAPIManager`) is blocked on upstream `RestAPIManager` exposing
/// status codes through its throwing surface; once available, this mapping
/// gains an HTTP-status branch.
enum LMStudioErrorMapping {

    /// Wraps a request-encoding failure (`requestBodyToDictionary` could not
    /// serialise the request body to a dictionary).
    static func requestEncodingFailure(_ underlying: Error) -> LLMError {
        return .invalidRequest("LM Studio request encoding failure: \(underlying.localizedDescription)")
    }

    /// Wraps an SSE `event: error` payload (server-side error reported mid-stream).
    static func sseErrorEvent(message: String) -> LLMError {
        return .invalidResponse("LM Studio SSE error: \(message)")
    }

    /// Wraps a missing-`choices` failure (stream ended without yielding any
    /// usable choices).
    static func noValidChoices(chunkCount: Int) -> LLMError {
        if chunkCount == 0 {
            return .invalidResponse("LM Studio stream ended without receiving any data chunks")
        }
        return .invalidResponse("LM Studio stream ended after \(chunkCount) chunks but none contained valid choices")
    }

    /// Generic mapper used by call sites that have already classified intent
    /// (e.g. `requestEncodingFailure(...)`); kept for parity with
    /// `OllamaHTTPStatusMapping.validate`.
    static func map(_ raw: Error) -> LLMError {
        if let llmError = raw as? LLMError { return llmError }
        return .networkError(raw)
    }
}
