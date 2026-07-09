# Result Formatting & Image Sanitization

> Sibling page of [tool-system/README.md](./README.md). What a tool result *is*, how oversized results are bounded without lying to the model, and how image payloads are made provider-safe. The seams these transforms ride on — dispatch-path middleware vs. transcript persist hook — are on [parallel-execution](./parallel-execution.md); the history-aging machinery they cooperate with is on [compaction](../context-engine/compaction.md).

## TL;DR

A tool result is a **list of typed content blocks** (text, image, structured data), not a string — with the model-facing rendering kept distinct from richer display-facing data. Size is governed at **three stages with three different owners**: at *production*, oversized results spill to disk and the model receives a bounded preview plus the file path (recoverable truncation — the model can read more if it needs more); *post-execution*, an opt-in middleware compacts recognizably noisy command output while leaving file reads verbatim and never touching exit codes; *in history*, aged tool results are cleared **in place** with one fixed marker string, preserving the `tool_use`/`tool_result` pair and the prompt-cache prefix. Images get an unconditional sanitization pass at the dispatch boundary: canonicalize the base64, infer the real MIME type from magic bytes (never trust the declared one), downscale/recompress through a quality ladder to fit provider caps, and on failure **replace the block with a text marker instead of failing the call** — a bad image should cost the model one degraded observation, not the whole turn.

---

## Recommendation

### A result is typed content blocks

The result shape that generalizes: an ordered list of blocks — `text`, `image { data, mimeType }`, and optionally structured payloads — plus tool-private display data that never reaches the model. Two disciplines:

- **Separate the model-facing view from the surface-facing view.** The model needs the observation; the TUI wants the diff widget, the row count, the syntax-highlighted preview. Deriving both from one blob couples prompt content to UI needs — the registry entry renders *for the model* deterministically, and surfaces read the structured side ([interface](../../surfaces/interface/README.md)).
- **Render deterministically.** Same result → same bytes. Timestamps, randomized ids, or unordered map iteration inside rendered results silently break the prompt-cache prefix and make transcripts non-replayable. (Same rule as catalog ordering on [schema-and-registration](./schema-and-registration.md).)

### Size discipline in three stages

**Stage 1 — at production: spill, don't truncate.** Each registry entry carries a max-result-size; past it, write the full output to a session-scoped results directory and hand the model a tagged envelope: a bounded preview (~2KB) plus the file path. This is *recoverable* truncation — the model that actually needs byte 100,001 can go read it — which is categorically better than silent cutting. Two details: idempotency (re-persisting the same result id is a no-op, falling through to the preview), and **exemptions where spilling is circular** — a file-read tool's output spilled to a file the model then reads re-enters the same path; file-read tools bound themselves with their own offset/limit contract and set the threshold to infinity.

**Stage 2 — post-execution: opt-in compaction of noisy output.** Shell commands are the pathological producers (test runners, package managers, build logs). An opt-in middleware on the dispatch path ([parallel-execution](./parallel-execution.md)) compacts *recognizably noisy* command output into a shorter structured form, under three hard rules from the studied implementation: it rewrites only the returned result — never the command, never the exit code; it leaves exact-content reads raw (compacting a file read hands the model a false file); and it stays opt-in, because verbatim-everything is a legitimate operator preference. Because it rides the middleware seam, the *persisted* transcript can still retain the fuller output.

**Stage 3 — in history: age in place with a fixed marker.** As turns age, old tool results are the cheapest tokens to reclaim. The proven mechanics: maintain an explicit *compactable-tool set* (file reads, shell output, search results, web fetches — things re-derivable or stale by nature) and replace the aged block's content with **one constant marker string** (`[Old tool result content cleared]`-style). Constant, because a marker with a timestamp or a reason varies per clearing and re-breaks the cache prefix it exists to protect; in place, because *removing* the block orphans its `tool_use` and the provider rejects the request ([compaction](../context-engine/compaction.md) owns that invariant). Anything not in the set — approvals, plan confirmations, sub-agent reports — is protected by default. Trigger policy (token thresholds, time-based aging) belongs to the [Context Engine](../context-engine/README.md); the Tool System's contribution is the set and the marker.

### Image sanitization at the dispatch boundary

