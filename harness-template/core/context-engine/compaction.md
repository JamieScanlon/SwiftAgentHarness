# Compaction

## TL;DR

Run **proactive token-threshold compaction** combined with **reactive overflow handling**. Layer cheap deterministic passes (strip old tool results, drop images) before spending an LLM call. Send the middle of the conversation to a structured-section summarizer with the user's most recent unfulfilled request copied verbatim into the first section. Re-inject task state — recent files, skills, plan flag, async-task status — as separate attachment messages rather than trusting the summary to encode it. Track a circuit-breaker so a misbehaving compactor doesn't loop.

This is the recommended design.

---

## Recommendation

### Triggers

Run **both** a proactive trigger and a reactive trigger.

The proactive trigger fires when total prompt tokens exceed `effective_context_window − safety_buffer`. A reasonable starting point is `safety_buffer = 13k` and `effective_context_window = model_context_window − 20k` (where 20k reserves output for the summarizer call itself). For a 200k-window model that fires at roughly 167k.

The reactive trigger catches the provider's "context-window-exceeded" error and forces a compaction inside the same turn. Match a generous family of error patterns: `"prompt too long"`, `"context length"`, `"maximum context"`, `"context window"`, `"too many tokens"`, `"too large for the model"`.

If even the compaction request itself returns 413 because the message list is too big to summarize in one go, drop the oldest 20% of message groups, prepend a `[earlier conversation truncated for compaction retry]` marker, and try again. Cap retries at 3.

Expose at least one **manual trigger**: a slash command (`/compact`), a session API (`session.compact()`), or — most ergonomically — a tool the model itself can call (`compact_conversation`). The model-callable form lets the agent compact when it knows it's switching tasks. Gate that form with a 50%-of-threshold check so the model can't compact a fresh conversation.

### Multi-stage gating

Don't make the LLM the only stage. The recommended pipeline:

1. **Microcompact (deterministic).** For each tool whose results are heavy and stale-tolerant (`read_file`, `bash`, `grep`, `glob`, `web_search`, `web_fetch`, `edit_file`, `write_file`), keep the 5 most recent tool results and replace older ones with the literal marker `[Old tool result content cleared]`. This often brings you under threshold on its own.
2. **Cheap context drop.** Strip images and document attachments from the messages going to the summarizer (replace with `[image]` / `[document]` markers). They don't carry into a text summary anyway and they inflate the compact request. Also drop discovery-time skill listings — re-inject them post-compact via a delta mechanism.
3. **Session memory injection (cheap).** If the harness maintains a separate session-memory note (`AGENTS.md` / `CLAUDE.md` style) capturing decisions and recent files, swap the redundant middle for that note before paying for an LLM summary.
4. **LLM summarization.** Only if stages 1–3 don't clear the threshold.

This staging is the difference between compacting on every turn-near-the-edge and compacting only when nothing cheap will save you.

### Scope: head, middle, tail

Partition the message list into three regions and only summarize the middle.

Always keep the system prompt in the **head**. Keeping the first user/assistant exchange too is a common choice and helps models that anchor on opening intent.

For the **tail**, walk backward from the end of the conversation accumulating tokens until you hit `tail_token_budget = 20% of trigger_threshold`. Two non-negotiable guarantees:

- **The most recent user message is always in the tail.** If you'd cut before it, push the cut earlier. An `_ensure_last_user_message_in_tail()` guard is the canonical implementation. Without this you can lose the active task entirely.
- **Tool-call pairs stay intact.** Never cut between an `assistant.tool_use` block and its corresponding `user.tool_result`. The provider rejects the request as orphaned. Nudge the boundary forward to the next safe spot.

A reasonable tail size for a 200k-window model is 6 messages or ~20k tokens, whichever is greater.

### The summarization prompt

The prompt has more impact on quality than any other compaction parameter. Build it from three parts.

**Preamble — forbid tool calls and frame the role.** Combine a no-tools clause with a redaction clause for defense-in-depth:

