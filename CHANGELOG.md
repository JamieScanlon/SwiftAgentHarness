# Changelog

## Unreleased

### Memory — active-memory feedback-loop guard

- **Affected prompts:** `ActiveMemoryPreReplyPrompts` standing + situational contracts now require ignoring `<memory-context>` / `[Active Memory Recall]` artifacts and basing notes only on durable `memory_search` / `memory_get` results.
- **Query sanitize:** situational `userQuery` is stripped of those injected fences/prefixes before the recall child prompt is built.

### Memory — active memory on by default

- **Config:** `activeMemoryEnabled` and both standing/situational lane flags remain default `true` (documented product choice for this coding harness vs template “opt-in surface”). Opt out via PromptConfig `memory.activeMemoryEnabled: false` (or per-lane flags). Test PromptConfig now states the three keys explicitly.

### Memory — active-memory summary cap (220)

- **Config:** `activeMemoryMaxSummaryChars` default **220** (was 4000); loader clamp **40–1000** (was floor 256).
- **Affected prompts:** `ActiveMemoryPreReplyPrompts` standing + situational contracts now require one compact note under the configured character budget.
- **Hard truncate:** over-budget notes are clipped with a trailing `…` counted inside the budget before fencing/injection.

### Memory — active-memory spawn tool allowlist

- **API:** optional `SubAgentSpawnRequest.toolsAllow` applied on isolated spawn as child `routingPrefs.explicitToolPolicy` allowlist.
- **Active memory:** recall spawn sets `toolsAllow` to `memory_search` + `memory_get` (with `interactionMode: memory-active-recall`) so the gateway enforces the closed world, not prompt text alone.

### Memory — active-memory NONE contract (pre-reply recall)

- **Affected prompts:** `ActiveMemoryPreReplyPrompts` standing + situational system/user prompts (model-facing active-memory recall; not `ToolDefinition.description` fields).
- **Behavioral intent:** Bias toward silence. Useful memory → concise third-person memory note; otherwise exactly `NONE`. Remove “If nothing relevant exists, say so briefly,” which forced prose injection every turn. Host parses `NONE`/empty and skips `[Active Memory Recall]` injection.

### Memory — daily staging capture prompts

- **Affected prompts:** `MemoryExtractionPrompts.systemPrompt`, `MemoryPreCompactionFlushPrompts.systemPrompt` / `userPrompt` (model-facing extraction and pre-compaction flush instructions; not `ToolDefinition.description` fields).
- **Behavioral intent:** Steer capture-cheap writes to today's `memory/YYYY-MM-DD.md` staging file; reserve typed topic files + `MEMORY.md` index for curated durable entries (capture vs curate split for dreaming consolidation).
