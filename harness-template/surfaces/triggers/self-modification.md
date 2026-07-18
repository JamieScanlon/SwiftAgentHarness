# Self-Modification — Recommended Architecture

*When the agent registers its own triggers.*

## TL;DR

Every path that registers a trigger — user CLI, admin UI, agent tool, skill shelling out to the CLI — converges on **one registration endpoint** that owns normalization, validation, the create-time prompt scan, and trust assignment. The agent's registration tool is a **thin client** of that endpoint, never a privileged writer; the scanner lives in the *store's create function*, not the tool wrapper, because agents can reach the store by other roads (bash, file tools, a skill-driven CLI). Registration tools are **control-plane tools**: main-agent-only by default, withheld from sub-agents. Everything self-registered gets a **trust ceiling** (`user-deferred` for scheduled prompts, `known-party` for webhook routes — never `system`), is **stamped with its creator** and fires back into the creator's scope, runs with **equal-or-fewer capabilities** than the registering session, defaults to **session-scoped durability**, and inherits every global policy gate (rate limit, budget, age-out) with no way to raise its own limits. `permanent` remains installer-only.

This page generalizes across trigger kinds; the scheduler-specific mechanics are in [scheduling.md](./scheduling.md) and the webhook-specific ones in [webhook-ingest.md § Self-registered webhooks](./webhook-ingest.md#self-registered-webhooks).

---

## Why this belongs in the harness

Every studied harness with a scheduler ships an agent-facing create tool, and it's the right call: "remind me in twenty minutes" is a core assistant behavior, and an agent that can't register its own follow-ups pushes users toward brittle workarounds. But self-registration is also the cheapest **persistence mechanism** an attacker can ask for. A prompt injection that merely misbehaves dies with its turn; one that registers a cron job survives the session that created it, fires later in a fresh context with full tool access and no human watching, and — if it can mark itself exempt from age-out — never leaves. The registration boundary is therefore a security boundary of the same rank as the inbound webhook gate, and the design question is not *whether* the agent may register triggers but *which invariants every registration path must preserve*.

---

## Recommendation

### One registration pipeline; the agent tool is a thin client

The reference shape: the agent's trigger tool does schema-level coercion and then **calls the same registration endpoint any other client uses** — the gateway RPC, the store's create function — where normalization, cron-expression validation, the pre-flight prompt scan, and trust assignment actually live. One studied harness gets this exactly right for scheduling: its agent-facing cron tool is a wrapper over the gateway call, so agent-created and user-created jobs are indistinguishable to the validator.

The corollary is about *call-site placement*: the scanner must run inside the store's create path, not in the agent tool's wrapper. Another studied harness scans cron prompts only in the tool layer — its CLI create path, and by extension any skill that shells out to that CLI, never invokes the scanner, and a direct write to the jobs file bypasses everything. Skills make this concrete rather than hypothetical: a webhook-subscriptions skill registers routes by running CLI commands in bash, so if validation lives anywhere other than the shared choke point, the skill path silently skips it. There is exactly one privileged writer — the installer — and it writes only `system` rows (see [scheduling.md § Anti-patterns](./scheduling.md#anti-patterns)).

### Registration is a control-plane capability

Trigger registration belongs in the same tool-policy bucket as gateway administration and node control, not alongside `read_file`. Two studied harnesses converge on this: one classifies its cron tool as a control-plane danger category and marks it **owner-only** — sub-agents and shared-session participants don't get it at all; the other keeps sub-agent-created jobs session-only and routed to the creating sub-agent's queue, never the main loop's. The recommendation combines both:

- **Main agent, owner session:** full registration tool (create / list / update / remove).
- **Sub-agents:** no registration tool by default. If a workflow needs it, grant explicitly — and the grant is per-spawn, not inherited.
- **Non-owner senders in shared channels:** never. Registration authority follows the [channel-triggers.md](./channel-triggers.md) authorization gate, not mere presence in the conversation.

### The trust ceiling: nothing self-registered is `system`

Self-registration can produce at most the trust its author already has, per the enum in [triggers.md § Trust as an explicit enum](./triggers.md#trust-as-an-explicit-enum):

- An agent-registered **scheduled prompt** is `user-deferred` — it earns fire-time "treat as user-authored" handling only by passing the create-time scan ([input-provenance.md § Primitive 2](./input-provenance.md#primitive-2--pre-flight-scanning-at-the-registration-boundary)).
- An agent-registered **webhook route** is `known-party` at most — the payloads it will admit are external content regardless of who registered the route.
- **`system` and `permanent` are unreachable** from any tool parameter. The reference implementation makes `permanent` literally unsettable via the create tool — it exists only as a field the installer writes directly to the store — and that is the correct shape: the trust ceiling is enforced by the schema, not by a runtime check that a confused deputy might route around.

### Scope and capability inheritance: attenuate, never amplify

A self-registered trigger is a deferred continuation of the session that created it, and it must not be a *promotion*:

- **Creator stamping.** Stamp every entry with the registering agent's identity at create time (the registration endpoint resolves it from the session key — the agent doesn't self-declare). The stamp is what makes attribution, listing, and cleanup possible, and it's what routes the fire back into the creator's scope rather than the main session.
- **Capability subset.** Per-entry tool restrictions (`toolsAllow`, a toolset list) may only *narrow* what the registering session held. A job that will run unattended with broader tools than its author had interactively is an escalation primitive.
- **Pinning against drift.** Resolve indirect references at create time. One studied harness pins the current provider onto the job when the agent specifies only a model, so the job doesn't silently change behavior when the user later switches defaults. The same applies to working directory and delivery target: capture concrete values, not "whatever is configured at fire time."
- **Origin capture.** Record the originating channel/chat from the session environment at create time so `announce` delivery routes to the right human even though no live session exists at fire time ([scheduling.md § Delivery on fire](./scheduling.md#delivery-on-fire)).

### Durability defaults: session-scoped unless the user asked

The reference tool guidance is right: "remind me in five minutes" stays in memory and dies with the session; only an explicit standing instruction ("keep doing this every day") justifies `durable: true`. Two reinforcing rules from the corpus: the tool *description* steers the model toward the session-only default — the harness doesn't rely on the model's judgment alone, since a separate kill switch can force `durable: false` at the call site — and **sub-agent-created entries are always session-only**, with no durable option at all. Persistence is the property that turns a bad registration from a bug into a foothold, so it's the property to ration most tightly.

### Idempotent installs, sticky deletions

The system-entry lifecycle has a subtle requirement: when the user deletes an installer-provided `system` job, a later re-install must **not** resurrect it. The reference implementation's installer uses write-if-missing semantics — it creates its built-in tasks only when the file doesn't already exist — so a user deletion is durable. Without this, "the user turned it off" and "the installer turned it back on" fight forever, and the user learns they can't actually control their own harness.

### Lifecycle symmetry

List, update, pause, and remove travel through the same endpoint as create, with the same authority rules: the agent may manage entries **it or its user created**, and `system` entries are visible but immutable from the tool (delete via the user-facing surface, not the agent). Update is re-validation — a patched prompt goes back through the scanner, a patched schedule back through expression validation. An update path that skips the create-time checks is just a second unvalidated create path.

### Policy gates apply with no self-service exceptions

Every self-registered trigger inherits the global activation-policy stack — rate limits, idempotency, age-out, and budget caps ([cost-ceilings.md](./cost-ceilings.md)) — automatically, and **no tool parameter can raise them**. This is stated for webhooks in [webhook-ingest.md § Self-registered webhooks](./webhook-ingest.md#self-registered-webhooks) and holds generally: limits are configuration owned by the user/operator; registration is a client operation that lives inside them.

---

## Alternatives

### No agent-facing registration at all

Withholding the tool entirely looks safer but usually isn't. The follow-up use case doesn't go away — the agent improvises with `crontab -e`, an `at` job, or a while-sleep loop in a background shell, none of which pass a scanner, carry a trust level, or appear in `list`. If the harness allows arbitrary shell access, a governed registration path is *safer* than a shadow one, because the governed path is observable and revocable. Withhold the tool only in harnesses that also deny general shell access.

### Approval-gated registration

Interactive surfaces can route every self-registration through the normal tool-approval flow — the human confirms each new cron job like any other dangerous tool call. This is a good *addition* for high-stakes deployments and composes cleanly with the pipeline (approval is a gate in front of the endpoint, not a replacement for its validation), but it cannot be the *only* defense: autonomous and scheduled contexts have no human at approval time, and an approval prompt shows the user the prompt text an injection scanner would catch mechanically.

### Post-hoc validation of a writable config store

The file-event pattern — agent writes a hook/job definition to a watched directory, a watcher validates on load — trades create-time refusal for load-time dropping. It composes well with configuration-as-files harnesses ([file-event-triggers.md](./file-event-triggers.md)), but validate-on-load is strictly weaker: the malicious row reaches disk before anyone judges it, error feedback arrives asynchronously or not at all, and the write itself may be replayed by sync tools. If the store is directly writable, run the *same* validator at both boundaries — refuse at create where possible, drop at load as the backstop.

---

## Anti-patterns

- **Validation in the tool wrapper instead of the store.** Any harness where the agent tool scans but the CLI/store doesn't has not sandboxed self-registration; it has decorated one of several doors. Agents run CLIs in bash and write files with file tools — the choke point must be the store's create path.
- **Agent-settable `permanent` or trust level.** If any tool parameter reaches the `system`/`permanent` bits, the trust enum collapses and age-out has a self-service exemption. Installer-only, enforced by schema absence, not runtime checks.
- **Registration tools granted to sub-agents by default.** A sub-agent spawned to summarize a document does not need to schedule work. Control-plane tools are opt-in per spawn.
- **Capability amplification on the deferred run.** A self-registered job whose tool surface exceeds the registering session's is privilege escalation with a timer on it.
- **No creator stamping.** Unattributed entries can't be listed per-agent, cleaned up when a sub-agent finishes, or audited after an incident. Resolve identity server-side from the session; never trust a self-declared `agentId` parameter.
- **Durable-by-default self-registration.** Session-scoped is the default; persistence requires the user's explicit standing instruction. A "poll this while I work" job that outlives the session is clutter at best and a foothold at worst.
- **Re-install resurrecting user-deleted system entries.** Write-if-missing on install; the user's deletion is the last word.
- **Update paths that skip create-time validation.** Patching a clean job's prompt to a malicious one must hit the same scanner the original create did.

---
