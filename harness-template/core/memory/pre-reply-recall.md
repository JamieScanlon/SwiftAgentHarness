# Pre-reply blocking memory recall (active memory)

A bounded model call that runs **before** the main reply so durable memory can inform the turn without waiting for the main model to invent a `memory_search`. This is the **active-memory** pattern.

Normative companion to [memory.md](./memory.md) § Pre-reply blocking memory recall.

## Constraints

- **Tools:** only `memory_search` and `memory_get`. No write, edit, or other tools. Restriction is **gateway-enforced** via spawn `toolsAllow` (child `routingPrefs.explicitToolPolicy`) plus the `memory-active-recall` mode profile allowlist — not prompt hope alone.
- **Model:** a separate, typically faster/cheaper recall model (or an explicit inherit of the session model).
- **Chat types:** default to direct messages; group/channel sessions opt in explicitly.
- **Agents:** per-agent allowlist in multi-agent setups.
- **Budget:** hard timeout and a `maxSummaryChars` cap on any note handed to the main reply.
- **Isolation:** run on its own per-conversation execution context so it does not cancel the main in-flight model call.

Lanes (implementation):

- **Standing** — `user` / `feedback` types (stable profile).
- **Situational** — `project` / `reference` types relevant to the current user message.

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
