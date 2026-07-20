# Scheduling — Recommended Architecture

## TL;DR

Model a scheduled task as a persisted row with **three orthogonal axes**, not one "cron" blob: a **schedule kind** (`at` one-shot / `every` interval / `cron` expression), a **payload kind** (`systemEvent` fire-and-forget vs `agentTurn` full-context run), and a **delivery mode** (`none` / `announce` / `webhook`). Persist to a single JSON file; recompute next-fire from `lastFiredAt ?? createdAt` on every load so restarts are deterministic. Guard the file with a **PID-based scheduler lock** so only one process fires per tick, and let a non-owning process take over if the owner dies. Apply **jitter** to next-fire so `*/5` jobs don't all hit shared APIs at `:00`. **Age out** recurring jobs after a default window, with `permanent` (installer-only) as the sole exemption. Decide missed-fire behavior **per schedule kind**: a one-shot `at` that elapsed during downtime fires late with a `[missed]` marker; a `cron`/`every` recurring job does *not* replay the runs it missed.

This page is the scheduler-internals deep dive under the architecture-level recommendation in [triggers.md](./triggers.md).

---

## Why this belongs in the harness

Scheduling is the single most common non-interactive trigger — most harnesses ship one; library harnesses expect the host to provide it. It's also the trigger surface most likely to be *self-registered*: the agent creates a cron job via a tool far more often than it registers a webhook. That combination — ubiquitous, persistent, and agent-writable — makes the scheduler a security and durability surface, not just a convenience. A scheduler that loses jobs on restart, fires duplicates after a crash, or lets the agent silently promote its own job to system-level is a liability that compounds over the lifetime of a long-running assistant. The discipline below is what separates "a `setTimeout` that survives one session" from "a durable task store the user can trust with a standing instruction."

---

## Recommendation

### The task schema: three orthogonal axes

A scheduled task is a persisted row. The mistake to avoid is collapsing everything into a cron string plus a prompt; real schedulers need three independent dimensions.

```ts
type ScheduledTask = {
  id: string                       // uuid; dedup + delivery anchor
  createdAt: number                // epoch ms — anchor for missed-task detection & age-out
  lastFiredAt?: number             // written back after each recurring fire; never set for one-shots

  // Axis 1 — schedule kind
  schedule:
    | { kind: "at"; at: string }                  // one-shot, ISO timestamp
    | { kind: "every"; intervalMs: number }       // recurring interval
    | { kind: "cron"; expr: string }              // 5-field cron, local time

  // Axis 2 — payload kind
  payload:
    | { kind: "systemEvent"; text: string }       // fire-and-forget, no full context
    | { kind: "agentTurn"; prompt: string }       // full agent run

  // Axis 3 — delivery
  delivery: "none" | "announce" | "webhook"
  deliveryTarget?: { origin?: ChannelOrigin; webhookUrl?: string }

  // Provenance / durability
  recurring: boolean               // false ⇒ delete on fire
  permanent?: boolean              // installer-only; exempt from age-out; marks `system` trust
  durable?: boolean                // runtime-only; false ⇒ session-scoped, never written to disk
  trust: TrustLevel                // `system` (permanent) or `user-deferred` (everything else)
}
```

The three axes are genuinely independent. Split schedule-kind and payload-kind explicitly; carrying `recurring` + `permanent` + runtime-only `durable` as separate flags is the right on-disk shape. Keeping them orthogonal means a recurring `cron` job can be a fire-and-forget `systemEvent` *or* a full `agentTurn`, and either can deliver to a webhook — without multiplying the schema by enumerating every combination.

### Schedule kinds: support three, not just cron

Cron alone forces the user (or agent) to express "every 90 seconds" as a six-field hack and "once at 3pm tomorrow" as a date-pinned expression that's wrong the day after. Three kinds cover the real cases cleanly:

- **`at`** — a one-shot ISO timestamp. "Remind me at 15:00." Fires once, then auto-deletes.
- **`every`** — an interval in milliseconds. "Every 90 seconds, poll X." No cron contortions.
- **`cron`** — a 5-field expression for calendar-aligned schedules. "Every weekday at 9am."

Validate the expression on write *and* re-validate on read (silently drop a single bad row at read time rather than failing the whole file). A malformed row should never block the rest of the schedule.

### Persistence and deterministic restart

Persist to one JSON file per project. The load-bearing detail is how next-fire survives a restart: **anchor next-fire computation from `lastFiredAt ?? createdAt`**, and write `lastFiredAt` back after every recurring fire.

