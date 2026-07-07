# Summarization Techniques (Beyond Full Compaction)

## TL;DR

Full context compaction is one tool, not the only one. Layer deterministic pre-compaction hygiene (strip old tool results, drop images, truncate arguments) before spending an LLM call. Use turn-prefix summaries when a compaction cut falls mid-stream. Use branch summaries when the user navigates the session tree away from a dead-end exploration. Use iterative summarization to update an existing summary on second and subsequent compactions rather than re-summarizing from scratch. Use focused compaction when the user is switching tasks and wants to aggressively shed unrelated context.

Each technique is independent and can be adopted without the others.

For the full compaction design (triggers, prompt template, output framing, resumability), see [compaction.md](./compaction.md).

---

## 1. Deterministic Pre-Compaction Hygiene

Run cheap, deterministic passes *before* any LLM call. In practice these often clear the threshold on their own, making the LLM stage unnecessary.

### Tool-result truncation (microcompact)

For each tool whose results are heavy and stale-tolerant, keep only the N most recent results and replace older ones with a short marker. A defensible default: keep the 5 most recent results from `read_file`, `bash`, `grep`, `glob`, `web_search`, `web_fetch`, `edit_file`, and `write_file`, replacing older ones with a `[Old tool result content cleared]` marker.

The marker is intentionally content-free. A blank placeholder is fine — the model shouldn't be reasoning from a stale `bash` result anyway.

**Tool-pair safety.** Never replace a `tool_result` without also checking that its paired `tool_use` isn't in the protected tail. If the `tool_use` is in the tail, the result must stay too or the API will reject the request as an orphaned tool call.

### Informative 1-line tool summaries

Instead of a blank marker, a `_summarize_tool_result()` function replaces large tool outputs with a structured 1-line description that preserves the key signal:

```
[terminal] ran `npm test` -> exit 0, 47 lines output
[read_file] read config.py from line 1 (1,200 chars)
[search_files] content search for 'compress' in agent/ -> 12 matches
[web_search] query='context compaction' (3,412 chars result)
```

This is pure Python/string logic — no LLM call, no latency. The implementation branches per tool name, extracts structured fields from the tool's JSON args, and builds a format string. The key insight is that most of what a tool result says can be reconstructed from its inputs; the result itself usually only adds exit code, char count, and match count.

Worth implementing for any tool whose results are large and whose important facts are compressible to one line.

### Image and document stripping

Before sending the message list to the LLM summarizer, strip images and documents, replacing them with `[image]` and `[document]` markers. They don't carry into a text summary, and including them inflates the compact request token count.

Skill-discovery and skill-listing attachment messages can also be stripped at this stage — they get re-injected post-compact via a delta mechanism rather than being summarized.

### Argument truncation

An alternative approach: truncate tool *arguments* (not just results) to a `trim_token_limit` before the LLM stage. Blunt but cheap. Reasonable as a last-resort gate before the LLM call.

---

## 2. Turn-Prefix Summarization

**Problem.** Context cuts sometimes fall mid-turn: the assistant message was still streaming when the window filled, or a user request arrived just before the boundary. Discarding the partial turn loses context; including the full raw turn bloats the tail.

**Solution .** A targeted, smaller LLM summary scoped to just the in-progress turn. The turn-prefix summary is prepended to the tail as a safe landing point — the model picks up from a complete thought rather than a sentence fragment.

The turn-prefix prompt is separate from the main compaction prompt, shorter, and scoped differently: it only describes what was happening in *this turn*, not the full session history. Allocate a smaller token budget for it: ~50% of reserve for a turn-prefix summary vs ~80% for a full compaction summary.

**When to reach for this.** Any harness that supports streaming or that can compact mid-turn needs something in this category. Without it, the options are either discarding the partial turn (loses context) or pushing the cut backward until a clean turn boundary is found (wastes tail budget). A turn-prefix summary is the cleaner third option.

---

## 3. Branch Summarization

**Problem.** The user navigated to a different point in the session tree (branching off to try a different approach), then returned to the main thread. The exploratory branch represents real work that may inform future decisions — but including its full transcript in the main context pollutes it with dead-end reasoning.

