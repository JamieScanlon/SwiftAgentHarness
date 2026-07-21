# Planning constraint regime — spec review notes

Captured while implementing planning alignment slices. Harness-template remains read-only; these are naming/shape mismatches and deferred work for later review.

## Tool naming: template vs harness

| Template (`modes.md` / `planning.md`) | Harness implementation |
|---|---|
| `write_doc` (plan allow — single writable exception) | `create_plan` / `edit_plan` / `add_plan_task` / `delete_plan_task` (write via `AgentPlanStore`, not filesystem tools) |
| `read_*`, `search`, `fetch` | `read_file`, `read_attachment`, `glob`, `grep` |
| `bash`, `exec`, `edit_file`, `write_file` (plan deny) | `bash`, `write_file`, `edit_file`, `process`, `process_send_keys`, plus spawn (`spawn_sub_agent`, `Coding Agent`) |
| `update_plan` / `write_todos` (progress tracking) | Checkbox tasks in `plan.md` + `update_plan_task` (not yet the structured tracking tool from Concern 3) |

The constraint-regime behavior matches the template (denied = absent; plan tools are the sole write path; exit/enter are ask-classified). Content/tool names remain host-shaped coding-domain choices.

## Artifact lifecycle progress

| Gap | Status |
|---|---|
| PL1–PL3 constraint regime | Done |
| PL4 bind conversation id from scope | Done — plan/mode tools use `ConversationScope` / injected resolver; no model `conversation_id` |
| PL5 fork copies plan | Done — `AgentPlanStore.copyConversationDirectory`; split/copy call sites delegate |
| PL6 compaction plan reinjection | Done — file presence + canonical path (not transcript substring) |
| PL7 tiered recovery | Deferred — see AGENTS.md; local disk is source of truth |
| PL8 marker vocabulary | Done — `[x]` complete / `[!]` blocked; legacy `[/]` parse + on-write migrate |
| PL9 structured task state on the wire | Done — plan-tool metadata + `GET /api/conversations/:id/plan` expose `PlanTaskInput` / counts |
| PL10 ≤1 in-progress | Done — auto-demote on create/edit/update/add |
| PL11 exit approval reject-with-feedback | Done — plan-exit presentation (Approve / Request revision); deny rewrites parked pending tool result + resumes in plan |
| PL12 planning-only turn classifier | Deferred — host-supplied heuristics / ack fast-path; revisit if plan-recap stalls appear |

## Still out of scope

- Ephemeral `update_plan` / `write_todos` tracking tool (Concern 3) — checkbox tasks in `plan.md` remain the durable progress surface
- Rich plan-approval decision vocabulary (approve + auto-accept edits, approve with fresh context)
- Production wiring of `shouldEmitEphemeralAgentBuildContinuation`
- Human-readable plan identity slugs / derived sub-agent keys (UUID paths today)
- Enriching WS `ConversationOrchestrationState` beyond existing bools (REST + tool metadata cover surfaces for now)
- PL12 planning-only stall classifier and ack fast-path (host-supplied; generic forced-tool-choice covers most cases)
