# Planning

## TL;DR

Planning is **three separable concerns**, not one feature:

1. a **constraint regime** — a mode profile that narrows the tool surface to read-only-plus-one-exception while the agent researches and drafts;
2. a **plan artifact** — a durable, conversation-scoped document with a real lifecycle (identity, resume, fork, compaction survival, recovery);
3. **progress tracking** — a structured step-state tool whose updates surfaces render live.

The OSS corpus adopts these independently: one harness has all three, one has only the artifact (as a skill), one has only the tracking tool, one has tracking plus a runtime guard against plan-restating stalls. Bundling them into a single "planning mode" over-prescribes by construction — a coding harness and a project-management harness legitimately mean different things by "a plan," and a host should be able to adopt the artifact contract without the constraint regime, or tracking without either.

This page prescribes the **mechanisms** hard — artifact lifecycle invariants (fork never clobbers; content survives compaction; tiered recovery), two interaction invariants (planning turns end only via a question tool or the exit tool; re-entry re-evaluates the existing artifact), exit-as-classified-approval, and structured-not-parsed tracking — and leaves the **content** soft: workflow prompt shape, plan document structure, and approval decision vocabulary are host-supplied defaults, with the coding-domain versions given as worked examples.

The constraint regime itself is *not* re-specified here: it is an ordinary `ModeProfile` per [modes.md](./modes.md), with `exit_plan_mode` as an ordinary `haltsLoop` tool per [agent-runtime](../agent-runtime/README.md). This page adds only what those pages don't: the artifact, the tracking, the approval semantics, and the interaction invariants.

---

## Why three concerns, not one

The decomposition is the load-bearing decision, so it comes first.

**The concerns have different lifecycles.** The constraint regime is per-mode-episode (entered, exited). The artifact is per-conversation and outlives the episode — it's re-read on re-entry, referenced during implementation, recovered after compaction. Tracking is per-run and deliberately ephemeral — [memory](../memory/memory.md) already rules that in-progress task lists are never persisted to long-term stores. Three lifecycles bundled into one feature means every consumer handles the union.

**The concerns have different owners.** The regime is Conversation Manager state enforced by the Tool System ([modes.md](./modes.md), [permissions](../tool-system/permissions.md)). The artifact is a workspace file provisioned by a mode hook. The tracking tool is a Tool System registration whose output is presentation-bound. No single layer owns "planning."

**Hosts legitimately want subsets.** A project-management harness may want the artifact and the tracking with no constraint regime at all — there's nothing dangerous about drafting a project brief, so read-only enforcement buys nothing. A minimal chat-first harness may want a plan *skill* and no machinery. A coding harness wants all three because unreviewed edits are exactly what plan mode exists to prevent. The template must not force the maximal configuration to get any of it.

---

## Recommendation

### The capability ladder

Adopt planning incrementally; each rung is useful alone and none is a prerequisite rewrite of the previous.

| Rung | What it is | Enforcement | Right for |
|---|---|---|---|
| **Plan as skill** | A bundled skill: "research, don't execute; write a plan document to the workspace plans directory" | None — prompt-level only | Hosts without mode machinery; domains where "execution" isn't dangerous |
| **Plan as permission preset** | A mode whose profile carries only a `tools` slice (mutating tools denied, plan file the one writable exception) | Availability plane — denied tools are absent from the turn | Hosts with modes but no artifact lifecycle needs |
| **Full planning mode** | Mode profile across all slices + artifact lifecycle + tracking + classified exit approval | Availability + gating + runtime termination policy | Coding-style harnesses where side effects are the point of the gate |

The skill rung is not a toy: one skills-first harness in the corpus ships planning *only* this way — a `/plan` skill that writes a timestamped markdown plan into a workspace `plans/` directory and replies with the path — and it covers the "user wants a plan, not execution" case with zero core changes. Its known weakness is that nothing *enforces* read-only, which is precisely what the next rung adds.

The rungs compose: a host at the top rung should still ship the skill-level behavior (the artifact contract below is shared), and the permission preset is literally the `tools` slice of the full profile.

### Concern 1: the constraint regime

Mechanically this is [modes.md](./modes.md) — a profile whose `tools` slice denies mutating tools, whose `context` slice injects a planning directive, whose `runtime` slice sets `termination: terminal-tool` on `exit_plan_mode` with `stopOnApprovalRequest: true`. Nothing here is planning-specific and no layer special-cases the mode id. What this page adds are two **interaction invariants** that belong in the mode's directive and the exit tool's prompt, because every harness that lacks them rediscovers the same failure:

