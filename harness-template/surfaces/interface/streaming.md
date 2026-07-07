# Streaming — Recommended Architecture

## TL;DR

Streaming is how partial output reaches a surface while the model is still generating. The architecture-level call is on the [interface README](./README.md) (§ Recommendation 4–5): **granularity is a surface capability, not a global setting.** This page goes deeper on the two delivery layers, the chunker internals, pacing, and cancellation.

The prescriptive shape:

1. **A capability ladder, chosen per surface and per attachment.** `token-delta` → `block` → `preview-edit` → `final-only`. The surface picks the rung it can afford; two surfaces on the *same* conversation render the *same* event stream at different rungs. There is no single "streaming on/off" switch.
2. **Two distinct delivery layers, kept separate.** **Block streaming** emits completed coarse blocks as *normal* messages as the model writes. **Preview streaming** updates *one temporary* message in place (`off` / `partial` / `block` / `progress`). They have different message semantics, different rate-limit profiles, and different failure modes; conflating them produces double-streamed output. Accept that **true token-delta streaming to channel messages does not exist** — a channel "token stream" is one edit per token and instant rate-limit death.
3. **A code-fence-aware block chunker.** Buffer model text; emit when it crosses `minChars`; prefer a break before `maxChars` using a preference ladder (`paragraph → newline → sentence → whitespace → hard`); **never split inside a code fence** — close and reopen the fence when a hard split is forced so Markdown stays valid. Clamp `maxChars` to the surface's `textChunkLimit` so a per-surface hard cap can't be exceeded.
4. **Coalescing and human-pacing as anti-spam, opt-in.** Merge consecutive blocks on an idle gap (`idleMs`) with a `minChars` floor so chatty channels don't get single-line spam; optionally insert a randomized inter-bubble delay (≈800–2500ms) so multi-bubble replies don't feel robotic. Both trade latency for legibility — enable on social channels, keep off on operator surfaces.
5. **Tool-progress as preview, not as messages.** "Searching the web," "reading file" updates keep a multi-step turn visually alive without emitting real, persisted messages.
6. **The terminal is the one surface that token-streams cheaply — so it should.** Render with a differential strategy (only redraw what changed) wrapped in synchronized output for atomic, flicker-free frames. Detail on [tui.md](./tui.md).
7. **Cancellation policy is decided per granularity.** A half-streamed block, a live preview, and a terminal token stream each resolve a mid-turn cancel differently (already-sent blocks persist; previews get a final/cancelled edit; terminal keeps the partial). State it; don't leave it implicit.

The surface subscribes to the conversation event stream at its chosen granularity off the [Communication Layer](../../core/communication-layer/); the chunker and pacing live in the surface's outbound seam. Nothing here is an inner-ring concern — the core emits one ordered event stream and is unaware of how each surface paces it.

---

## Why this belongs in the surface layer

The [Communication Layer](../../core/communication-layer/) carries exactly one ordered event stream per conversation (`conversation/{id}/events`): token deltas, reasoning blocks, tool-call deltas, and committed messages, interleaved in arrival order. It does **not** decide how often a surface flushes, how text is chunked, or whether a channel gets one edited bubble or ten new ones. Those are properties of *where the output is going* — a terminal can repaint 60 times a second; Slack will rate-limit you off the planet if you edit a message per token.

So streaming granularity is a surface capability, sitting in the surface's **outbound seam** (the `sendPayload` / chunker / `textChunkLimit` path the [interface README](./README.md) describes). The same event stream feeds a terminal token-streaming at one rung and a messaging channel block-streaming at another, simultaneously, with no coordination — because each surface consumes the stream independently and paces it for its own medium.

This is the load-bearing reason the [capability-record surface model](./README.md) matters here: a surface declares *which streaming rung it supports*, and core neither assumes token streaming everywhere nor forces the richest surface's cadence onto a channel that can't take it.

---

## The capability ladder

Four rungs, coarsest-affording-surface to finest. A surface picks the highest rung it can sustain without rate-limit or rendering damage.

| Rung | What the surface does | Who can afford it |
|---|---|---|
| **token-delta** | Repaint on every token/delta event | Terminals, native web clients (a stream they own, no per-edit cost) |
| **block** | Emit each completed coarse block as it lands | Most messaging channels (normal messages, paced) |
| **preview-edit** | Keep one temporary message and update it in place | Channels with cheap edits and a thread/preview target |
| **final-only** | Render nothing until the turn completes | Rate-limited, edit-expensive, or batch surfaces |

