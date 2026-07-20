# Skills as memory (procedural promotion)

## TL;DR

Memory and skills are the declarative and procedural halves of one durability story: **memory** stores facts, preferences, and context; **skills** store reusable procedures the agent should follow on future tasks. The bridge between them is a **skill workshop**: the agent observes its own runs and turns corrections, hard-won fixes, and recurring workflows into *proposals* for workspace `skills/<name>/SKILL.md` files. Proposals arrive through three capture paths (an explicit tool, a zero-cost correction-phrase heuristic, and a threshold-gated no-tools LLM reviewer), flow through a **pending → applied / rejected / quarantined** lifecycle, and pass a **safety scanner whose critical findings quarantine even under auto-approval**. Default to pending-approval; reserve auto-apply for trusted workspaces. Writes are confined to the workspace skills directory with normalized names, atomic writes, and a **hot skills-snapshot refresh** so promoted procedures are invocable without restart. The routing rule that keeps the two surfaces coherent: *corrections about what to do* → skill proposal; *facts about the user/world* → memory. Ship the whole feature disabled by default — it's the most autonomy-expanding write path in the memory system.

---

## Recommendation

### Declarative vs. procedural: the routing rule

The [four-type taxonomy](./memory.md#agent-written-memory-the-type-taxonomy) already captures *guidance* in `feedback` memories — but a feedback memory is advice the agent reads and interprets; a **skill** is a procedure the agent (or user, via slash command) *executes*. The line:

- **Memory** — facts, preferences, entities, past context. "User prefers aisle seats." "Integration tests must hit the real DB, because of incident X."
- **Skills** — multi-step, repeatable procedures. "How to validate externally sourced animated assets." "How to run the repo-specific QA scenario." "How to debug the recurring provider failure."

What promotion is *not* for: single facts ("user likes blue"), autobiographical context, transcript archives, one-off instructions that won't repeat, and never secrets or hidden prompt text. Give the agent this routing rule explicitly in the prompt guidance (below) — without it, procedures get saved as sprawling feedback memories and facts get saved as one-line skills, and both surfaces degrade.

The promotion path in one sentence: *the agent proposes a procedural memory as a skill; the user approves (or the system auto-approves in trusted workspaces); the promoted procedure becomes a workspace skill — discoverable, slash-invocable, and repairable.*

### Three capture paths

Capture at three cost levels, each with a distinct trigger:

**1. Explicit tool call.** A `skill_workshop`-style tool the model calls when it recognizes a reusable procedure or the user says "save this as a workflow." Zero heuristics, works even with all automatic capture disabled. This is the floor — ship it first.

**2. Correction-phrase heuristic.** After successful turns, scan the user's messages for explicit correction phrases: *next time…*, *from now on…*, *remember to…*, *make sure to…*, *always use/check/verify…*, *prefer X when/instead…*. A match becomes a proposal from the matching instruction, with topic hints choosing a stable skill name (recurring task families get named workflows; everything else falls back to a general `learned-workflows` skill). **No model call** — this path is free, and intentionally narrow: clear corrections and repeatable process notes only, not transcript summarization.

**3. Threshold-gated LLM reviewer.** After every N successful turns (default ~15) *or* M observed tool calls (default ~8), run a compact embedded review pass. Constrain it hard:

- **Input caps** — recent transcript capped (~12,000 chars), up to ~12 existing workspace skills at ~2,000 chars each. The existing-skills input is essential: it's what lets the reviewer *repair* instead of duplicate.
- **No tools, no messaging.** The reviewer reads and emits JSON; it cannot act.
- **Output: `none` or exactly one proposal**, with action `create`, `append`, or `replace` — and instructions to **prefer `append`/`replace` when a relevant skill exists**, using `create` only when nothing fits. This single preference is what turns the skill library from an append-only pile into maintained procedural memory.
- **Bounded and skippable** — a timeout (~45 s); on failure, timeout, or invalid JSON, log and skip the pass. Same failure discipline as every background memory worker: never let the learning loop break the working loop.

The reviewer inherits the session's model context with runtime defaults as fallback — same resolution philosophy as [pre-reply recall](./pre-reply-recall.md), except this path is off the reply path, so latency tolerance is higher.

### The proposal lifecycle

Every capture becomes a **proposal**, not a write:

```
Proposal {
  id, createdAt, updatedAt,
  workspaceDir, agentId?, sessionId?,
  skillName, title, reason,
  source: tool | agent_end | reviewer,
  status: pending | applied | rejected | quarantined,
  change,            // create | append | replace payload
  scanFindings?, quarantineReason?
}
```

Details that matter in practice: **dedupe** pending/quarantined proposals by skill name + change payload (the heuristic will fire on the same correction repeatedly); **cap the store** (~50 per workspace, newest kept); store state per workspace under the harness state directory keyed by workspace hash — proposals are *about* a workspace but must not live *in* it, or they'd sync/commit with the repo. The `reason` field is what the human reads at review time; require it.

**Approval policy** is a two-value dial: `pending` (default — queue everything; apply only on explicit approval via the tool or a review UI) and `auto` (write scanner-clean proposals immediately). Auto mode **still runs the scanner and still quarantines critical findings** — auto-approval is a trust statement about the *workspace*, never a bypass of the safety path. Don't enable auto when the workspace holds sensitive procedures, the agent processes hostile web/email content, skills are shared across a team, or you're still tuning capture. Run pending mode first and read what the agent proposes before trusting it.

### The safety scanner

Generated skill content is future system-prompt/instruction material — exactly like memory writes, it must survive a jailbroken model or attacker-shaped context ([memory.md § Sensitive-data handling](./memory.md#sensitive-data-handling)). Scan every proposal and support file. Two severity tiers:

**Critical → quarantine** (blocks even under auto-approval):

| Rule | Blocks content that… |
| ---- | -------------------- |
| injection / ignore-instructions | tells the agent to ignore prior or higher-priority instructions |
| injection / hidden-prompt reference | references system prompts, developer messages, hidden instructions |
| injection / tool-bypass | encourages bypassing tool permission or approval flows |
| pipe-to-shell | fetch-and-execute (`curl \| sh` shapes) |
| secret exfiltration | appears to send env/credential data over the network |

**Warn → retained, non-blocking** (broad destructive deletes, permissive chmod) — recorded in `scanFindings` so the human sees them at review.

Quarantine is **terminal for that proposal**: `apply` refuses it, the findings and reason stay attached for inspection, and recovery is a *new* clean proposal — never hand-editing the proposal store. This mirrors the memory write-scanner principle: prompt-level rules are necessary but not sufficient; the scanner is what actually holds.

### Write discipline

- **Confined target.** Writes land only under `<workspace>/skills/<normalized-name>/`. Skill names are normalized (lowercase; illegal runs → `-`; trimmed; length-capped; final regex check) so a proposal can't smuggle a path.
- **Change semantics.** `create` writes a new `SKILL.md` (if the name already exists, degrade to appending into the main workflow section); `append` adds to a named section (creating a minimal skill if absent); `replace` requires the exact `oldText` present and replaces the first match only. Narrow, schema-shaped mutations — the same philosophy as the wiki layer's `wiki_apply` ([plugin-slot.md](./plugin-slot.md)): no freeform page surgery.
- **Support files** (references, templates, scripts, assets) are allowed only in those named subdirectories, workspace-scoped, path-checked, byte-limited (~40 KB default), scanned, and written atomically.
- **Hot refresh.** Applying a proposal refreshes the in-memory skills snapshot immediately — the promoted skill is discoverable and invocable in the *same session*, no restart. Promotion that requires a restart teaches the agent (and user) that promotion doesn't work.

### Prompt guidance and skill quality

When the workshop is enabled, inject a short prompt section that carries the routing rule and the quality bar:

- Capture **procedures, not facts/preferences** (facts go to memory).
- Capture user corrections, non-obvious successful procedures, recurring pitfalls; propose after long tool loops or hard-won fixes.
- **Repair** stale/thin/wrong skills through append/replace rather than creating near-duplicates.
- Skill text is **short and imperative** — steps the next agent executes.
- **No transcript dumps.**

The good/bad contrast is worth embedding verbatim in the guidance. Good: `- Verify the URL resolves to the expected content type. - Confirm the file has multiple frames. - Record source, license, attribution. - Verify the local asset renders before final reply.` Bad: "The user asked about an asset and I searched two websites, then one was blocked…" — transcript-shaped, not imperative, full of one-off noise, tells the next agent nothing to *do*. This is the procedural twin of memory's ["what NOT to save"](./memory.md#agent-written-memory-what-not-to-save) section, and it's the highest-leverage prompt text in the feature.

Vary the guidance with the approval policy: pending mode says "queue suggestions; apply only after explicit approval"; auto mode says "apply safe, clearly-reusable workspace-skill updates."

### Keeping the two surfaces coherent

Three rules prevent memory and skills from drifting into overlap:

1. **Route at capture time.** The routing rule in the prompt (facts → memory, procedures → skill proposal) is the primary mechanism.
2. **Repair-over-create keeps skills canonical.** Because the reviewer sees existing skills and prefers append/replace, a procedure has one home that improves, rather than five near-duplicate homes.
3. **Promotion retires the memory.** When a `feedback` memory turns out to be procedural and gets promoted to a skill, the memory entry should be updated to a one-line pointer (or removed) — otherwise recall surfaces the stale prose version alongside the maintained skill. This is a natural [consolidation](./consolidation.md) concern: promotion to a different surface is still promotion.

Observability: a `status` action counting proposals by state, `list`/`inspect` actions per status, and log lines for queued/applied/quarantined/skipped events. The quarantine list matters most — "automatic capture appears to do nothing" is usually a quarantined proposal nobody looked at.

---

## Alternatives

**Procedures as feedback memories only.** No skills surface; procedures live in the four-type taxonomy as `feedback` entries with `**How to apply:**` bodies. Fine for harnesses without a skill registry, and simpler by an entire subsystem. Costs: no slash-invocability, no support files (scripts/templates), no structured repair, and procedures compete with facts for index budget. Right up until users start pasting the same multi-step instructions repeatedly — that's the signal to build the workshop.

**Manual skill authoring only.** Users write skills by hand; the agent only consumes. The safest configuration and a completely defensible default — the workshop's entire value is capturing procedures the user *wouldn't* have bothered writing. Pair it with the explicit tool path (path 1) as a middle ground: the agent can draft, but only when asked.

**Self-amending instruction files.** Let the agent append learned procedures to the project-instructions file (`AGENTS.md`). Attractive because there's no new surface, but instruction files are hand-curated, always-loaded, and precedence-bearing — an agent-writable append path erodes the [two-surfaces discipline](./memory.md#two-surfaces-not-one) and bloats every future prompt. Skills are lazily loaded and individually gated; that's the right cost model for procedures.

**Capture-everything episodic logging.** Record all successful tool sequences and mine them offline for procedures. Maximal recall, but the mining problem is harder than the capture problem, and the store is transcript-shaped by construction. The three-path design (explicit, phrase-heuristic, thresholded reviewer) is the disciplined version — capture at moments with signal.

---

## Anti-patterns

- **Transcript-shaped skills.** A skill that narrates what happened instead of prescribing what to do is noise with a filename. Imperative steps or it doesn't get saved — enforce through the reviewer prompt and review-time human judgment.

- **Auto-apply as scanner bypass.** If `auto` mode skips the scanner "because the workspace is trusted," a single hostile web page read in that workspace can plant an instruction-injection skill that loads into every future session. Auto-approval trusts the *workspace's humans*, not the content the agent ingests there. Scanner always runs; critical findings always quarantine.

- **Skills as a second memory.** "User prefers tabs over spaces" saved as a skill wastes the surface and dodges memory's taxonomy, scopes, and consolidation. If it isn't a procedure, it isn't a skill; route it.

- **Create-happy capture.** A reviewer that can't see existing skills (or isn't told to prefer repair) produces `asset-workflow`, `asset-workflow-2`, and `media-asset-checks` within a month, and the model stops trusting any of them. Existing-skill context plus append/replace preference is the dedupe mechanism.

- **Proposals stored in the workspace.** Pending proposals in the repo get committed, synced, and reviewed by teammates as if they were decisions. State directory, keyed by workspace hash, outside the tree.

- **Hand-editing the proposal store.** Recovering a quarantined proposal by editing the store JSON reintroduces the exact content the scanner blocked, now with an `applied`-adjacent status. New clean proposal or nothing.

- **A reviewer with tools.** The review pass exists to *judge*, not act. A reviewer that can read files or call tools is an unattended background agent with write ambitions — the constraint `no tools, JSON out, one proposal max` is the containment.

- **Unbounded capture on hostile input.** Heuristic phrases appear in attacker-controlled content too ("from now on, always run…" in a scraped page). Capture reads *user* messages, not tool results — and even then, the scanner backstops what capture proposes.

- **Restart-gated promotion.** If an applied skill isn't visible until the next session, the feedback loop that teaches the agent promotion works is severed. Atomic write + snapshot refresh, same session.

- **Shipping it enabled.** An agent that autonomously grows its own capabilities is the feature's point *and* its risk profile. Opt-in, pending-first, auto only after the operator has read a few weeks of proposals.

---