**Invariant 1 — planning turns end only via a question tool or the exit tool.** Never via free-text "shall I proceed?" / "does this plan look good?". Free-text approval is unparseable: the surface can't render an approval control, the approval doesn't enter the [approval-ux](../../surfaces/interface/approval-ux.md) lifecycle (no dedupe, no expiry, no reroute), and the transcript records consent nowhere machine-readable. The exit tool's prompt must say this explicitly — "do NOT ask about plan approval via text or the question tool; calling this tool *is* the approval request" — because models otherwise default to polite prose. The question tool remains available for *requirement* clarification; the rule discriminates by purpose, not by tool.

**Invariant 2 — re-entry re-evaluates the artifact.** When a conversation re-enters planning and an artifact already exists, the enter hook attaches a re-entry directive: read the existing plan first; if the current request is a *different* task (even a related one), overwrite; if it is explicitly a continuation, revise in place and prune stale sections; either way, **edit the artifact before calling the exit tool**. Without this, stale plans get re-approved verbatim — the artifact's persistence becomes a liability instead of an asset.

Two smaller regime notes:

- **Agent-initiated entry is itself gated.** If the model can call `enter_plan_mode` proactively (a good pattern — the model often knows a task is ambiguous before the user does), that call is an ordinary `ask`-classified tool call: the user consents to entering the regime. Mode transitions the *user* initiates (hotkey, slash command) don't need this — consent is the gesture.
- **The enter/exit hooks own the artifact plumbing.** Enter provisions the artifact (below) and attaches a directive naming its path; exit archives or releases it. This is the `prepareContextForPlanMode`-shaped hook already anticipated by [modes.md § Mode-transition hooks](./modes.md#mode-transition-hooks).

### Concern 2: the plan artifact

The artifact is a **conversation-scoped durable document** that is the single writable exception inside the constraint regime. The single-writable-exception shape matters: "you may edit exactly one file, and here is its path" is enforceable on the availability/gating planes (path-scoped allow rule), keeps the plan out of the transcript's prose (where it can't be diffed, versioned, or recovered), and gives the agent a place to build the plan *incrementally* rather than emitting it in one shot at the end.

**Identity.** Key the artifact per conversation with a stable, human-readable identifier (a generated word-slug outperforms a UUID for anything a user will see in a file listing). Sub-agents planning under a parent get **derived keys** (`{key}-agent-{agentId}`), never the parent's file — concurrent sub-agent planners otherwise interleave writes. The identifier is recorded on the conversation (or in its event log) so resume can find it.

**Location.** A dedicated plans directory — per-instance config-home by default, optionally project-relative via config, with the config value validated against path traversal (a relative `plansDirectory` that resolves outside the project root is a config error, not a request). Hosts with workspace-portable file tools may instead keep plans workspace-relative (`<workspace>/plans/`) so the artifact travels with the execution backend; both satisfy the contract, pick one and document it.

**Lifecycle invariants.** These are the hard-won part; all four are cheap to honor and expensive to retrofit:

1. **Resume reuses identity.** Re-attaching to a conversation recovers the recorded key and continues editing the same artifact.
2. **Fork gets a new identity and a copy.** A branched conversation generates a *fresh* key and copies the source artifact's content into it. Sharing the file between branches means the two sessions silently clobber each other — this is the single most common artifact bug in the corpus.
3. **Content survives compaction.** [Compaction](../context-engine/compaction.md) must not trust the summary to carry the plan. Re-inject a **plan reference attachment** (path + content, or path + digest for large plans) alongside the mode flag it already re-injects. A plan that exists only in summarized-away turns is a plan the implementation phase can't see.
4. **Recovery is tiered.** When the file is missing at resume (ephemeral filesystem, remote execution, user deletion), recover in order: (a) the most recent **file snapshot** written incrementally into the event log — on ephemeral backends, snapshot the artifact into the log on every change; (b) the plan content embedded in the last exit-tool call's recorded input; (c) the compaction-injected plan reference attachment. Scan backwards; first hit wins; write the recovered content back to the canonical path.

**Content: a default, not a contract.** What goes *in* the plan is domain-owned. Ship a default structure as the mode directive's guidance — for coding: a brief context section, the recommended approach only (not all alternatives considered), paths of files to be modified, existing functions/utilities to reuse with their paths, and a verification section — and let hosts replace it wholesale. One evidence-backed rule survives domain transfer: **bias hard toward concision.** Telemetry from one very large deployment (tens of millions of planning sessions) shows plan rejection rate rising monotonically with plan length — roughly 20% for plans under 2K characters to 50% above 20K. Long plans aren't thorough; they're unreviewable. The directive should say so ("concise enough to scan, detailed enough to execute"), and hosts that want teeth can cap ("most good plans are under 40 lines; prose is padding") — but the cap is a tuning knob, not template law.

### Concern 3: progress tracking