Two properties make this a *ladder*, not a *mode*:

- **It is per-surface.** A terminal and a channel attached to the same conversation sit on different rungs off the same stream.
- **It is per-attachment, not per-conversation.** The choice belongs to the connected client's capabilities, not to the conversation. The conversation has one event stream; granularity is a read-side decision.

The most common mistake the ladder prevents is assuming token-delta streaming is universal. It is the *exception* (terminals and native web), not the default. Everything channel-shaped lives on `block` or `preview-edit`.

---

## Recommendation

### Two delivery layers, kept separate

There are two genuinely different ways to show progress on a channel, and they should be two mechanisms, not one knob.

**Block streaming** sends assistant output as completed coarse chunks *as normal channel messages*, while the model is still writing. Each block is a real, persisted message. Good for surfaces where new bubbles are cheap and edits are expensive or unavailable. Controlled by a default plus per-channel override (`blockStreaming: on/off`, default off) and a **break boundary**:

- `text_end` — flush blocks as the chunker emits them (stream as you go).
- `message_end` — buffer until the assistant message finishes, then flush (still multi-chunk if the buffer exceeds `maxChars`).

**Preview streaming** keeps *one temporary message* and updates it in place as generation proceeds. Modes:

- `off` — no preview.
- `partial` — single preview replaced with the latest full text.
- `block` — preview updated in chunked/appended steps.
- `progress` — a status/progress preview during generation, replaced by the final answer at completion.

The two layers are mutually exclusive *per channel for a given turn*: if block streaming is explicitly on, skip preview streaming to avoid double-streaming the same content. A surface that supports both should pick one per turn, not run them concurrently.

**Why separate them.** Block streaming's unit is *a committed message in the transcript*; preview streaming's unit is *a mutable scratch message that the final reply supersedes*. They persist differently, they replay differently on reconnect, and they hit platform rate limits differently (N sends vs. N edits of one message). A single "streaming" boolean that tries to cover both ends up doing neither cleanly — preview edits leak into history, or block sends can't be coalesced.

### The block chunker

The chunker is the heart of block streaming. It buffers model text and decides *when* and *where* to cut. The contract:

