# Skill Workshop

Explicit procedural promotion: the agent proposes workspace skill updates through `skill_workshop`; proposals queue outside the repo, pass a safety scanner, and apply only after explicit approval.

Normative spec (read-only): harness-template `core/memory/skills-as-memory.md`.

**Shipped scope:** `skill_workshop` tool (`suggest`, `apply`, `reject`, `list`, `inspect`, `status`), pending queue, scanner with critical quarantine, full create/append/replace writes, hot skill-catalog invalidation after apply.

**Deferred:** correction-phrase heuristic, threshold-gated LLM reviewer, auto-approval policy, prompt-section injection, promotion-retires-memory, support-file writes.

Ship **disabled by default** (`skillWorkshop.enabled: false` in PromptConfig). Approval is pending-only — every `suggest` queues; nothing auto-writes.

## Routing rule

Facts and preferences belong in memory; multi-step repeatable procedures belong here. Tool descriptions carry this rule for the model.

## Proposal lifecycle

```
pending → applied | rejected | quarantined
```

- Store: `{MemoryConfigHome}/projects/{workspaceKey}/skill-workshop/proposals.jsonl` (outside the workspace tree).
- Dedupe pending/quarantined proposals by `(skillName, change fingerprint)`.
- Cap per workspace (default 50); oldest non-applied entries evicted first.
- Quarantine is terminal for that proposal; recovery requires a new clean `suggest`.

## Safety scanner

Critical findings (instruction injection, hidden-prompt refs, tool-bypass language, pipe-to-shell, secret exfil, plus shared project-instruction rules) → `quarantined`, blocks `apply`. Warn findings (destructive deletes, permissive chmod) are recorded but non-blocking.

## Write discipline

Writes confined to `{skillsFolderPath}/{normalized-name}/SKILL.md`. Names normalized to Agent Skills spec (`[a-z0-9-]+`, max 64). Atomic writes via `MemoryFileLock.atomicWrite`; post-write validation with `SkillParser`.

| Action | Behavior |
|--------|----------|
| `create` | New `SKILL.md`; if skill dir exists, degrades to append into **Workflow** section |
| `append` | Add to named section (default **Workflow**); creates minimal skill if absent |
| `replace` | Requires exact `old_text` match; replaces first occurrence only |

## Configuration

```json
"skillWorkshop": {
  "enabled": false,
  "maxProposalsPerWorkspace": 50
}
```

## Modules

| File | Role |
|------|------|
| `SkillWorkshopConfiguration.swift` | Opt-in config + PromptConfig loader |
| `SkillWorkshopProposal.swift` | Proposal/change DTOs |
| `SkillWorkshopProposalStore.swift` | Workspace-keyed JSONL store (actor) |
| `SkillWorkshopContentScanner.swift` | Critical/warn content scan |
| `SkillWorkshopSkillNameNormalizer.swift` | Agent Skills name normalization |
| `SkillWorkshopWriter.swift` | Confined create/append/replace writes |
| `SkillWorkshopService.swift` | suggest/apply/reject/list/inspect/status orchestration |
| `../ToolSystem/SkillWorkshopToolProvider.swift` | `skill_workshop` tool surface |

## Related

- [`../ToolSystem/README.md`](../ToolSystem/README.md) — tool registration and policy
- [`../Memory/README.md`](../Memory/README.md) — declarative memory (parallel durability surface)