This scheme is exactly right. A never-fired pinned cron like `30 14 27 2 *` anchors from `createdAt`, so its next-from-now correctly lands next year rather than firing immediately on first load. A previously-fired recurring job reconstructs the same in-memory `nextFireAt` the prior process held, so a restart is a no-op rather than an extra fire. Without this anchor, every process restart either double-fires recently-fired jobs or skips jobs whose window opened during downtime — both are silent correctness bugs.

### The scheduler lock: one firer per tick

When two REPL sessions (or a daemon and a REPL) share the task file, only one may fire each tick — otherwise every job fires N times. Use a **PID-based lock with a takeover probe**:

- The owning process writes its identity (session id or, for daemons, a stable per-process UUID) plus its PID into a lock file.
- A non-owning process re-probes the lock on a coarse interval (5s is a reasonable default) and takes over only if the recorded PID is no longer alive.

`tryAcquireSchedulerLock` / `releaseSchedulerLock` as a PID-based lock is the reference; apply the same PID-file pattern at the daemon level. PID liveness is the takeover signal regardless of who owns the identity field, so a crashed owner is reclaimed within one probe interval rather than wedging the schedule forever.

### Missed-fire behavior: decide per schedule kind

What happens to a fire whose time elapsed while the harness was down is not one policy — it's one policy *per schedule kind*, because the kinds encode different intent:

- **`at` one-shot in the past:** fire it late, marked. "Remind me at 3pm" is still worth delivering at 3:05 if the harness was down at 3:00. Detect these on startup and either fire with a `[missed]` marker or hand them to the daemon caller via an `onMissed` callback.
- **`at` one-shot in the future:** schedule a timer normally.
- **`cron` / `every` recurring:** **do not** replay missed runs. A "every 5 minutes, scrape X" job that was down for a day must not fire 288 times to catch up. Fire once at the next natural occurrence. Making this decision explicit is the right default.

Surface the missed set to the caller rather than hard-coding the notification, so a daemon, a REPL, and an assistant-mode installer can each decide how to present it. A split between `onFire(prompt)`, `onFireTask(task)`, and `onMissed(tasks)` callbacks is the right seam.

### Jitter on next-fire

Without jitter, every `*/5 * * * *` job across every user fires at `:00`, `:05`, `:10` — a thundering herd against any shared API the jobs touch. Apply jitter to the computed next-fire via `jitteredNextCronRunMs` / `oneShotJitteredNextCronRunMs` driven by a `CronJitterConfig`, exposed per-tick so ops can widen the window live during a load spike without restarting clients. **Recommendation: jitter by ±10% of the interval, capped at ±60s.** One-shots get a smaller absolute jitter; sub-minute `every` jobs get proportionally less so the jitter doesn't swamp the interval.

### Age-out for recurring jobs

A recurring job the user set 18 months ago and forgot is a standing hazard — it's still firing, still costing tokens, still potentially acting on stale intent. Auto-expire recurring jobs past a max age on their next fire: a recurring, non-permanent task older than `recurringMaxAgeMs` is deleted on next fire; `maxAgeMs === 0` means never expire. **Default: 90 days.** The only exemption is `permanent: true` — which, per the trust model, only the installer can set.

### Durability: not everything goes to disk

A cron created inside a single REPL session shouldn't necessarily outlive that session. A runtime-only `durable` flag gates whether the row is written to disk at all; the serializer strips it so the on-disk shape stays clean. **Default `durable: false` for session-created jobs; opt into persistence via an explicit tool parameter.** This keeps "just poll this for the next hour while I work" from accumulating in the persistent store forever.

### Payload kind shapes the prompt

