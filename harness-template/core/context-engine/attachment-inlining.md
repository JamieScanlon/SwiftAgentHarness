# Attachment inlining policy

## TL;DR

Attachments — files, URLs, images, datasets a user or agent attached to the conversation — are **metadata plus a byte reference** owned by the [Conversation Manager](../conversation-manager/README.md#attached-resources); what the model actually *sees* is a per-attachment, per-turn representation decision the Context Engine makes at projection time. The decision is a **three-rung ladder**: **inline** (full content), **digest** (a bounded summary plus instructions for getting more), or **reference** (a metadata line; the model pulls content through tools on demand). Pick the smallest rung that serves the current turn, chosen from size vs. budget, modality vs. the active model's capability record, trust class, and recency of use — and **demote over time**: an attachment inlines while hot, drops to digest as turns pass without access, and parks at reference when cold, with re-promotion happening through the tool path rather than re-inlining. Attachment bytes never enter `rawEvents` (the raw log records the attach *event*; the projection materializes content), expensive digests are cached as Checkpoints keyed on content hash, and trust class controls envelope-wrapping at *every* rung — a digest of hostile content is still hostile content.

---

## Recommendation

### Where the seam sits

Three layers touch an attachment and each owns exactly one thing. The **Conversation Manager** owns metadata and lifecycle: `id`, `kind`, `name`, `mimeType`, `size`, `addedBy`, and — the part most easily lost — the **trust class** (`user-direct` for user uploads, `unknown-party` for agent-fetched content). The **persistence backend** owns the bytes, referenced from the attachment record, never embedded in the Conversation. The **Context Engine** owns representation: at `assembleForTurn`, it reads the current attachment list and decides, per attachment, what this turn's projection will carry. The Manager never transforms content; the Engine never mutates metadata.

This split is why the policy can be *per-turn*: nothing about an attachment's stored form changes when its representation does. The same PDF can be inline on turn 3, a digest on turn 20, and a one-line reference on turn 60 — three projections, one artifact.

### The representation ladder

**Rung 1 — inline.** The full content, materialized into the projection's Attachments section. Correct for small, task-central, actively-used artifacts: the config file being edited, the screenshot being discussed, the CSV under analysis. Inline is the only rung with zero interaction cost — the model doesn't spend a tool round-trip to see the content — which is exactly why it's rationed.

**Rung 2 — digest.** A bounded representation plus a pointer: for text, a structural summary or head/tail excerpt with an elision marker recording total size; for datasets, the schema plus head rows; for images on a vision model, a downscaled rendition; for documents, an extracted outline. Every digest carries the recovery instruction — the attachment id or workspace path and the tool that reads it — so the digest is a *lossy view with a receipt*, never a silent substitute. This is the same recoverability principle as the tool-result spill pattern ([result-formatting § spill, don't truncate](../tool-system/result-formatting.md)): the model that needs byte 100,001 can go get it.

**Rung 3 — reference.** One metadata line: name, kind, size, how to access. Costs a few tokens; keeps the attachment *discoverable* — the model knows it exists and can promote it itself by reading it. Cold attachments, bulk uploads, and anything the conversation hasn't touched in a long while live here.

The selection rule: **the smallest rung that serves the current turn.** When in doubt between rungs, choose the smaller one — the ladder's whole design is that under-provisioning is recoverable (the model reads more via tools) while over-provisioning is a permanent per-turn tax.

### Decision inputs

The rung is a function of five inputs, all available at assemble time:

- **Size vs. budget.** A per-turn attachment budget (a share of the assembled prompt, junior to the conversation tail — same seniority logic as [memory-injection.md](./memory-injection.md)) and a per-attachment inline ceiling. Text under the ceiling and inside the budget inlines; over either, it digests. Nothing displaces the most recent user message, ever.
- **Modality × model capability.** The active model's capability record ([Model Pool](../model-pool/)) gates the ladder: an image on a `vision: false` model *cannot* inline — it goes through a text-extraction pass (OCR / description via a capable model, cached as a digest) or sits at reference with an honest marker ("image attached; active model cannot view images"). Never send bytes the model can't decode and let the provider error explain it.
- **Trust class.** Orthogonal to the rung — it controls *wrapping*, not *size* (next section).
- **Recency of use.** Watch tool calls and conversation references. An attachment read or edited in the last few turns is hot; one untouched for N turns demotes a rung. This is the working-set heuristic that keeps image-heavy and upload-heavy conversations viable.
- **Count pressure.** Per-kind caps in addition to byte budgets: keep the K most recent images inline (K small — images are the fastest way to fill a context) and demote older ones to `[image: name, dimensions — attach-id]` markers. Same shape as keeping the 5 most recent tool results.

Modality defaults worth shipping: text/code inlines under the ceiling with head/tail truncation-to-digest above it; images inline under the count cap *after* the sanitization ladder (magic-byte MIME inference, downscale/recompress to provider caps — the dispatch-boundary pass from [result-formatting](../tool-system/result-formatting.md) applies to attachments identically); datasets digest by default (schema + head rows — a million-row CSV is never task-central in raw form); URL attachments default to *reference* (fetch-on-demand through the web tool, which applies its own trust envelope) rather than eager fetching at attach time.

### Bytes never enter the raw log

`rawEvents` records the attach event — `{kind: "attachment-added", attachmentId, metadata}` — and nothing else. Content materializes only in projections. Three properties follow. **The raw log stays lossless-but-small:** branching, search, and replay don't drag gigabytes of file bytes through every operation. **Representation stays revisable:** since no projection is stored, this turn's rung choice doesn't commit any future turn. **Replacement works:** a user re-uploading a corrected file updates the attachment record; the next projection materializes the new content, and stale cached digests invalidate via content hash.

The corollary for cache discipline ([cache-aware-operations.md](./cache-aware-operations.md)): an inlined attachment must materialize **byte-identically and at a stable position** across the turns it stays inline — materialize once per rung decision, reuse the rendering, and treat rung *changes* as the deliberate cache events they are, batched at natural break points rather than drifting turn by turn.

### Digest caching

Digesting is the expensive rung — an LLM summarization or extraction pass — so it runs once per (content, policy) pair, cached through the Engine's standard machinery: an **`AttachmentDigest` Checkpoint** in `derivedEvents`:

```
AttachmentDigest extends Checkpoint {
  attachmentId: string
  contentHash: string      // hash of the bytes digested
  digest: ContentBlock[]   // the bounded representation
}                          // policy fingerprint comes from the Checkpoint base (configFingerprint)
```

Validity is content-hash match plus config-fingerprint match — no raw-prefix term, because a digest depends on the attachment's bytes, not conversation position, which also means it survives compaction and inherits cleanly across branches (see [conversation-manager § branching](../conversation-manager/README.md)). It's optional in the same sense `SystemPromptAssembly` is — harnesses that only ever inline or reference never emit it.

One rule for *how* digests are produced: **the digest pass is a tool-less, envelope-aware call.** It processes attachment content — frequently `unknown-party` content — so it runs with no tool access and with the same untrusted framing the main model would see. A summarizer that can execute tools while reading a hostile PDF is an injection amplifier with a cache.

### Trust wrapping at every rung

The trust class travels with the attachment through every representation. `user-direct` uploads render plain. `unknown-party` content — anything the agent fetched, anything that arrived through a channel or trigger — gets the full content envelope from [input-provenance](../../surfaces/triggers/input-provenance.md) (random-ID boundary markers, special-token sanitization, source metadata block) around whichever rung renders: the inline body, the digest, even the reference line's name field (filenames are attacker-controlled strings too).

The subtle case is the digest: summarization does not launder trust. A digest of `unknown-party` content is itself `unknown-party` — the summarizer can be steered, and instruction-shaped text survives summarization more often than not. The digest inherits the source's trust class and wraps accordingly.

### Interaction with compaction

Two touchpoints, both already load-bearing in [compaction.md](./compaction.md):

- **Strip before summarizing.** Images and document blobs are replaced with `[image]` / `[document]` markers in the messages sent to the compaction summarizer — they don't carry into a text summary and they inflate the request. The attachment *list* survives compaction untouched (it's Manager state, not message history), so nothing is lost: post-compaction turns re-materialize whatever rung the policy assigns.
- **Post-compaction re-injection is rung promotion.** The "re-read the 5 most-recently-accessed files fresh" step is this page's policy applied at a specific moment: compaction just destroyed in-context file content, so the hot working set gets promoted back to inline for one turn. Same mechanism, same budgets — implement it as the attachment policy's post-compaction pass rather than a parallel code path.

---

## Alternatives

**Always-inline.** Every attachment, full content, every turn. Correct for harnesses with small, few, text-only attachments — and it's where everyone starts. It fails on the first image-heavy conversation or bulk upload, and it fails *quietly*: the cost is a context window that fills three times faster, misattributed to chatty conversation. The ladder with generous ceilings degrades to always-inline in the easy cases anyway.

**Filesystem-only (no inlining at all).** Attachments land as files in the workspace; the model discovers and reads them through the same file tools it uses for everything else, with the spill/offset machinery bounding size. Genuinely attractive for coding harnesses — one uniform content path, zero new machinery, and the working set self-selects. The cost is first-touch latency and visibility: the model must *decide* to look, and a user who attached a screenshot expects the agent to have seen it without being told to open it. A reference-rung-only policy is this alternative expressed inside the ladder; the hybrid (inline the first materialization, reference thereafter) usually beats the pure form.

**RAG-index large attachments.** Chunk-embed big documents at attach time; each turn retrieves relevant chunks into context. The right call for the corpus case — hundreds of pages, recurring queries — and wrong as the default: it adds an embedding dependency, retrieval-quality failure modes, and stale-index hazards for artifacts a digest-plus-tools handles fine. Reserve it for a designated `dataset`/`corpus` attachment kind rather than applying it to every PDF.

**Provider-native file APIs.** Upload the attachment to the provider once, reference it by file id in subsequent calls. Offloads bytes from every request and lets the provider do the multimodal heavy lifting — at the cost of a per-provider integration, provider-side lifecycle management (expiry, deletion, region), and a portability seam right where the [Model Pool](../model-pool/) wants substitutability. Treat it as a provider-binding optimization behind the same ladder: the *policy* still picks the rung; the binding picks the transport.

---

## Anti-patterns

- **Attachment bytes in `rawEvents`.** Embedding file content in the raw log bloats every branch, search, and replay operation, and freezes one representation forever. The log records that an attachment arrived; projections decide what it looks like.

- **Unbounded image inlining.** Images are the fastest context-filler per unit of user intent, and re-inlining every screenshot every turn is the canonical image-heavy blowup. Count caps, recency demotion, and the downscale ladder — all three.

- **Silent truncation instead of digest-with-receipt.** Clipping a file at N bytes with no marker and no recovery path gives the model a *false file* — it acts on content that doesn't exist. Every lossy representation names what was elided and how to get it. (Same rule as tool-result formatting; attachments don't get an exemption.)

- **Digesting with tools enabled.** The summarization pass reads untrusted content; giving it tool access converts a prompt-injection *attempt* into a tool *execution*. Tool-less, envelope-aware, always.

- **Trust laundering through summarization.** Tagging a digest of `unknown-party` content as clean because "the model rewrote it" is exactly backwards. Trust class is inherited from the source, at every rung, including through the digest cache.

- **Re-digesting unchanged content.** An attachment summarized on every turn (or on every session resume) is the no-cache failure — one LLM call per turn for identical output. Content-hash-keyed `AttachmentDigest` Checkpoints exist so the expensive rung runs once.

- **Rung churn.** A policy that flips an attachment between inline and digest turn-over-turn (size right at the ceiling, oscillating recency) breaks the cache-stability contract and whipsaws the model's view. Hysteresis on the thresholds; rung changes batched at break events.

- **Attachments displacing the conversation.** The budget is a share, and it's junior: a projection that carries three inlined PDFs while trimming the user's recent turns has inverted its priorities. Under pressure, demote rungs before touching the tail — and never touch the latest user message.

- **Eager-fetching URL attachments at attach time.** Fetching on attach runs hostile content through the pipeline before anyone asked for it and snapshots a page nobody may ever read. URLs sit at reference until a turn actually needs them; the fetch tool's own provenance machinery then applies.

- **Letting the provider error explain modality gaps.** Sending an image to a text-only model and surfacing the 400 teaches the user nothing. The capability record is known at assemble time; render the honest marker and offer the extraction path instead.

---
