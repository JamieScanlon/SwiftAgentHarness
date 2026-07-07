//
//  Provider Adapter Normalization Contract
//
//  This file documents the behavior every `LLMProtocol` implementation MUST honor. It is the named seam
//  between the SwiftAgentKit `StreamResult<LLMResponse, LLMResponse>` envelope and
//  the per-provider transports (Ollama NDJSON, OpenAI client, LM Studio SSE). Today
//  the contract is honored by `OllamaLLM`, `OpenAILLM`, and `LMStudioLLM` via the
//  helpers in `ProviderAdapterSupport.swift`.
//
//  Alignment status:
//  - Internal `NormalizedEvent` seam is now the canonical adapter boundary contract.
//  - `validateAuth` probing is wired and used by binding failover preflight.
//  - Streaming reasoning/tool-call argument deltas route through normalized mapping where
//    provider transports expose those fields.
//  - Per-HTTP-status precision for `LMStudioLLM` / `OpenAILLM` remains transport-boundary
//    constrained until upstream clients expose response status in thrown errors.
//  - Adapter `getRequestFeatures()` is populated from `Model.requestFeatures` threading.
//
//  The contract:
//
//  1. `send(_:config:)` returns one `LLMResponse` with `isComplete: true`, or
//     throws. Any provider-internal stream-to-aggregate is invisible to the caller.
//
//  2. `stream(_:config:)` yields zero or more `.stream(LLMResponse)` chunks,
//     followed by **exactly one** `.complete(LLMResponse)` on success, then
//     `continuation.finish()`. Tool calls accumulated mid-stream are surfaced on
//     the `.complete` value (also as lifecycle / argument `PartialFragment` chunks
//     governed by `compat.supportsEagerToolInputStreaming` on the registry row).
//
//  3. **Fragment classification** uses `LLMResponse.streamingFragment`. Adapters
//     that cannot classify a delta MUST leave `streamingFragment` nil so the
//     orchestrator's `?? .text(content)` fallback in
//     `SwiftAgentKitOrchestrator.partialFragmentsStream` is the exclusive
//     normalization path. No ad-hoc adapter-side text classification.
//
//  4. **Cancellation** (consumer cancels the consuming `Task`, OR the upstream
//     transport throws `CancellationError`): the adapter throws `CancellationError`
//     from `send`, and `continuation.finish(throwing: CancellationError())` from
//     `stream`. **No** synthesized `.complete`. **No** sentinel tokens injected
//     into content (e.g. the historical `_CANCELLED_` marker).
//
//  5. **Errors** are surfaced as `LLMError`. Provider-shaped errors map to typed
//     `LLMError` cases where statuses are known (`OllamaHTTPStatusMapping` for
//     Ollama, `LMStudioErrorMapping` for LM Studio); unknown failures wrap as
//     `LLMError.networkError(error)` so `TransientErrorClassifier` can recurse.
//     Adapters never finish a stream with raw `Error` / `NSError`.
//
//  6. **Finish reason** is normalized through `FinishReason` and stored on
//     `LLMMetadata.finishReason: String?` as the canonical raw value. Each
//     adapter passes its provider-shaped raw string through `FinishReason.from*`
//     so downstream consumers see a stable vocabulary.
//
//  7. **Tool calls** are deduped through `ToolCallAccumulator`. Duplicate
//     done-chunk repeats (Ollama's `/api/chat` resends the full tool list on the
//     `done` boundary) and out-of-order index fragments (LM Studio SSE deltas)
//     collapse to a single `[ToolCall]` on the `.complete` value.
//
//  8. **Identity properties** (`currentState`, `stateUpdates`) remain default
//     adapter pass-throughs; adapters and wrappers should explicitly forward
//     `getRequestFeatures()` so capability metadata survives outer stack wrapping.
//
//  9. **Auth probe semantics** (`AdapterAuthProbing.validateAuth()`):
//     return `false` only for definitive credential invalidity for the active
//     binding/profile (for example HTTP 401/403). Return `true` for valid auth
//     and for indeterminate/transient transport states to avoid false-negative
//     binding suppression during failover preflight.

import Foundation

/// Marker namespace for the adapter normalization contract.
///
/// Tests and adapter file headers cite this type to anchor the contract. The
/// real behavior lives in:
///
/// - `ProviderAdapterSupport` (helpers the contract depends on),
/// - `OllamaLLM`, `OpenAILLM`, `LMStudioLLM` (the conforming adapters).
enum AdapterContract {}
