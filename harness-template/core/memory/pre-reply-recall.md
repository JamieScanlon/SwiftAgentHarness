# Pre-reply blocking memory recall (active memory)

A bounded model call that runs **before** the main reply so durable memory can inform the turn without waiting for the main model to invent a `memory_search`. This is the **active-memory** pattern.

Normative companion to [memory.md](./memory.md) § Pre-reply blocking memory recall.

## Constraints

- **Tools:** only `memory_search` and `memory_get`. No write, edit, or other tools. Restriction is **gateway-enforced** via spawn `toolsAllow` (child `routingPrefs.explicitToolPolicy`) plus the `memory-active-recall` mode profile allowlist — not prompt hope alone.
- **Model:** resolved via the Model Pool — optional pin (`activeMemoryModelRef`), then a `memory-recall` capability query (prefer cheap/tools, trust-scoped to the session provider tier by default), then the parent session model if it has tools. Unresolved → skip recall (no error).
- **Chat types:** default to direct messages; group/channel sessions opt in explicitly.
- **Agents:** per-agent allowlist in multi-agent setups.
- **Budget:** hard timeout and a `maxSummaryChars` cap on any note handed to the main reply. Default **220** (compact note, not an essay); PromptConfig clamp **40–1000**. Soft limit in the recall prompt; hard truncate with a trailing `…` when clipped.
- **Isolation:** run on its own per-conversation execution context so it does not cancel the main in-flight model call.
- **Recall cache:** per-conversation bound `activeMemoryRecallCacheMaxEntries` (default **1000**, clamp **1–100000**). LRU eviction prefers situational keys so standing stays sticky.

## Defaults (this harness)

Active memory **ships on**: `activeMemoryEnabled`, `activeMemoryStandingEnabled`, and `activeMemorySituationalEnabled` default to `true`. The template page describes an opt-in surface for conversational products; here the product choice is opt-**out** via PromptConfig (`memory.activeMemoryEnabled: false`, or per-lane flags). Soft session/global toggles (below) pause recall without editing PromptConfig.

The `chatType == direct` gate remains, but coding REPL/API sessions are constructed as `direct`, so that gate is not a product off-switch. Group/channel sessions still require an explicit non-direct `chatType` and stay skipped unless the host sets one.

Lanes (implementation):

- **Standing** — `user` / `feedback` types (stable profile). Query-independent; no conversation transcript.
- **Situational** — `project` / `reference` types relevant to the current conversation excerpt (see query modes below).

## Session toggle

Pause or resume active memory without editing PromptConfig:

```text
/active-memory status
/active-memory off
/active-memory on
```

Session on/off writes conversation metadata (`sah.activeMemory.enabled`). Absent key ⇒ on.

Global soft toggle (all sessions; does not rewrite PromptConfig):

```text
/active-memory status --global
/active-memory off --global
/active-memory on --global
```

Global soft state lives in `active-memory-control.json` under the memory config home (missing file ⇒ on). CLI: `memory active-memory status` (read-only).

**Gates (all must pass):** `config.activeMemoryEnabled` AND global soft on AND session soft on AND existing lineage / `chatType == direct` / lane flags.

## How to see it

By default the recall note is a hidden pre-reply injection. For the tuning loop:

```text
/verbose on
/trace on
```

After the main assistant reply, the harness appends follow-up lines (harness-injected; not model prompt pollution):

```text
Active Memory: status=ok elapsed=842ms query=recent summary=34 chars
Active Memory Debug: <note text>
```

| status | Meaning |
|--------|---------|
| `ok` | Non-NONE note injected |
| `none` | Lanes returned NONE / empty |
| `disabled` | Config / global / session soft off |
| `skipped` | Lineage / chatType / no query |
| `timeout` / `error` | Spawn path failure |

`activeMemoryLogging` (default `true`) emits structured debug logs: `active-memory: start|done …`.

### Recommended tuning loop