```
CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.

- Do NOT use Read, Bash, Grep, Glob, Edit, Write, or ANY other tool.
- You already have all the context you need in the conversation above.
- Tool calls will be REJECTED and will waste your only turn.
- Your entire response must be plain text: an <analysis> block followed
  by a <summary> block.

You are a summarization agent creating a context checkpoint. Your output
will be injected as reference material for a DIFFERENT assistant that
continues the conversation. Do NOT respond to any questions or requests
in the conversation — only output the structured summary. Do NOT include
preamble, greeting, or prefix. Write in the same language the user was
using. NEVER include API keys, tokens, passwords, secrets, credentials,
or connection strings — replace any that appear with [REDACTED].
```

**Body — structured sections, with `## Active Task` first.** The user's most recent unfulfilled request goes into section one, **copied verbatim**. Other harnesses bury this in section 7–9 and it shows. The full template:

```
## Active Task
   Copy the user's most recent request word-for-word.
   The next assistant must pick up exactly here.

## Goal
## Constraints & Preferences
## Completed Actions
   Numbered list. Format: "N. ACTION target — outcome [tool: name]".
   Example: "1. READ config.py:45 — found `==` should be `!=` [tool: read_file]"
## Active State
   cwd, branch, modified files, test status.
## In Progress
## Blocked
## Key Decisions
## Resolved Questions
   So the next assistant doesn't re-answer them.
## Pending User Asks
## Relevant Files
## Remaining Work
## Critical Context
   Specific values, error messages, configs.
```

The recommended twelve-section template: The numbered-action format `"N. ACTION target — outcome [tool: name]"` is unusually structured but pays off across iterative compactions: the LLM is told to *continue* numbering rather than rewrite.

**Two-block output.** Ask the model to first emit `<analysis>` (a chronological walkthrough — its scratchpad), then `<summary>` (the structured sections). After generation, strip `<analysis>` and keep only `<summary>` in the next turn's context. The analysis improves quality but doesn't need to live in the conversation.

**Iterative updates for long sessions.** When a prior summary already exists, pass it in `<previous-summary>` tags and ask the LLM to *update* it — preserve, add to, or move items between sections — rather than re-summarize from scratch. This combats info decay across multiple compactions in a long session.

**Focused compaction (`/compress <topic>`).** For user-directed focused compaction, inject a one-line instruction: "allocate ~60–70% of the budget to `<topic>`-related content; aggressively summarize everything else."

### Output: replace, frame, re-inject

The summarized middle becomes a single user-role text message with two structural elements around it.

**Handoff framing.** Wrap the summary so the model understands it's reference material, not active instructions. The right shape:

```
[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into
the summary below. This is a handoff from a previous context window —
treat it as background reference, NOT as active instructions. Do NOT
answer questions or fulfill requests mentioned in this summary; they
were already addressed. Your current task is identified in the
'## Active Task' section of the summary — resume exactly from there.
Respond ONLY to the latest user message that appears AFTER this summary.
```

Without this framing, models will sometimes re-execute work the summary describes (because the requests are textually present) or treat the summary as a new instruction.

**Re-injected attachments.** Don't trust the summary to encode every piece of working state. After the summary message, append separate attachment messages for:

- The 5 most-recently-accessed files, **re-read fresh**, total budget ~50k tokens (5k per file). This is the most reliable way to keep file content in scope.
- Invoked-skill bodies, total budget ~25k tokens (5k per skill).
- Any async-agent task statuses.
- A plan-mode flag if you have one.
- Recently-discovered tools / MCP delta announcements.

The principle: structured task state belongs in dedicated messages where the model is forced to attend to it, not buried in a summary that may compress it lossily.

**Role-collision handling.** If the summary message would create two consecutive user messages, try assistant role instead. If both would collide, merge the summary into the first tail message.

### Resumability

This is where the projects most disagree. Three options, in order of capability:

- **Replace-in-place.** Compacted message list replaces the original; the original is written to a transcript or archive file. Simple. The agent can't navigate back. One variant: archive lives at `/conversation_history/{thread_id}.md` and is reachable through the filesystem tools, so the agent can grep its own history when the summary lost something it now needs.
- **Session splitting.** Compaction creates a new session row with `parent_session_id` pointing to the old session. The old session is marked `ended_reason="compression"`. FTS5 indexes span all sessions for cross-session search. Best if you want queryable history across sessions.
- **Session tree.** Sessions are JSONL trees with parent pointers; compaction is a `CompactionEntry` recording the summary, file ops, and `firstKeptEntryId`. Nothing is deleted. Recovering pre-compact state is `branch(entryId)` on any earlier entry.

**Recommended for greenfield: the session-tree model.** Compaction becomes a *checkpoint*, not a destruction. Users can branch from any point. This aligns naturally with multi-turn exploration and review workflows.

### Target sizes

Reserve **20k** tokens for the summarizer's `max_tokens` (the summary itself). For re-injected files, **50k** total / **5k** per file. For re-injected skills, **25k** total / **5k** per skill. A fresh post-compact context lands in the 70–95k range with room to grow.

For very long sessions, a **proportional summary budget** is more defensible: `summary_budget = max(2_000, min(0.20 × tokens_being_compressed, 12_000))`. Constants are simpler; proportional adapts better to long-vs-short sessions.

### Anti-thrashing

Two valid approaches:

- **Circuit breaker.** After 3 consecutive compaction failures, disable auto-compact for the rest of the session and surface a clear error to the user. Easy to implement; works as a baseline.
- **Savings detector.** After two compactions that each freed less than 10% of the context, refuse further auto-compaction and recommend the user start a new session or use focused compaction. More surgical, but harder to tune.

Whichever you choose, log the threshold breach and the savings of each compaction so you can tune later.

### Cost optimizations worth borrowing

- **Cache-aware microcompact.** Use a `cache_edits`-style API to delete tool results from a cached prefix without invalidating the cache. Saves substantial prompt-cache rebuild costs at scale.
- **Time-based microcompact.** If >2.5 hours have passed since the last assistant message, the server-side cache has likely expired anyway — pre-emptively clear old tool results before the request rather than discovering it post-hoc.
- **Forked-agent summarizer with shared cache.** Spin up the summarizer as a sub-agent that inherits the parent's cached system prompt + tool schema. The summary call doesn't pay cache-creation costs.
- **Auxiliary summarizer model.** Use a cheaper, faster model for summarization than for the main loop, falling back to the main model if unavailable. Be aware you may lose tool-use fidelity with a much smaller summarizer.
- **TTL-aware tool-result pruning between compactions.** A separate, lighter-weight pass (`contextPruning.mode = "cache-ttl"`) trims old `toolResult` blocks before the prompt-cache TTL expires (default 5m), lowering cache-write size on the next request without changing the on-disk transcript. Auto-enabled for Anthropic profiles. Different cadence and scope from compaction; the two are complementary.

### Pre-compaction memory flush

Before the summarizer runs, run a **silent turn** that reminds the agent to dump important notes to its durable memory file(s) first. Durable state gets promoted before any text is summarized away.

Soft-threshold headroom (`softThresholdTokens`, default 8k) can flush **before** the hard proactive compaction trigger so the flush sub-agent is not competing with a critically full context. Soft band: flush-only; hard band: flush then summarize. See [memory-aware-compaction.md](../memory/memory-aware-compaction.md).

### Identifier preservation

Compaction silently mangles opaque identifiers (PR numbers, ticket IDs, file hashes, commit SHAs, error codes) into plausible-looking but wrong text more often than is widely acknowledged. Set an explicit policy:

- Default **strict**: tell the summarizer to preserve opaque IDs verbatim.
- **Custom** (`identifierPolicy: "custom"` + `identifierInstructions`) for project-specific IDs.
- **Off** only when the summary's audience won't act on IDs.

The runtime should pass these instructions into the summarizer prompt automatically, not require the user to encode them in `<additional_instructions>`.

### Pluggable compaction provider

