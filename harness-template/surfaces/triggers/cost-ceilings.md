# Cost Ceilings — Recommended Architecture

*Per-source budget gates in the activation policy.*

## TL;DR

Rate limits cap **events**; a trigger's cost per event is unbounded, so the activation policy needs a stage denominated in **spend**. Give every trigger source a **budget ledger** — scope (route / job / channel peer), rolling window, ceiling — checked *before* admission and charged *after* the run from the [canonical usage record](../../cross-cutting/observability/README.md#one-canonical-usage-shape-cost-computed-once), attributed by `Trigger.id → source`. Because a run's cost is unknowable up front, the budget gate is **ledger-based admission** (admit while spent-so-far < ceiling) paired with **per-run caps** (timeout, turn cap, pinned model) that bound the overshoot to one run's worst case. Use the **two-tier shape** the corpus already proved for real-money micropayments: a per-fire cap *and* a per-window budget. On breach, walk a ladder — warn → degrade → defer → suspend the source — and notify the owner through the origin channel; never silently eat their standing instructions. Keep two mechanisms that look similar distinct from budgets: the **circuit breaker** (consecutive-failure suspension, which catches runaway loops that would drain any budget through retries) and the **kill switch** (operator-level stop that running schedulers poll, halting in-flight recurrence, not just new registrations).