1. Start with `queryMode: recent`, `promptStyle: balanced`, compact `maxSummaryChars` (220), logging on.
2. Use `/verbose on` and `/trace on` while tuning.
3. Move to `message` for lower latency, or `full` (raise situational timeout) if extra context is worth it.
4. If noisy → tighten `maxSummaryChars` / prefer `strict`; if slow → lower query mode / timeouts / recent turn+char caps.

Follow-ups like “what about the second one?” need an antecedent. Situational recall therefore builds a **query payload** from the parent transcript (not a forked child history):

| `activeMemoryQueryMode` | Payload |
|-------------------------|---------|
| `message` | Latest user message only (legacy behavior) |
| `recent` (**default**) | Latest user message + up to N prior user / M prior assistant turns (excluding the latest), each truncated to char caps |
| `full` | Same builder with a bounded window (last 20 user + 20 assistant turns, still per-turn char-capped). May need a higher `activeMemorySituationalTimeoutMs`. |

Defaults (OpenClaw-aligned):

| Knob | Default | Clamp |
|------|---------|-------|
| `activeMemoryQueryMode` | `recent` | `message` \| `recent` \| `full` |
| `activeMemoryPromptStyle` | `balanced` | see styles below |
| `activeMemoryRecentUserTurns` | `2` | 0–4 |
| `activeMemoryRecentAssistantTurns` | `1` | 0–3 |
| `activeMemoryRecentUserChars` | `220` | 40–1000 |
| `activeMemoryRecentAssistantChars` | `180` | 40–1000 |

Harness-injected and empty messages are skipped. Each fragment is stripped of `<memory-context>` / `[Active Memory Recall]` before assembly. Prefetch and blocking recall use the **same** builder output so cache fingerprints match.

## Prompt styles

`activeMemoryPromptStyle` adjusts situational system-contract eagerness only (NONE / char budget / ignore-injected rules stay in force):

| Style | Intent |
|-------|--------|
| `balanced` (default) | Useful note when memory clearly helps; use prior turns to resolve references |
| `strict` | Prefer NONE unless the match is obvious; minimal bleed |
| `contextual` | Lean on conversation continuity for pronouns / follow-ups |
| `recall-heavy` | Softer but still plausible matches |
| `precision-heavy` | Aggressively prefer NONE unless match is clear and specific |
| `preference-only` | Favorites, habits, routines, taste, recurring preferences |

## Feedback-loop guard

Prior injected recall (`<memory-context>…</memory-context>`, `[Active Memory Recall]`) must not become evidence for the next recall pass. The recall prompt tells the sub-agent to ignore those artifacts and base notes only on `memory_search` / `memory_get`. Situational `userQuery` is stripped of the same fences/prefixes before the child prompt is built, so standing-lane notes cannot echo into situational recall via a contaminated query string.

## NONE contract (core)

The recall sub-agent must **bias toward silence**. Its output is binary:

| Case | Output |
|------|--------|
| Useful durable memory exists | A concise **third-person memory note** — background for the main agent, **not** a reply to the user |
| Nothing useful | Exactly `NONE` |

Rules:

- Do not apologize, narrate the search, or say “nothing was found” in prose.
- Do not invent memory.
- Do not wrap `NONE` in other sentences.
- Prefer `NONE` when unsure whether a note would help.

### Examples

**Good**

```text
User prefers Grafana dashboards over raw Prometheus queries for latency reviews.
```

```text
NONE
```

**Bad**

```text
I didn't find anything relevant in memory.
```

```text
No relevant memory was found.
```

```text
Sure — here's what I know about your preferences: …
```

## Injection rule

Only a non-`NONE` note is fenced (e.g. `<memory-context>…</memory-context>`) and prepended to the main turn as ephemeral context (e.g. `[Active Memory Recall]`).

`NONE`, empty output, timeout, or spawn failure → **no injection**. Silence must not become prompt pollution.