**Solution .** When navigating away from a branch, generate a branch summary prefixed with a navigation marker:

```
The user explored a different conversation branch before returning here.
Summary of that exploration:

[summary of what was tried and why it didn't work out]
```

This keeps a compact record of exploratory work without polluting main compaction. The branch summary uses the same `SUMMARIZATION_SYSTEM_PROMPT` constant as the main compaction function — it's the same structured format, just scoped to the branch messages.

**When to reach for this.** Only relevant if the harness implements a session tree or branching model. If sessions are linear (replace-in-place), there are no branches to summarize. See [compaction.md](./compaction.md) — Resumability section — for the session-tree model.

---

## 4. Iterative / Delta Summarization

**Problem.** On the second and subsequent compactions in a long session, re-summarizing the entire conversation from scratch has two failure modes: it's expensive (the full history is re-processed), and it causes info decay (each pass through the summarizer loses a little more signal, especially for older completed work).

**Solution .** Pass the prior summary alongside the new messages and instruct the LLM to *update* the existing summary rather than generate a new one. The prompt passes the previous summary in `<previous-summary>` tags:

```
Below is an existing context summary, followed by new conversation turns that
have occurred since it was written.

<previous-summary>
{previous_summary}
</previous-summary>

Update the summary to incorporate the new turns. For each section:
- Move items from "In Progress" to "Completed Actions" if they are now done.
- Continue the numbering in "Completed Actions" — do not restart from 1.
- Add new context to "Critical Context" and "Relevant Files" where appropriate.
- Update "Active Task" to reflect the user's current request.
- Remove resolved items from "Blocked" and "Pending User Asks".

Preserve all existing content unless it is explicitly superseded.
```

The numbered-action format in a twelve-section template (`"N. ACTION target — outcome [tool: name]"`) is designed specifically to survive iterative updates: the model is told to continue numbering, so the completed-actions list grows across compactions rather than being rewritten.

**When to reach for this.** Any session long enough to hit the compaction threshold more than once — which in practice means any non-trivial coding session. The first compaction can be a full re-summarization; subsequent ones should be updates. Combine with a prior-summary token budget (e.g., `max(2k, min(0.20 × tokens_compressed, 12k))`) so update summaries don't bloat proportionally to session length.

---

## 5. Focused / Partial Compaction

**Problem.** The user is switching tasks mid-session — the old task's context is no longer relevant and is consuming headroom that the new task needs. A full compaction treats all context equally; the user wants to aggressively shed one topic and preserve another.

**Solution: `/compress <topic>` command.** User-directed partial compaction where the topic is named explicitly. An additional injection into the summarization prompt:

```
The user has requested focused compaction on the topic: "{topic}".
Allocate approximately 60–70% of the summary budget to content related to
this topic. Aggressively summarize everything else.
```

This is the same LLM call as a full compaction, just with a topic-weighting instruction added. The prompt template and section structure are identical.

**When to reach for this.** Whenever the harness exposes a manual compact command, focused compaction is a natural extension — it costs nothing architecturally, just adds a topic parameter to the existing prompt-building path. Gate it so the user can only invoke it when the conversation is past some threshold (e.g. 50% of the context window) to prevent compacting a fresh session.

---

## Out of Scope for This Section

Three summarization use-cases from the harnesses are covered elsewhere because they are UI or orchestration features rather than context-window management:

- **Away summary** — a 1-3 sentence recap for users returning to a session. Covered under [Interface](../../surfaces/interface/README.md).
- **Agent progress summary** — a 3-5 word background label generated every ~30s for coordinator-mode sub-agents. Covered under [Agent Orchestration](../sub-agent-pool/agent-orchestration.md).
- **Tool-use summary** — a ~30-character batch label generated after each tool group for SDK clients. Covered under [Tool System](../tool-system/README.md).

All three are separate LLM call sites with their own prompts, their own model selection, and no shared code path with compaction. The architectural lesson is that summarization requirements diverge enough by use case (token budget, output shape, latency sensitivity, model choice) that a shared abstraction rarely makes sense — each use case earns its own implementation.

---