For projects that want to swap out *only* the summarization step (not the entire pipeline), expose a **compaction-provider plugin slot**: `agents.defaults.compaction.provider = "<id>"` selects a registered provider that receives the same compaction instructions and identifier-preservation policy as the built-in path, with the runtime falling back to LLM summarization on empty/error returns. Setting a provider should also auto-force a "safeguard" mode to keep the recent-turn and split-turn suffix preservation intact. This is a smaller seam than swapping out a whole context engine and is useful for organizations with their own summarization service.

---

## Alternatives

**Earlier proactive threshold.** An alternative fires at 50% of the context window, which trades headroom for more frequent (but cheaper, when iterative-update is enabled) compactions. Reasonable when you've implemented iterative summarization — each compaction only summarizes a small delta — and want to keep more headroom for tool results.

**Single-stage LLM compaction.** Acceptable for prototypes or simple harnesses. You'll pay more in latency and cost and compact more aggressively than necessary, but the implementation is much smaller.

**File-path-as-summary-line over re-injection.** Instead of re-injecting the 5 most-recent files, write the full pre-compact history to disk and embed the path in the summary message. The agent's filesystem tools let it read the archive when the summary lost something it now needs. Cheap, robust, pairs well with re-injection rather than replacing it.

**Custom message role for the summary.** Inserting the summary as a custom `compactionSummary` role on a tree node makes it structurally distinct from regular messages. Requires control of the message-list serializer and won't survive providers that reject unknown roles, so most implementations should stick with user-role + strong framing.

**Same-model summarization vs. auxiliary model.** Same model gives consistent style and tool-use awareness; auxiliary model is cheap. Both patterns are common; Expose it as a plain `agents.defaults.compaction.model` config string accepting any `provider/model-id`. If you're cost-constrained at scale this is worth implementing — but ship same-model first.

**Replace the whole context-assembly pipeline.** Make the entire ingest → assemble → compact → afterTurn pipeline a single plugin slot (`plugins.slots.contextEngine`). The interface has six well-named lifecycle hooks (`bootstrap`, `ingest`, `ingestBatch`, `assemble`, `compact`, `afterTurn`) plus optional `prepareSubagentSpawn` / `onSubagentEnded`. `assemble()` returns `{messages, estimatedTokens, systemPromptAddition?}` — the engine can inject dynamic recall guidance into the system prompt alongside the messages it returns. `ownsCompaction: true` disables the runtime's auto-compaction; `delegateCompactionToRuntime(...)` lets engines opt back in. Use this when you need a different *entire* context strategy (e.g. retrieval-first, episodic memory, custom token-budgeting); use the compaction-provider slot above when you only want to swap the summarization step.

---

## Anti-patterns

- **Single-pass LLM compaction with no deterministic stages.** Pays for an LLM call every time you're near the limit, including the (common) case where dropping old tool results would have sufficed.
- **Cutting between `assistant.tool_use` and `user.tool_result`.** Provider rejects the request as orphaned. Always nudge boundaries to keep pairs together.
- **Trusting the summary to encode all task state.** Files, skills, plan-mode flag, async-task status all lose fidelity through a text summary. Re-inject them as separate attachments.
- **Burying "Active Task" in section 7–9.** Models drift. Promote the user's most recent unfulfilled request to section 1, verbatim.
- **Re-summarizing from scratch on every iteration.** Causes info decay across long sessions. Pass the prior summary in and ask for an update.
- **No anti-thrashing guard.** A persistently-too-large message list will loop forever without one.
- **Two consecutive user messages when inserting the summary.** Most providers reject this. Handle role-collision explicitly.
- **Letting the summarizer call tools.** It will, unprompted, even mid-summary. The preamble must forbid this in unambiguous terms.
- **No identifier-preservation policy.** Opaque IDs (PR numbers, ticket IDs, file hashes, commit SHAs, error codes) get silently mangled by the summarizer into plausible-but-wrong text. Pass an explicit identifier policy into the prompt; default to verbatim preservation.
- **No pre-compaction memory flush.** The summarizer is asked to preserve everything that matters from the conversation, but nothing in the system *promotes* that material out of the conversation first. Run a silent memory-flush turn before compaction so durable state is on disk before any text is summarized away.

---