A structured **step-state tool** — the piece of planning most portable across domains, and the one to prescribe most confidently because four of six corpus harnesses converge on nearly the same schema:

```ts
type PlanStep = {
  step: string                                   // short, imperative
  status: "pending" | "in_progress" | "completed"
}

// tool: update_plan / write_todos — a full-replace write, not a patch
type UpdatePlanInput = {
  explanation?: string                           // what changed and why, for the surface
  plan: PlanStep[]                               // ordered; at most ONE in_progress
}
```

Rules the schema encodes: steps are **ordered**; at most **one step is `in_progress`** (the invariant that makes a status line renderable); updates are **full-list replacements** (idempotent, no patch grammar to mis-apply); the optional `explanation` gives surfaces a change note without diffing.

Placement and presentation:

- **It's a Tool System registration**, not conversation state — it arrives via [schema-and-registration](../tool-system/schema-and-registration.md) like any tool, is filterable per mode profile, and is deniable to sub-agents that shouldn't own a top-level step list.
- **Its output is structured state for the surface**, carried as typed detail on the tool result ([result-formatting](../tool-system/result-formatting.md)) and rendered via the portable presentation path ([interface](../../surfaces/interface/README.md)) — a progress widget, a checklist message, a status line. **Never parse progress out of prose.** One corpus harness extracts numbered steps from a `Plan:` header in output text and tracks completion via inline `[DONE:n]` markers; it works until the model rephrases, and it makes the transcript the parser's problem. The structured tool costs one schema and removes the whole failure class.
- **It's ephemeral.** Step state lives in run/conversation state and dies with the task. [Memory](../memory/memory.md) already prohibits persisting in-progress task lists; the tracking tool is the thing that rule points at.

**Tracking is not the artifact.** The artifact is approval-time (what the user consents to); tracking is execution-time (where the work stands). A host may auto-seed the step list from an approved plan's steps — a nice touch — but the lifecycles stay separate: rejecting a plan doesn't touch step state from a previous task, and completing steps doesn't rewrite the approved document.

### Exit is a classified approval

Plan approval flows through the same machinery as every other approval — it is a **classified approval request** with the standard lifecycle (dedupe, expiry, reroute, decision recording) from [approval-ux](../../surfaces/interface/approval-ux.md), not a bespoke dialog. Three consequences:

**The decision vocabulary is per-approval-kind, and plan approval's is host-extensible.** Tool approvals use allow-once / allow-always / deny. Plan approval wants richer options, and *which* options is domain-owned. The coding-domain worked example: **approve** (exit regime, implement, edits gated normally), **approve + auto-accept edits** (exit into an accept-edits-style mode — a mode-to-mode transition, expressible because modes are registry entries), and **approve with fresh context** (approve, then compact/clear the planning transcript and start implementation with the plan document as the primary carried-forward context — a pattern that couples approval to the [context engine](../context-engine/README.md) and works precisely because the plan is a durable artifact, not transcript prose). A PM-domain harness might instead offer approve / request-revision / escalate. The template prescribes that the vocabulary is extensible, not what it contains.

**The approver is routing, not identity.** By default the approval routes to the conversation's user. In orchestrated settings ([agent-orchestration](../sub-agent-pool/agent-orchestration.md)), a worker agent's plan approval can route to the *orchestrating agent* instead — the request enters the orchestrator's inbox, the worker parks on `stopOnApprovalRequest`, and the human sees only what the orchestrator escalates. Same classification, different delivery target.

**Rejection returns to the regime with feedback.** A denied plan doesn't exit the mode; the denial (with the user's note) re-enters the loop as input, the agent revises the artifact, and exits again. The artifact's incremental-edit affordance is what makes revision cheap.

### Runtime guard: planning-only stalls

A failure mode adjacent to planning but owned by the [agent runtime](../agent-runtime/README.md): the model describes or restates a plan **instead of acting** — in planning mode by never calling the exit tool, or after approval by recapping the plan instead of taking the first concrete action. This is a *stall variant* under the runtime's existing termination/recovery machinery, and the seam is worth specifying even though the detection is not:

- **Classify** turns that produced neither a tool call with side effects nor a user-visible deliverable — just plan-shaped prose. Detection heuristics (structured-bullet detectors, intent-cue regexes, per-language acknowledgment lists) are messy, model-specific, and partly mitigations for particular providers' current behavior; they are **host-supplied classifier territory**, not template content.
- **Retry, bounded, with a targeted instruction** — "do not restate the plan; take the first concrete action now; if a real blocker prevents action, state the exact blocker in one sentence." Cap retries (the corpus uses 1–2) and land in an explicit **blocked terminal state** rather than looping — surfacing "agent stopped after repeated plan-only turns" beats silently burning turns.
- **Fast-path short approvals.** When the user's message is a bare acknowledgment ("ok, do it"), inject a directive to *skip the recap* and act immediately — the recap-after-approval is the same stall wearing a politeness mask.

