# Changelog

## Unreleased

### Memory — daily staging capture prompts

- **Affected prompts:** `MemoryExtractionPrompts.systemPrompt`, `MemoryPreCompactionFlushPrompts.systemPrompt` / `userPrompt` (model-facing extraction and pre-compaction flush instructions; not `ToolDefinition.description` fields).
- **Behavioral intent:** Steer capture-cheap writes to today's `memory/YYYY-MM-DD.md` staging file; reserve typed topic files + `MEMORY.md` index for curated durable entries (capture vs curate split for dreaming consolidation).