This page is the deep dive under [triggers.md § Activation policy](./triggers.md#activation-policy-gate-before-the-agent-runs), stage 4.

---

## Why this belongs in the harness

None of the six studied harnesses implements a per-source spend cap — the rare finding of a *shared gap* rather than a shared pattern. The attack it leaves open is cheap: a webhook source with a valid secret can POST at just under the rate limit forever, and each POST launches a full agent turn with tool access. Thirty requests a minute times an expensive `agentTurn` is a large bill by morning, and every one of those requests *cleared* the validation gate — signature valid, under the rate limit, idempotency key fresh. The failure isn't hostile traffic slipping past a check; it's that no check speaks the right unit. The same gap bites without an attacker: a self-registered polling job, a chatty channel, a monitoring webhook that fires on every log line — triggers run when no human is watching, which is precisely when spend needs a mechanical guardian. The corpus meters cost well (per-run cost snapshots, per-user daily buckets, a canonical usage shape) but at best *alerts* on it; one harness's daily-threshold tracker fires a callback and logs a warning while admission continues. Metering without enforcement is a receipt, not a ceiling.

---

## Recommendation

### The budget object

```ts
type TriggerBudget = {
  scope:                        // what this ledger covers
    | { kind: "source"; sourceId: string }   // one webhook route, cron job, channel peer
    | { kind: "class"; trust: TrustLevel }    // e.g. all unknown-party sources
    | { kind: "global" }                      // whole trigger surface
  window: "day" | "month"       // calendar-aligned, local time
  ceilingUsd: number            // admission stops when the ledger reaches this
  perFireCapUsd?: number        // bound on any single run (see two-tier shape)
  onBreach: "warn" | "degrade" | "defer" | "suspend"   // ladder position to start at
}
```

Resolution is most-specific-wins: a per-source budget overrides its trust-class budget, which overrides the global one — but all matching ledgers are *charged*, so the global ledger still sees every dollar. Defaults matter more than the schema: every source gets a budget the moment it's registered, inheriting the trust-class default unless the user sets one. A budget that exists only when someone remembers to configure it protects nobody.

### Placement: after the cheap gates, before the prompt builder

The activation-policy order in [triggers.md](./triggers.md#activation-policy-gate-before-the-agent-runs) is idempotency → rate limit → authorization → cost ceiling, and the ordering is deliberate: the first three are O(1) lookups that shed duplicate and hostile traffic before the budget ledger is even consulted, so a replay flood can't distort spend accounting. The cost gate then answers one question — *has this source's ledger reached its ceiling for the window?* — and refuses admission if so. Refusal is the same observable drop as any other gate failure: logged to the audit path with the ledger balance, never surfaced to the model.

### Ledger-based admission plus per-run caps

The awkward truth about pre-admission cost checks: you cannot know what a run will cost before running it. An `agentTurn` may answer in one model call or spiral through forty tool rounds. The resolution is to split the problem:

- **The ledger bounds the cumulative.** Admit while `spentThisWindow < ceilingUsd`. This check is against *recorded history*, so it's exact — no estimation.
- **Per-run caps bound the overshoot.** The run admitted at $9.99 of a $10 ceiling can still overshoot — by at most one run's worst case. The corpus's per-run knobs are exactly the right set: a per-job `timeoutSeconds`, a turn limit, and a pinned (cheaper) model — all fixed at registration time per [self-modification.md § pinning](./self-modification.md#scope-and-capability-inheritance-attenuate-never-amplify).

The reference for the two-tier shape comes from the one place the corpus enforces spend for real: the micropayment path, which pairs a per-request cap with a per-session total, both checked *before* money moves. Triggers deserve the same pairing — `perFireCapUsd` (enforced by aborting the run when its accrued usage crosses it) and `ceilingUsd` per window.

### Attribution: charge the source, roll up the fan-out

The charge side runs on machinery that already exists: every model call emits the canonical usage record, cost is computed once from the versioned pricing table, and the trigger runtime stamps each run's cost onto its session entry. The budget system adds one join: usage events carry the `Trigger.id`, the trigger record carries its `sourceId`, and the ledger accrues per source. Two rules keep the attribution honest:

- **Sub-agent fan-out rolls up.** A trigger run that spawns three sub-agents charges all four runs to the originating source. Fan-out is the easiest way to launder a budget; the creator-stamping chain from [self-modification.md](./self-modification.md) is what makes roll-up mechanical.
- **The ledger persists across restarts.** A daily ceiling that resets on process restart is a ceiling an attacker resets by crashing the process (or waiting for the nightly deploy). Persist ledgers with the trigger store, keyed by window date, and prune on window rollover.

### The breach ladder

One threshold with one action is too blunt — "warn" alone is the corpus's current failure, and "suspend" alone turns a busy Tuesday into an outage. Walk a ladder, with thresholds as fractions of the ceiling:

1. **Warn (~75%).** Notify the source's owner through the origin channel captured at registration. The alert-threshold callback pattern is right; wiring it to a user-visible channel instead of a server log is the missing half.
2. **Degrade (~90%).** Shed cost without shedding function: route subsequent fires to the cheaper pinned model, flip heavy payloads to lightweight context, batch pending fires into the next heartbeat instead of running each alone (see *Alternatives*).
3. **Defer (100%).** New fires queue for the next window instead of running. Correct for recurring jobs whose work is not urgent; the missed-fire semantics from [scheduling.md](./scheduling.md#missed-fire-behavior-decide-per-schedule-kind) apply — deferred recurring fires collapse to one, they don't replay.
4. **Suspend (sustained or egregious breach).** The source stops firing until a human re-enables it. Suspension is the right terminal state for the hostile case; auto-resume at window reset is the right default for the benign one. Distinguish by pattern: a source that hits its ceiling every window is misconfigured or hostile either way, and escalating to sticky suspension after N consecutive breached windows keeps the decision mechanical.

Every rung notifies. A trigger the user registered is a standing instruction; making it silently stop firing is a correctness bug wearing a cost-control costume.

### Self-registered sources: budgets are not self-service

Per [self-modification.md](./self-modification.md#policy-gates-apply-with-no-self-service-exceptions), an agent-registered trigger inherits its budget from the trust-class default, and no tool parameter can raise a ceiling or widen a window. The agent may *lower* its own job's caps (attenuation is always allowed) and may *report* ledger state — "this job has used 80% of its daily budget" is a useful thing for the agent to know and say. Raising limits is a user/operator action on the user-facing surface.

### The circuit breaker is not a budget

Two corpus mechanisms sit adjacent to budgets and must stay distinct:

- **Consecutive-failure circuit breaker.** One harness auto-suspends a session that was active across three consecutive process restarts — a crash-loop detector. Generalize it per trigger source: N consecutive failed or timed-out runs suspends the source regardless of ledger balance. A stuck loop burns budget through *retries*, and waiting for the ceiling to catch it means paying the whole ceiling for nothing.
- **The kill switch.** A remote flag that running schedulers poll on a coarse interval, stopping in-flight recurrence — not just new registrations — when flipped. This is the operator's emergency stop for the whole trigger surface; its value is precisely that it doesn't consult any per-source state.

Budget, breaker, and kill switch answer different questions — *is this source too expensive*, *is this source broken*, *stop everything now* — and collapsing them into one mechanism loses the ability to answer any of them well.

---

## Alternatives

### Provider-side spend limits as the only ceiling

API-org budgets and provider dashboards will eventually stop runaway spend, and they should exist as the backstop. But they're the wrong granularity in both directions: they can't tell the hostile webhook from the user's interactive session — when they trip, everything stops, including the human — and they can't answer *which source* spent the money. Harness-level per-source ledgers are what make the breach ladder and the attribution story possible. Use both; treat the provider limit as the fuse that should never blow because the harness gates fired first.

### Token-denominated budgets

Metering natively happens in tokens; dollars require a pricing table that drifts as providers reprice. Budgeting in tokens avoids the drift but fails the person configuring it — nobody knows what 40M tokens costs without doing the conversion, and mixed-model sources make token counts incomparable. The corpus's answer is right: meter in tokens, convert through the versioned pricing table *once* at emit time, budget and report in dollars. When the table updates, historical ledger entries keep the cost computed at their emit time; only new accrual uses new prices.

### Concurrency caps as cost control

A max-concurrent-runs bound (the corpus has per-process session caps) limits *instantaneous* burn and protects the machine, but not the wallet — a single-file queue of expensive runs spends just as much, just slower. Concurrency caps are worth having for resource reasons; they are not a substitute for a ledger.

### Heartbeat batching as cost prevention

The strongest cost mechanism in the corpus isn't a gate at all: batching N periodic checks into one heartbeat turn — isolated session, lightweight context, a cheap ack token for the nothing-to-do case, suppressed OK-acknowledgments — makes the common case nearly free instead of policing an expensive one. Prefer converting agent-registered polling jobs to heartbeat entries *before* reaching for budget enforcement; the budget then guards the residue. Prevention and ceiling compose — this page exists because prevention alone has no answer to a hostile source.

---

## Anti-patterns

- **Request rate as a cost proxy.** 30/min sounds bounded; 30/min × an unbounded `agentTurn` is not. Rate limits and budgets are different gates in different units — keep both.
- **Alerting without enforcing.** A daily-threshold warning that fires while admission continues is the corpus's status quo and the page's reason to exist. Every threshold needs an action rung, not just a log line.
- **Limits set beyond reach.** A recursion limit of 9,999 is documentation, not a limit. The same corpus that lacks spend caps ships turn limits tuned to never fire; a ceiling nobody can hit protects nobody.
- **Global-pot-only metering.** One shared budget with no per-source attribution means the first noisy source exhausts it for everyone, and the post-mortem can't name the offender. Ledgers are per-source first; the global ledger is the roll-up, not the primary.
- **Volatile ledgers.** Spend state that resets on restart converts every deploy into a budget refill. Persist with the trigger store.
- **Fan-out laundering.** Charging only the top-level run and not its sub-agents makes "spawn a sub-agent" the universal budget bypass. Roll up by originating source.
- **Silent suspension.** Cutting off a user's standing instruction without telling them through the origin channel converts a cost control into a data-loss bug they discover weeks later.
- **Self-service ceilings.** If the registration tool can raise its own budget, the ceiling is decorative — same rule, same reasoning as the `permanent` flag in [self-modification.md](./self-modification.md).

---
