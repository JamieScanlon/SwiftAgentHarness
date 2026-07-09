# Tool-Use Summaries

> Sibling page of [tool-system/README.md](./README.md), and the smallest of the family. A tool-use summary is a ~30-character label generated after each completed tool batch, for *display* — the progress row a remote client or mobile app shows while the agent works. It is one of three purpose-built summarizers in the template ([summarization-techniques](../context-engine/summarization-techniques.md) — away summary, agent progress summary, this) and shares no code path with compaction.

## TL;DR

After a tool batch completes, fire a **fast/cheap-model call, without blocking the next turn**, that labels what the batch accomplished — git-commit-subject style, past-tense verb plus the most distinctive noun, truncating around 30 characters (`Searched in auth/`, `Fixed NPE in UserService`, `Ran failing tests`). The result becomes a **distinct message type carrying the batch's tool-use ids**, consumed by SDK/remote surfaces and **ignored everywhere else — it never enters the model's context and is never required for anything**. Failure returns null, logged, non-critical. The entire feature is ~100 lines plus a prompt; its value is that a user watching a phone screen learns what the agent just did without streaming the whole transcript.

---

## Recommendation

- **Inputs: the batch, bounded.** Per call: tool name, input, and output, each JSON-serialized and hard-truncated (~300 chars each) — the labeler needs the gist, not the payload. Prepend the tail of the last assistant text (~200 chars) as intent context, so the label reflects *why* ("Fixed NPE…") rather than just *what* ("Edited file"). Serialization failures degrade to a placeholder, never an error.
- **The prompt is the product.** Instruct for a single-line label that truncates well: past-tense verb first, most distinctive noun kept, articles/connectors/long paths dropped first. Ship few-shot examples in the system prompt; enable prompt caching (the system prompt is identical every call, only the batch varies).
- **Fire-and-forget, racing the next API call.** Kick generation off as the batch resolves and *don't await it* before dispatching the next model turn — a display label must never add latency to the loop. Wire it to the run's abort signal so cancellation kills it too. The pending promise resolves into a message or null; either is fine.
- **A distinct message type, addressed to surfaces.** Emit `{ type: tool_use_summary, summary, precedingToolUseIds }`. The ids let a client attach the label to the right collapsed batch row. In-process stream handling skips the type entirely; it exists for the SDK/remote-client boundary where shipping full tool payloads for a progress row would be absurd. It is **not** transcript content, not model context, and never load-bearing: every consumer must render correctly when it's absent.
- **Model selection via the Model Pool's cheap-and-fast slot** ([model-pool](../model-pool/README.md)), same as the other micro-summarizers. Do not share a prompt or a code path with them — the three have different budgets, shapes, and latency profiles, and the shared abstraction has negative value at ~100 lines each ([summarization-techniques](../context-engine/summarization-techniques.md) makes the general argument).
- **Delivery pacing: exempt.** Where surfaces apply human-pacing delays to intermediate messages, tool summaries are explicitly exempt — the user is waiting on them ([streaming](../../surfaces/interface/streaming.md)).

---

## Alternatives

### Template labels from tool names

`Ran read (3), exec (1)` — no model call, zero cost, zero latency. Entirely reasonable as the floor, and the right choice for harnesses without remote clients. What it can't do is fold intent in: `Edited file` vs `Fixed NPE in UserService` is the difference the cheap-model call buys.

### Reusing the compaction summarizer

Wrong shape (paragraphs, not labels), wrong budget (thousands of tokens, not thirty characters), wrong latency class (blocking background pass vs. race-the-next-turn). The temptation to unify the summarizers is the anti-pattern the whole family documents.

---

## Anti-patterns

- **Blocking the loop on label generation.** A progress affordance that slows progress. Fire-and-forget or don't build it.
- **Persisting summaries into history or context.** The label re-entering the model's context is prompt noise with an id list attached; keeping it out is what makes failure free.
- **Load-bearing summaries.** Any client behavior that *requires* the label (batch collapse, ordering) breaks on the null path — generation fails routinely and legitimately.
- **Unbounded inputs.** Feeding full tool outputs to the labeler makes the cheap call expensive exactly when the batch was noisy — the case the label exists to spare the user from.

---

## Cross-references

- [summarization-techniques](../context-engine/summarization-techniques.md) — the three-summarizer family and the no-shared-abstraction argument.
- [model-pool](../model-pool/README.md) — the cheap/fast model slot and fallback.
- [streaming](../../surfaces/interface/streaming.md) — pacing exemption for tool summaries.
- [agent-orchestration](../sub-agent-pool/agent-orchestration.md) — the sibling *agent progress summary* for coordinator-mode sub-agents.