A `systemEvent` payload is fire-and-forget text injected as a lightweight turn; an `agentTurn` payload is a full prompt that runs with the normal tool surface and context. Both still get the **provenance system reminder** from [triggers.md § Provenance system reminder](./triggers.md#provenance-system-reminder) — the model must know no human is present at fire time regardless of payload weight. The trust level is `user-deferred` for everything the user or agent scheduled, and `system` only for `permanent` installer entries; the prompt-builder rules in [triggers.md § Prompt builder](./triggers.md#prompt-builder-trust-level-determines-the-shape) follow from there. See [input-provenance.md](./input-provenance.md) for the per-level wrapping.

### Delivery on fire

Three delivery modes:

- **`none`** — log only. Default for `system`-trust jobs.
- **`announce`** — deliver the agent's response to the originating chat. Capture that origin at *create* time, so the response routes back to the right user/channel even though no live session exists at fire time. Default for `user-deferred` jobs.
- **`webhook`** — POST the result to a configured URL, validated through the same SSRF guard as `web_fetch` (see [webhook-ingest.md § Outbound delivery](./webhook-ingest.md)).

### Pre-flight prompt validation at create time

The `user-deferred` trust level earns its "treat as user-authored at fire time" handling by paying for validation at the *registration* boundary. A `_scan_cron_prompt` check runs on every cron prompt at create time and refuses jobs matching injection or exfiltration patterns. This is the scheduler's hook into the provenance machinery; the mechanics live in [input-provenance.md § Pre-flight scanning](./input-provenance.md), but the *call site* is the scheduler's create path. Critically, the **self-registration path runs the same scanner** — there's no privileged JSON-write that skips it (see anti-patterns, and [self-modification.md](./self-modification.md) for the general contract on agent-registered triggers).

### On-demand "fire now"

Expose a way to invoke a registered job immediately by name (a `RemoteTriggerTool` pattern). It serves two needs: testing a job without waiting for its schedule, and the "I scheduled this for tomorrow but want it now" case. A manual fire runs through the *same* validation and delivery path as a scheduled fire — it's a convenience, not a bypass.

---

## Alternatives

### Standalone scheduler daemon (vs in-process REPL scheduler)

A separate daemon with a PID file and a `cron_history.jsonl` log is an alternative to firing from inside an interactive session. The daemon survives client disconnects and gives you a durable history log for free. The cost is a second process to supervise and an IPC path between the daemon and whatever runs the agent turn. Prefer the daemon when jobs must fire whether or not anyone has a session open (a server-side assistant); prefer the in-process scheduler when the harness is fundamentally a REPL and "no session open" means "nothing should fire anyway." The same scheduler core can serve both.

### No scheduler at all (host-application responsibility)

A library harness ships no scheduler; the embedding host (Airflow, Temporal, Lambda + EventBridge) already schedules. This is correct when your host *is* a scheduler — don't ship a second one. But the host must still construct a `Trigger`-shaped object on entry and the harness must accept it, so the trust-level enum, the provenance reminder, and the missed-fire semantics still apply; you're outsourcing the *timer*, not the *handling*.

### `croner`-style library + file-watch (vs hand-rolled tick loop)

Using a battle-tested library for cron math and integrating scheduling into a `workspace/events/` file-watch transport is a sound approach. Leaning on a battle-tested cron library for next-fire computation avoids a class of date-math bugs (DST transitions, month-length, leap years) that hand-rolled parsers get wrong. The trade-off is a dependency and less control over jitter/anchor behavior. Reasonable default: use a library for the *parsing and next-occurrence math*, but keep the firing loop, lock, jitter, and missed-fire policy in your own code where the harness-specific semantics live.

---

## Anti-patterns

- **Letting the agent set `permanent` on its own job.** `permanent` is the on-disk marker of `system` trust and the age-out exemption. If the user-facing tool (or the agent) can set it, the trust enum collapses and a runaway job can never be aged out. The `permanent` flag must be settable *only* by the harness installer writing directly to the file; the user-facing create tool can't set it. Enforce the same.
- **Self-registration that bypasses the create-time scanner.** If the agent can write `scheduled_tasks.json` directly (rather than through the validated tool), a malicious cron prompt injected via some upstream content can install itself without ever hitting `_scan_cron_prompt`. Every registration path — user tool, agent tool, skill — goes through the same validation. The only privileged writer is the installer, and it only writes `system` rows.
- **Anchoring next-fire from `now()` instead of `lastFiredAt ?? createdAt`.** Anchoring from wall-clock-now on load means a restart either double-fires recently-fired jobs or skips jobs whose window opened during downtime. The anchor must be the persisted history, not the current instant.
- **Replaying every missed recurring fire on startup.** A 5-minute job down for a day must not fire 288 times to "catch up." Recurring jobs fire once at the next natural occurrence; only one-shots fire late.
- **No jitter on shared-resource jobs.** `*/5` jobs all firing at `:00` is a self-inflicted thundering herd. Jitter is not optional once more than a handful of jobs touch the same API.
- **Unbounded recurring jobs.** A standing job with no age-out is a forgotten process that costs tokens and acts on stale intent indefinitely. Age out by default; exempt only `system`-level.
- **Sharing the task file across processes with no lock.** Two sessions polling the same file fire every job twice. The PID lock with takeover is the minimum; "we only ever run one session" is an assumption that breaks on the first `--replace` restart race.
- **Persisting session-scoped jobs to disk by default.** "Poll this for the next hour" shouldn't survive the session. Default `durable: false`; opt in.

---