- **Low bound (`minChars`).** Don't emit until the buffer reaches `minChars` (unless forced by end-of-turn). Prevents tiny fragment spam.
- **High bound (`maxChars`).** Prefer a clean break *before* `maxChars`; if none exists, hard-split *at* `maxChars`.
- **Break-preference ladder.** Search for a safe break in order: `paragraph` (`\n\n`) → `newline` (`\n`) → `sentence` (`.!?` followed by whitespace/end) → `whitespace` → hard break. Take the coarsest break available past `minChars`.
- **Code-fence safety — the non-negotiable rule.** Parse fence spans in the buffer and never choose a break index inside an open ```` ``` ```` fence. When a hard split at `maxChars` would land inside a fence, **close the fence on the outgoing chunk and reopen it on the next** so both halves render as valid Markdown on every channel. A chunker that splits a fence produces broken rendering everywhere downstream — this is the single highest-leverage correctness rule on the page.
- **Per-surface clamp.** `maxChars` is clamped to the surface's `textChunkLimit` (e.g. a platform's hard message-length cap), so chunker config can never exceed what the channel accepts. A per-channel soft cap (e.g. max lines per message) can further split tall replies to avoid UI clipping.

The break logic is a *safe-break search*: for each candidate boundary (paragraph/newline/sentence), accept it only if it falls past `minChars` *and* is not inside a fence span. This keeps the common case (prose) cutting on paragraph boundaries while guaranteeing fenced code never tears.

### Coalescing — merge before send

Streaming blocks as soon as they're ready produces single-line spam on chatty models. Coalescing merges consecutive chunks before they go out:

- Wait for an **idle gap** (`idleMs`) before flushing a merged block — if more text is still arriving, keep accumulating.
- Cap the merge buffer at `maxChars` (flush early if exceeded); keep a `minChars` floor so fragments wait for company (the final flush always sends whatever remains).
- Derive the **joiner** from the break preference (`paragraph` → `\n\n`, `newline` → `\n`, `sentence` → space) so merged text reads naturally.
- Raise the default `minChars` on notably chatty/social channels so progressive output stays useful without flooding.

Coalescing is the lever that makes block streaming feel *progressive* rather than *twitchy*. It costs a little latency (the idle wait) for a lot of legibility.

### Human-pacing between bubbles

Optionally insert a randomized pause between block replies (after the first) so a multi-bubble response doesn't arrive as an instantaneous wall:

- Modes: `off` (default), `natural` (≈800–2500ms randomized), `custom` (`minMs`/`maxMs`).
- Applies **only to block replies** — never to the final reply or to tool summaries, which the user is waiting on.

This is a social-channel affordance. On an operator-facing surface it's pure added latency; keep it off there. The randomization matters — a fixed delay reads as mechanical, which defeats the purpose.

### Preview streaming modes and graceful degradation

Preview streaming's four modes (`off` / `partial` / `block` / `progress`) are not uniformly supported, so the surface must **degrade gracefully**: a channel that can't do a `progress` preview maps it down to `partial` rather than erroring. Two surface-specific realities to honor:

- **Native streaming transports need a target.** Some platforms expose a first-party streaming/typing API that requires a reply-thread target; a top-level DM with no thread can't show the thread-style preview, so fall back to plain edit-based preview there.
- **One preview, replaced by the final reply.** `partial` mode replaces the preview text with the latest; the *final* committed reply supersedes the preview entirely. Don't leave the scratch preview in history as if it were a real message.

Treat preview text as **ephemeral**: it's a liveness affordance, not transcript content. It should not be what reconcile-and-watch replays as history on reconnect — that's the committed message's job.

### Tool-progress preview

A multi-step turn (search → read → synthesize) goes visually dead if the surface shows nothing between tool calls. Surface short progress lines — "Searching the web," "Reading `report.pdf`" — as *preview* updates, not as emitted messages. They keep the turn alive without polluting the transcript or paying the send cost. This rides the same preview channel as `progress`-mode streaming and is the natural default for turns dominated by tool work rather than prose.

### Media single-delivery during streaming

When block streaming can emit media early (an image, a voice note, a file referenced by a delivery directive), remember each delivery for the turn. If the final assistant payload repeats the same media, **strip the duplicate from the final send** so the user doesn't get the attachment twice. Suppress exact-duplicate final payloads entirely; if the final payload wraps already-streamed media in *new* text, send the new text but keep the media single-delivery. (Binary bytes themselves live in the blob store per [persistence](../../backends/persistence/); streaming references them, it doesn't re-upload.)

### Terminal token rendering — the fine rung, done right

The terminal is the one surface that can afford `token-delta`, because it owns its own display and a repaint costs nothing on the wire. Spend that affordance, but render *differentially* so it doesn't flicker:

- **Three strategies.** (1) *first render* — output all lines without clearing scrollback; (2) *width change or change above the viewport* — clear and full re-render; (3) *normal update* — move the cursor to the first changed line, clear to end, render only changed lines.
- **Synchronized output.** Wrap every update in synchronized-output markers (`\x1b[?2026h … \x1b[?2026l`) so the terminal swaps the frame atomically — no partial-frame tearing.
- **A minimal component contract.** `render(width) → string[]`, one string per line, each line no wider than `width`; reset styles (SGR + hyperlink/OSC 8) at the end of every line so styling never bleeds across lines.

Full treatment of the renderer and component model is on [tui.md](./tui.md); the streaming-relevant point is that token-delta is the terminal's rung and differential + synchronized rendering is how you make it flicker-free.

### Cancellation, per granularity

A mid-turn cancel resolves differently at each rung, and the policy must be explicit:

- **token-delta (terminal):** stop repainting, keep the partial text on screen, mark the turn cancelled. Nothing to "unsend."
- **block:** blocks already sent are real messages and stay; flush or discard the in-flight buffer (discard is usually right — a half-block is rarely worth committing) and append a cancellation marker.
- **preview-edit:** resolve the scratch preview with a final edit — either the partial text marked cancelled, or removed — so no live-looking preview is orphaned.
- **final-only:** trivially, render nothing; emit a cancellation notice.

The unifying rule: **already-committed output is immutable** (you can't unsend a channel message), **ephemeral output is resolvable** (a preview can be edited to a terminal state), and the partial buffer is **discarded unless it's independently meaningful**. Decide this once per rung and apply it consistently.

---

## Alternatives

### Framework-stream passthrough

Lean entirely on a runtime framework's output stream: whatever granularity the framework emits is what the surface renders, with no harness-side chunker or pacing.

**When this works:** for a single-surface, terminal-first harness where the framework already token-streams and the only client is a TUI that can take it. Zero chunker code; the framework does the work.

**Why not as the default:** it has no answer for channels. The framework stream is token-or-block at the framework's granularity, with no `textChunkLimit` clamp, no code-fence safety, no coalescing, no preview/ block split. The moment a messaging surface attaches, you need the chunker and the two-layer model anyway — so build them and treat the framework stream as just another event source feeding the surface's outbound seam.

### One global streaming setting

A single `streaming: on/off` (or one granularity) applied to every surface.

**When this works:** a harness with exactly one surface, forever.

**Why not as the default:** it forces the channel and the terminal onto the same rung. Set it to token-delta and channels rate-limit out; set it to final-only and the terminal feels dead. Granularity is per-surface by nature; a global setting is the wrong axis. (This is the README's § Rec 4 stated as an anti-default.)

### Token-delta edits to channel messages

Emulate token streaming on a channel by editing one message on every token/delta.

**When this works:** essentially never at production cadence — only a toy with one user and a generous platform.

**Why not:** an edit per token is an API call per token. Every mainstream platform rate-limits message edits aggressively; you hit the cap in seconds and the stream stalls or the bot gets throttled. Preview streaming (a *paced* edit cadence, not per-token) is the legitimate version of this idea.

---

## Anti-patterns

- **Assuming token-delta streaming everywhere.** It's the terminal/native-web exception, not the default. Channels get `block` or `preview-edit`. A surface model that bakes in token streaming can't host a messaging channel without rate-limit failure.

- **Splitting a code fence mid-stream.** A break inside a ```` ``` ```` block renders as broken Markdown on every channel. Parse fences; never break inside one; close-and-reopen when a hard split is forced.

- **Running block and preview streaming concurrently on the same turn.** The user sees the content twice — committed blocks *and* a live preview of the same text. Pick one layer per turn; skip preview when block streaming is explicitly on.

- **Letting `maxChars` exceed the channel's hard cap.** If the chunker can emit a block longer than the platform accepts, the send fails or the platform truncates. Clamp `maxChars` to the surface's `textChunkLimit`, always.

- **Streaming every block with no coalescing on chatty channels.** Single-line spam. Coalesce on an idle gap with a `minChars` floor; raise the floor on social channels.

- **Human-delay on the final reply or tool summaries.** Pacing is for *intermediate* block bubbles. Delaying the answer the user is waiting on is just latency. Apply it only between block replies.

- **Preview text persisted as history.** A scratch preview is a liveness affordance, not transcript content. If reconcile-and-watch replays the preview as a real message on reconnect, history is wrong. Keep preview ephemeral; let the committed reply own history.

- **Re-delivering media that already streamed.** Emitting an attachment during streaming and again in the final payload double-sends it (duplicate voice notes/files). Remember per-turn deliveries; strip duplicates from the final send.

- **Flicker from full-screen terminal repaints.** Repainting the whole screen each token tears and flickers. Use differential rendering (redraw only changed lines) wrapped in synchronized output for atomic frames.

- **Undefined cancellation behavior.** If a mid-turn cancel leaves a half-streamed block committed, a live preview orphaned, or a terminal mid-repaint, the surface looks broken. Decide flush/discard/mark-partial per granularity and apply it consistently.

---

## Cross-references

- [Interface README](./README.md) — § Recommendation 4–5 (granularity as a surface capability; the chunker at architecture level), the outbound seam, the capability-record surface model.
- [Communication Layer](../../core/communication-layer/) — the single ordered event stream every surface subscribes to; reconcile-and-watch and replay.
- [tui.md](./tui.md) — the terminal differential renderer and component contract (the `token-delta` rung in depth).
- [approval-ux.md](./approval-ux.md) — pausing a stream for a mid-turn approval.
- [Providers](../../backends/providers/) — the normalized model event stream (`text_delta`, `tool_call` deltas, `usage`) that feeds the chunker.
- [Persistence](../../backends/persistence/) — the blob store streamed media references; committed vs. ephemeral message handling.