Image blocks are the least trustworthy payloads a tool returns — screenshots from headless browsers, channel media, MCP servers with sloppy encodings. Run every image block through one sanitizer at the boundary where results enter the harness:

1. **Canonicalize the base64** (strip data-URL prefixes, whitespace; reject what doesn't decode).
2. **Infer MIME from magic bytes** and prefer it over the declared type — declared types lie, and one mislabeled PNG-as-JPEG fails a whole provider request.
3. **Enforce provider caps by transformation, not rejection.** Downscale/recompress through a descending grid of side lengths × quality steps (never enlarging), taking the first candidate under the byte cap. Caps are provider-reality-driven — the observed limits (dimension caps that fail multi-image requests, hard byte ceilings) live in the provider compat table ([providers](../../backends/providers/README.md)), with conservative defaults (~1200px, ~5MB) and an operator override.
4. **Degrade to a text marker on failure.** Empty payload, undecodable base64, or an image that won't compress under the cap becomes `[label] omitted image payload: <reason>` — the call succeeds with a degraded observation. A tool call that hard-fails because a *screenshot was large* teaches the model to stop taking screenshots.
5. **Log the transform with full metrics** (source/output dimensions, bytes, quality chosen, trigger) — silent recompression is otherwise indistinguishable from source corruption when debugging vision behavior.

Sanitization is *stage-aware*: the same pass runs wherever images cross a boundary — into the model payload, into logs and the event bus (where "sanitize" also means redact/omit — [observability](../../cross-cutting/observability/README.md)), out to channels with their own media limits ([channels](../../surfaces/interface/channels.md)). And it composes with stage 3: **recent images stay byte-for-byte stable** (re-encoding a recent image every turn breaks the cache prefix for no reclaimed value), while aged images are cleared to markers like any other compactable result — they are usually the single largest reclaimable blocks in a long session.

---

## Alternatives

### Bare-string results

Every result a string; images impossible, structure re-parsed by consumers. The floor that every harness outgrows the day it takes a screenshot. Acceptable only for text-tool-only harnesses, and even there the deterministic-rendering rule still applies.

### Unconditional head/tail truncation

Truncate every result at N chars with `...`. Simple, and *irrecoverably lossy* — the model can't get byte N+1 back, and for file reads it acts on a file that doesn't exist. Spill-with-preview costs a directory and buys back correctness.

---

## Anti-patterns

- **Trusting the declared MIME type.** Magic bytes or bust; one mislabeled image fails the entire multi-block request at the provider.
- **Failing the tool call on an unsalvageable image.** The marker degrades one observation; the failure poisons the turn and the model's tool-selection behavior.
- **Truncating exact-content reads.** A compacted or clipped file read is a *false file*; the model edits against content that isn't there. Reads bound themselves via their offset/limit contract instead.
- **Spilling read output to disk.** Read → too big → file → read → the loop. Exempt self-bounding tools from the spill threshold.
- **Variable clearing markers.** A timestamp inside the marker makes every clearing a new prefix; the constant string is the point.
- **Removing aged `tool_result` blocks.** Orphans the `tool_use`; provider rejects. Clear content in place, always.
- **Re-encoding recent images per turn.** Byte-identical recent turns are what keep the cache prefix alive; sanitize once, then leave them alone.
- **One rendering for model and UI.** The prompt inherits UI concerns (colors, alignment, verbosity) and the UI inherits prompt concerns (token budgets); split the views at the result shape.

---

## Cross-references

- [parallel-execution](./parallel-execution.md) — the middleware (dispatch) vs. persist (transcript) seams these transforms ride; history may retain more than the model saw.
- [schema-and-registration](./schema-and-registration.md) — `maxResultSizeChars` and rendering as registry-entry concerns; deterministic-output discipline.
- [compaction](../context-engine/compaction.md) — the tool-pair invariant; where clearing fits among head/middle/tail strategies.
- [providers](../../backends/providers/README.md) — per-provider image caps and payload quirks in the compat table.
- [observability](../../cross-cutting/observability/README.md) — redaction at the emit boundary; the transform metrics worth logging.
- [channels](../../surfaces/interface/channels.md) — per-channel media limits on the outbound side of the same discipline.
