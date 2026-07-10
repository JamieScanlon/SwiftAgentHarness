# Changelog

## Unreleased

### Memory — active-memory spawn tool allowlist

- **API:** optional `SubAgentSpawnRequest.toolsAllow` applied on isolated spawn as child `routingPrefs.explicitToolPolicy` allowlist.
- **Active memory:** recall spawn sets `toolsAllow` to `memory_search` + `memory_get` (with `interactionMode: memory-active-recall`) so the gateway enforces the closed world, not prompt text alone.

### Memory — active-memory NONE contract (pre-reply recall)

- **Affected prompts:** `ActiveMemoryPreReplyPrompts` standing + situational system/user prompts (model-facing active-memory recall; not `ToolDefinition.description` fields).
- **Behavioral intent:** Bias toward silence. Useful memory → concise third-person memory note; otherwise exactly `NONE`. Remove “If nothing relevant exists, say so briefly,” which forced prose injection every turn. Host parses `NONE`/empty and skips `[Active Memory Recall]` injection.

### Memory — daily staging capture prompts

- **Affected prompts:** `MemoryExtractionPrompts.systemPrompt`, `MemoryPreCompactionFlushPrompts.systemPrompt` / `userPrompt` (model-facing extraction and pre-compaction flush instructions; not `ToolDefinition.description` fields).
- **Behavioral intent:** Steer capture-cheap writes to today's `memory/YYYY-MM-DD.md` staging file; reserve typed topic files + `MEMORY.md` index for curated durable entries (capture vs curate split for dreaming consolidation).