### Workflow shapes (patterns, not prescriptions)

Two proven shapes for what the agent *does* inside the regime; both satisfy the interaction invariants, and the choice is a host decision (or a config arm):

**Interview loop** — pair-planning with the user. Skeleton the artifact early (headers and rough notes), then cycle: explore → immediately capture findings in the artifact → ask the user when a decision can't be resolved from context → repeat; converge and call the exit tool when the plan covers what-changes / where / what-to-reuse / how-to-verify. Strengths: the user shapes the plan before it calcifies; ambiguity surfaces early; the artifact is always current (which invariant-1 turn-ending discipline depends on). This is the corpus's newer generation and the better default for interactive surfaces.

**Phased fan-out** — explore with parallel read-only sub-agents ([the explore/plan triad](../sub-agent-pool/agent-orchestration.md)), then one or more plan-designer agents (optionally with assigned *perspectives* — simplicity vs. performance vs. minimal-change — for genuinely architectural tasks), then review against the user's intent, then write the final artifact and exit. Strengths: breadth without polluting the parent's context; parallel wall-clock wins on large scopes. Costs: token-heavy, and the user is out of the loop until the end — pair it with question-tool checkpoints.

Either way, the directive arrives via the mode profile's `context` slice, with a **sparse re-reminder variant** re-attached on later planning turns (a one-liner restating the regime, the artifact path, and the turn-ending rule) so long planning episodes don't drift as the full directive scrolls out of attention.

---

## Alternatives

### One bundled "planning mode" feature

Ship regime + artifact + tracking as a single unit behind one flag. **Why not as default:** the three concerns have different lifecycles and owners (see above), and bundling forces the maximal configuration on hosts that want a subset — the PM harness that wants artifact + tracking must drag in a constraint regime that means nothing in its domain. The bundle also invites the `if (mode === 'plan')` scatter that [modes.md](./modes.md) exists to prevent.

### Skill-only planning as the ceiling

Stop at the ladder's first rung: a plan skill, no mode, no lifecycle. **Why not as default:** nothing enforces read-only — a prompt-level "don't execute" loses to a sufficiently confident model or a sufficiently adversarial context, which matters exactly in the coding domain where planning is most valuable. And without artifact identity, resume/fork/compaction all silently orphan the plan. Fine as a floor; wrong as a recommendation.

### Plan as transcript prose (no artifact)

The plan is whatever the model last said; approval quotes it. **Why not as default:** compaction eats it, fork can't copy it, re-entry can't revise it, "approve with fresh context" is impossible, and the exit tool has to carry the full plan as a parameter (bloating every approval event) instead of pointing at a file. The one-writable-file exception costs a path rule and buys the whole lifecycle.

### Tracking derived by parsing output text

Extract numbered steps from a `Plan:` section; track completion via inline markers. **Why not as default:** couples progress to the model's phrasing, breaks silently on rephrase, and pushes a parser into every surface. The structured tool is strictly cheaper. (Acceptable as a retrofit onto a harness with no tool-registration seam — which is the situation the corpus example was actually in.)

---

## Anti-patterns

- **Fork shares the plan file.** Branch and source both hold the original artifact key and clobber each other's edits. Fork must mint a new key and copy content — invariant 2 of the artifact lifecycle.
- **Free-text plan approval.** "Does this look good?" in prose. No approval lifecycle, no machine-readable consent, no surface control. Turns end via question tool or exit tool, full stop.
- **Trusting the compaction summary to carry the plan.** The summary mentions "we made a plan"; the content is gone. Re-inject a plan reference attachment — same rule as the [compaction](../context-engine/compaction.md) task-state list, which this page extends from flag to content.
- **Re-approving a stale artifact on re-entry.** The agent exits planning without touching the existing file; the user approves last week's plan. Re-entry directive: evaluate, revise or overwrite, always edit before exit.
- **Progress parsed from prose.** `[DONE:3]` markers and regexes over a `Plan:` header. Use the structured tool.
- **Persisting step state to memory.** In-progress task lists in long-term memory stores — already prohibited by [memory](../memory/memory.md); the tracking tool's ephemerality is the point.
- **A second policy system for the regime.** Implementing plan mode's read-only property as checks inside tools rather than as the mode profile's `tools` slice read by the [permission](../tool-system/permissions.md) planes. One policy system; the mode is data.
- **Prescribing one plan structure across domains.** Hard-coding the coding-domain sections (files to modify, verification commands) into core rather than the mode directive's replaceable guidance. Structure is content; content is host-owned.
