# Triggers

This folder implements the harness **Surfaces/Triggers** spec: non-interactive activation (cron, webhooks, file events, channels) through a normalized `Trigger` pipeline.

Production wiring is assembled by **`TriggersRuntimeWiring`**. The host app supplies `TriggersRuntimeWiring.Configuration` (notably `dataDirectory`, optional `eventsDirectory`, and feature toggles) and injects the returned `TriggersRuntimeBundle` into its composition root alongside the agent runtime and Communication Layer.

## Pipeline

```mermaid
flowchart LR
  Adapter --> ActivationPolicy
  ActivationPolicy --> SessionRouter
  SessionRouter --> PromptBuilder
  PromptBuilder --> DispatchService
  DispatchService --> Runtime
  DispatchService -->|delegated| SubAgentPool
  SubAgentPool --> OutputRouter
```

## Boundary: Communication Layer vs Triggers

| Concern | Communication Layer | Triggers surface |
|--------|---------------------|------------------|
| User typing in client UI | `POST /api/conversations/:id/messages` | N/A |
| Cron / webhook / file / channel ingress | Removed from API contract | **Trigger gate** → `TriggerDispatchService` |
| Idempotency | WS `dedupe_check_and_set` | `TriggerIdempotencyGate` (same persistence primitive) |
| Trust / provenance | `CommEnvelopeOriginTrust` on wire envelopes | Adapter sets trust; prompt builder wraps |

Trigger ingestion is **outside** Communication Layer scope. Interactive clients use the Communication Layer; automation surfaces use the trigger gate only.

## Service inventory

| Type | Role |
|------|------|
| `Trigger` / `TriggerSource` | Normalized activation object |
| `TriggerActivationPolicy` | Idempotency, rate limit, auth, cost ceiling |
| `TriggerSessionRouter` | Isolated / threaded / delegated session keys |
| `TriggerPromptBuilder` | Trust-dispatch prompt + provenance reminder (`known-party` envelope preamble on by default, configurable off) |
| `ExternalContentEnvelope` | Shared provenance primitive ([`cross-cutting/Provenance`](../../cross-cutting/Provenance/ExternalContentEnvelope.swift)); trigger prompts + tool-result middleware |
| `TriggerDispatchService` | Gate → runtime or delegated sub-agent handoff |
| `TriggerDelegatedDispatchService` | Spawn constrained sub-agent via SubAgentPool |
| `TriggerSymmetricOutputRouter` | Source-aware completion egress |
| `TriggerRegistrationService` | **The one registration endpoint** — every create/update/delete, from every client |
| `TriggerSchedulerService` | Cron/at/every reader + firer. Does **not** register |
| `WebhookIngressAdapter` | HTTP validate-then-normalize → file queue or `Trigger` |
| `FileEventQueueService` | Watches `events/` directory; sole consumer when queue enabled |
| `TriggerWebhookRouteRegistrar` | Vapor routes outside `/api` |

## Host integration

At boot, the host app typically:

1. Resolves a **`dataDirectory`** for trigger configuration (webhook subscriptions, scheduled tasks, channel config, audit snapshots).
2. Optionally sets **`eventsDirectory`** or relies on `TRIGGER_EVENTS_DIR` / `{persistenceRoot}/events/`.
3. Calls `TriggersRuntimeWiring.resolve(...)` with runtime, dedupe, conversation-creation, and delegated sub-agent ports.
4. Registers webhook routes and starts the file-event watcher / channel listeners when enabled.
5. Installs channel lifecycle on the agent runtime: `orchestratorRuntime.installChannelRegistry(bundle.channelRegistry, holder: channelRegistryHolder, sessionLifecycleCoordinator: bundle.channelSessionLifecycleCoordinator)` after `installAgentRuntime`.

| `Configuration` field | Purpose |
|-----------------------|---------|
| `dataDirectory` | Root for `channels.json`, `scheduled_tasks.json`, `webhook_subscriptions.json`, `trigger_snapshots/`, `trigger_audit.jsonl`, channel locks/status |
| `eventsDirectory` | Override for file-event queue watch path |
| `fileEventQueueEnabled` | When true, webhooks enqueue instead of direct dispatch |
| `channelListenersEnabled` | Starts channel listener registry (default `false`) |
| `staticWebhookRoutes` | Boot-time webhook route table |

## Delegated routing (Step 13)

When `routingMode: .delegated`, triggers spawn a **constrained sub-agent** (async by default) instead of running the parent agent loop. Completion is delivered symmetrically:

| Source | Egress on completion |
|--------|----------------------|
| `channel` | Reply on same thread via channel listener |
| `webhook` | POST to `deliveryWebhookURL` |
| `cron` | Per `delivery` (`none` / `announce` / `webhook`) |
| `file-event` | Audit log only |

Configure on webhook routes, `channels.json`, or `ScheduledTask` rows:

- `routingMode`: `delegated`
- `delegate`: `TriggerDelegateProfile` (`subagentType`, `runInBackground`, …)
- `deliveryWebhookURL` (webhook/cron outbound)

Child runs use mode profile `trigger-delegate` (read-only tool surface, no recursion). Trigger hosts use `trigger-host` metadata stamped on the parent conversation.

**Provenance reminder (delegated):** Isolated/threaded routes inject the provenance reminder as an ephemeral system message via `TurnLoop` (`systemReminder` → `ephemeralSystemReminder`). Delegated sub-agents have no separate system-reminder channel at spawn, so `TriggerDelegatedDispatchService` prepends `systemReminder + "\n\n" + userMessageBody` into the sub-agent `prompt`. Parity would require an `ephemeralSystemReminder` field on `SubAgentSpawnRequest`; inline prepending is the intentional v1 deviation.

## File-event queue (Step 11)

When the file-event queue is enabled, producers drop paired files under `{eventsDirectory}/`:

```text
{eventsDirectory}/
├── foo.json              # event payload (immediate | one-shot | periodic)
├── foo.trust             # optional provenance sidecar
└── .processing/          # rename-on-read staging
```

Trust comes **only** from the `.trust` sidecar; missing sidecar → `unknown-party`. Producers write the `.trust` sidecar **before** the `.json` event so the watcher never sees an event without its trust. Webhooks write to the queue only (no direct `dispatch.ingest`) when the watcher is enabled.

Default events path: `TRIGGER_EVENTS_DIR` env, else `{persistenceRoot}/events/` (see `FileEventQueueLayout.resolveEventsDirectory`).

**Non-goal:** `HOOK.md` handler discovery (separate subsystem).

## Channel listeners (Step 12 framework)

Platform-agnostic intake pipeline under `Channel/`:

```text
transport → parse → instance lock → dedup → attachments → allowlist → mention gate → debounce → trust → Trigger
```

`channels.json` accepts all `ChannelTransportKind` values (`mock`, `slack`, `telegram`, `discord`, `email`). **Only `mock` is implemented today**; other kinds log `channel_transport_not_implemented` at startup and are skipped until platform PRs land. Trust comes from mechanical classification (`user-direct`, `known-party`, `unknown-party`, `system`), not message content.

Config: `{dataDirectory}/channels.json` with per-channel `auth`, `mention`, `debounce`, `dedupe` (`ttl_seconds`, default 3600), `primary_user`, optional `routing_mode` / `delegate`, and optional `include_known_party_security_preamble` (default `true`). Disabled by default (`channelListenersEnabled: false` in wiring).

Inbound dedupe uses the same persistence primitive as trigger idempotency and WS `dedupe_check_and_set` (host-provided `dedupeCheckAndSet` port → `cache/dedupe.sqlite`). Keys are namespaced `channel-intake:{channel}:{account}:{peer}:{session}:{platformMessageId}` so reconnect redelivery survives process restarts within the configured TTL window.

Runtime status: `{dataDirectory}/channel-status/{channel}.json` with stage counters and inflight debounce count.

**Follow-up platform PR checklist** (one PR per platform): add a `ChannelPluginFactory.build` branch returning transport (`ChannelTransport`), supervised listener (`ChannelSupervisedListening`), raw parser (`ChannelTransportRawEvent` → `ChannelMessageEvent`), outbound slot (native rich render), optional `sessionGrammar` / `security` overrides, transport-specific config fields, and fixture-based tests.

**Deferred:** live Slack/Telegram/Discord/Email SDK adapters, credential storage, attachment download over credentials.

## Trigger replay (Step 14)

`webhook test` equivalent for dry-run and end-to-end replay without contacting upstream sources. The harness ships [`TriggerReplayCLI`](Replay/TriggerReplayCLI.swift) and [`TriggerReplayHarness`](Replay/TriggerReplayHarness.swift); host apps embed or wrap them in their own CLI or test harness.

```bash
# Dry-run: render route template + prompt preview (JSON stdout)
<trigger-cli> webhook test <route> --payload '{"key":"value"}' --data-directory <dir> --json

# Fire via file-event queue (requires a running host with file-event watcher enabled)
<trigger-cli> webhook fire <route> --payload '{"key":"value"}' --json

# Replay captured artifacts
<trigger-cli> file replay <event.json>
<trigger-cli> snapshot replay <trigger.json>
<trigger-cli> audit replay <trigger-id>

# Cron on-demand fire
<trigger-cli> cron fire <task-id>
```

| Flag | Purpose |
|------|---------|
| `--data-directory` | Trigger config directory (`channels.json`, `scheduled_tasks.json`, …) |
| `--events-dir` | Override events directory |
| `--in-process` | Synchronous pipeline test without enqueue |
| `--json` | Machine-readable stdout |

Admitted triggers are snapshotted to `{dataDirectory}/trigger_snapshots/<id>.json` for audit replay.

### Cross-trigger correlation

Each `HarnessTrigger` may carry an optional `TriggerCorrelation` triad:

| Field | Meaning |
|-------|---------|
| `rootId` | First trigger in the logical workflow |
| `parentTriggerId` | Immediate causal parent (`nil` for roots) |
| `correlationId` | Shared workflow id (defaults to `rootId` for root triggers) |

Lineage is assigned at **creation time** in ingress builders, `schedule_create`, and file-event producers — not stamped after dispatch. Root triggers (webhook, channel, standalone cron/file) set `rootId = correlationId = trigger.id`. Scheduled follow-ups inherit from the host trigger fingerprint (via `schedule_create`) or from explicit `rootId` / `parentTriggerId` / `correlationId` fields on file-event JSON.

Durable query surfaces (no separate lineage store):

- **`trigger_audit.jsonl`** — every activation decision includes the triad; filter by `correlationId` to list all legs (including rate-limited and dedup-hit).
- **`trigger_snapshots/<id>.json`** — full trigger JSON for replay of any admitted leg.

Lineage is best-effort over audit retention; rotated audit rows drop early legs from reconstructable chains.

Default fire path enqueues to `{eventsDirectory}/replay-<uuid>.json`; the host's file-event watcher consumes it when the server process is running.

## Channels (Messaging-as-Interface)

Channel code is split across two surface trees:

| Tree | Role |
|------|------|
| [`Surfaces/Interface/Channel/`](../Interface/Channel/) | Surface contract: `ChannelSurfacePlugin`, outbound/presentation, streaming sink, message-tool delivery, approvals |
| [`Surfaces/Triggers/Channel/`](Channel/) | Inbound provenance: intake, trust, session grammar, transport, lifecycle; assembles `ChannelPlugin` from surface + trigger slots |

- **`ChannelPlugin`** (Triggers) — composed runtime record: `surface` + `security` + `sessionGrammar` + platform `listener`.
- **Core `message` tool** — registered in `OrchestratorRuntimeService.buildToolManager`; assistant prose always streams as `text_delta`. The `message` tool is additive for structured/native output (blocks, buttons, media). Channel and interactive turns use `MessageOutputPolicy.structuredPreferred` for prompt guidance.
- **Session grammar** — `ChannelSessionGrammar.resolveSessionConversation` + `parentFallbackCandidates` wired through `TriggerSessionRouter`.
- **Lifecycle helpers** — `ChannelTypingKeepalive`, `ChannelTransportSupervisor`, `ChannelSessionLifecycleCoordinator`. Session reset drains per-conversation tasks; channel `stop()` tears down transport separately.

See [`Interface/Channel/README.md`](../Interface/Channel/README.md) and [`Documentation/channels-phase0-spike-report.md`](../../../Documentation/channels-phase0-spike-report.md).

## Registration control plane (`Registration/`)

Every path that registers a trigger converges on **`TriggerRegistrationService`**: the agent tool,
the file-event drop directory, the installer, and — from phase 3 — slash commands, CLI, and HTTP
admin. It owns normalization, validation, the create-time content scan, trust assignment, creator
stamping, origin capture, and the registration audit trail. Per-kind stores below it are persistence
only.

**The chokepoint is a type rule, not a convention.** `ScheduledTaskStore.upsert` accepts only a
`ValidatedScheduledTask`, whose initializer is private and whose only factory is
`ValidatedScheduledTask.validate(spec:authority:policy:existing:now:)`. A caller cannot reach the
store around the validator, because the value it would need to pass has no accessible initializer.
`commitTickResults` is the separate, explicitly-named path the scheduler uses to write back
`lastFiredAt` and age-out — it rewrites rows that already cleared validation and must never
introduce one.

**Authority is an explicit parameter, not ambient state.** `RegistrationAuthority` carries a
`RegistrationCreator` (`installer` / `owner` / `agent` / `subAgent`), the surface it arrived on, and
the origin to announce back to. The *client* resolves the creator from session state a model cannot
forge; the registration *spec* carries no identity fields at all. This is what lets non-conversational
clients register triggers — the previous create path hard-guarded on `ConversationScope.current`, so
a CLI, HTTP admin, or operator slash surface could not register anything.

| Creator | Max trust (schedule) | `permanent` | Durability default | May register |
|---------|---------------------|-------------|--------------------|--------------|
| `installer` | `system` | yes | durable | all kinds |
| `owner` | `user-deferred` | no | durable | all kinds |
| `agent` | `user-deferred` | no | session-scoped | all but `channel` |
| `subAgent` | — | no | — | none (policy flag to opt in) |

Webhook / channel / file-event ceilings are `known-party`: the payloads they admit are external
content regardless of who registered the route.

Notes:

- `permanent` and `trust` are **absent from the tool-facing spec surface**, not runtime-checked. The
  trust ceiling is enforced by schema absence so a confused deputy has nothing to route around.
- Installer entries use **write-if-missing**. A user deletion tombstones the id
  (`deletedSystemTaskIDs` in the task file envelope), so reinstalls do not resurrect it. Disabling a
  feature in config *uninstalls* without tombstoning, so re-enabling works.
- System entries are **listed but immutable from the agent tools**; a human may still delete one.
- `ScheduledTask.createdBy` is the canonical attribution; `ownerAccountID` and
  `createdByConversationID` are mirrors the validator keeps in sync for the existing owner/lineage
  access checks. Legacy rows resolve through `ScheduledTask.resolvedCreator`.
- Mutation authority is **symmetric**: `assertMutable` gates delete *and* on-demand fire, so a
  creator that may not register a trigger cannot delete or fire one either, and a `system` entry is
  listable but not invokable from the agent tools.
- The scheduler tick commits a `ScheduledTaskTickResult` **delta** (fired ids, removed ids), not a
  replacement row set, so a registration landing between the tick's read and its commit survives.

### Schedule lifecycle (phase 1)

`schedule_create` now exposes `title`, `delivery`, `deliveryWebhookURL`, `routingMode` and `durable`,
and three tools join it: `schedule_update`, `schedule_pause`, `schedule_resume`.

- **`enabled`** is the pause knob. A paused row keeps its id, history and next-fire anchor; the
  scheduler skips it. The `enabled` check runs *before* age-out — an explicitly paused task is the
  clearest evidence the user has not forgotten it, and age-out exists to collect forgotten ones.
  `catchUp` drains a paused task's undelivered run instead of skipping it, so resuming months later
  does not replay a `[missed]` fire for a long-past window.
- **`durable`** finally decides something. `false` (the default for agent-created tasks) routes the
  row to `SessionScopedScheduledTaskStore` — in memory, never serialized, gone when the process
  exits. `true` goes to disk. Scheduler and registration endpoint **must share one session store**;
  two instances mean tasks that exist but never fire.
- **Update is re-validation.** A patched prompt goes back through the scanner, a patched schedule
  back through expression validation. Rewriting the prompt of a task that fires into a *different*
  conversation is refused outright (`cross_conversation_payload_change`): the original create cleared
  an approval gate for a specific prompt, and the rewrite has not.
- **Pause is not.** `setScheduleEnabled` uses `ValidatedScheduledTask.enabledToggle`, which changes
  no field validation covers. Routing a toggle through the full validator would mean a row with a
  stale prompt or a sub-second interval cannot be paused — precisely the rows a user needs to stop.
- **Attribution, trust and origin are create-time.** An update re-validates content; it does not
  re-author the row. Otherwise a pause issued from another conversation would re-attribute the task,
  demote an installer row's trust, or overwrite the channel a reminder answers into.
- **Routing is resolved once, at registration.** `nil` infers (threaded when there is a target,
  isolated otherwise); an explicit `.isolated` is honored and clears the target. The trigger builder
  honors the stored value, with one carve-out: a stored `.isolated` that still carries a target is a
  pre-registration-layer row where `.isolated` was merely the struct default, so it keeps routing
  threaded rather than being re-homed into a different session key.
- **`announce` delivers.** `TriggerOriginRef` is captured at create — from the host-conversation
  fingerprint when the caller sits in a channel-backed conversation — and stamped into the trigger as
  `origin*` metadata. `deliverCron` sends through that channel's plugin. A threaded run needs no
  delivery (its answer is already in the conversation) and is audited as such; an isolated run with
  no channel origin logs a warning rather than dropping silently.
- Validation gained two floors: an empty `payloadText` is refused, and `every` intervals below
  `ScheduledTaskCreateScanner.minimumIntervalMs` (1s) are refused — `intervalMs > 0` alone admitted a
  1 ms recurring task.

Still open: `timezone` is decoded on file-event payloads but neither stored on `ScheduledTask` nor
honored by `CronSchedule`; session-scoped rows die with the process but are not dropped on
conversation reset (no lifecycle hook is wired); `schedule_update`'s approval gate is a hard refusal
rather than an approval prompt, pending the phase-3 tool consolidation.

### Divergence: `events/` serves two roles

`file-event-triggers.md` keeps the event *queue* and the *configuration store* strictly separate. We
keep both in `events/`, discriminated by `FileEventPayload.type`: `immediate` is a queue event,
`periodic` / `one-shot` are registrations. The registration half now goes through
`TriggerRegistrationService`, so those rows get creator stamping and an audit trail and are visible
to `schedule_list` — previously they were written straight to the store with no creator and were
both invisible and undeletable from the tools.

## Cost ceilings (`Budget/`)

Activation-policy stage 4, denominated in **spend**. Rate limits cap *events*; a trigger's cost per
event is unbounded, so 30/min under an unbounded `agentTurn` is not a bounded bill. This is the one
gate that speaks the right unit.

- **`TriggerBudget`** — scope (`source` / `trustClass` / `global`) × window (`day` / `month`) ×
  `ceilingUSD`. Resolution is most-specific-wins for the *governing* rung, but **every matching
  ledger is charged**, so the global ledger sees every dollar and admission refuses if *any*
  applicable ledger is at its ceiling. Defaults ship per trust class — a budget that exists only when
  someone remembers to configure it protects nobody — and are tightest for `unknown-party`.
- **`TriggerSpendLedgerStore`** persists to `trigger_spend_ledger.json`. A daily ceiling that resets
  on process restart is a ceiling an attacker resets by crashing the process. Corrupt ledger throws
  rather than truncating, for the same reason.
- **Admission is exact, not estimated.** It compares recorded history against the ceiling. A run
  admitted at $9.99 of a $10 ceiling can still overshoot — by at most one run's worst case, bounded
  by whatever per-run caps the task carries, not by this gate.
- **Attribution is by trigger-host conversation.** Isolated and delegated fires get their own
  conversation, so its whole cost belongs to that source — which also gives sub-agent fan-out roll-up
  for free. Threaded fires share the user's conversation with their own turns and are deliberately
  **not** billed; mis-attributing the user's typing to their reminder is worse than a known gap.
- **Charging is reconcile-on-next-admit.** `dispatchTriggerMessage` is fire-and-forget, so there is
  no completion hook for isolated runs. A fire records a `TriggerPendingRunCharge` when it is routed;
  the next admission for that source settles anything outstanding. Exact, idempotent (each
  conversation settles once), and restart-safe.
- **The meter is host-supplied.** `Configuration.conversationCostUSD` answers "what did this
  conversation cost" from the authoritative per-run rollups. The harness knows which conversation
  belongs to which source; the host knows what it cost. **Without the meter the ledger never accrues
  and ceilings never bind** — boot logs `trigger_budgets_unmetered` rather than presenting an
  unmetered ceiling as enforcement.
- **Ladder: warn (75%) → defer (100%) → suspend** (after N consecutive fully-breached windows).
  `degrade` is deliberately absent — it needs per-task model pinning, which does not exist yet.
  Every rung notifies through the origin channel; a trigger the user registered is a standing
  instruction, and making it silently stop firing is a correctness bug in a cost-control costume.
- Ledger IO failure **fails open** and logs. Refusing every trigger because a file is unreadable
  turns a bookkeeping fault into an outage of the user's automations.

Naming debt: `TriggerCostCeilingGate` is now a per-initiator burst cap denominated in *fires*, not
cost — it survives as a cheap O(1) pre-filter in front of the ledger. It should be renamed
`TriggerInitiatorBurstGate`; that rename touches ~24 test fixtures and is safest done with an IDE
refactor rather than by hand.

## Webhook lifecycle (phase 2)

`WebhookDynamicRouteStore` was previously unreachable — `upsert` had zero callers and there was no
delete at all. Routes now go through the same registration endpoint as schedules.

- **Chokepoint:** `upsert` accepts only a `ValidatedWebhookRoute`; `saveUnlocked` is private. The one
  `WebhookRoute(...)` construction site in the surface is inside `validate`.
- **Secrets are minted, shown once, and never echoed.** `subscribe` returns a 32-byte base64url
  secret in its result; `redacted` **clears** it rather than masking, because an empty secret means
  "keep the stored one" at the registration boundary — a masked placeholder round-tripping through
  an update would have become the HMAC key and broken every upstream delivery.
- **The prompt template is scanned at create.** It is agent-authorable text that becomes model input
  on every delivery, and it was the one prompt in the system that wasn't scanned.
- **`source` is stamped `.dynamic` on load.** Rows defaulted to `.static`, which inverted the
  "config wins" collision rule. Registration also refuses a name held by a static route.
- **Ownership is enforced, not just creator class.** `assertWebhookMutable` gates update / pause /
  delete on `createdBy`'s owner account and refuses static rows; `listWebhooks(authority:)` is
  owner-scoped and redacted. Before this, `createdBy` was stamped and never read — any conversation
  could retarget any route.
- **`subscribe` refuses an existing name** (`already_exists`); use `update`. Re-subscribing used to
  reset the template and delivery target while reporting success.
- **Pause does not re-validate** (`ValidatedWebhookRoute.enabledToggle`), same reasoning as the
  schedule path: a route whose stored template trips a scanner rule added later is exactly the route
  a user needs to stop.
- **Rate limiting:** per-route `rateLimitPerMin` is finally plumbed, plus one shared bucket for all
  runtime-registered routes. The activation policy's key is now source-prefixed — it and the webhook
  gate were consuming the *same* bucket, so every admitted delivery recorded two hits and silently
  halved the configured limit.
- A corrupt `webhook_subscriptions.json` now **throws** instead of decoding to `[]`; the old
  behavior meant the next write deleted every other subscription.

Known limits: the route-count cap is checked before the write, so concurrent registrations can
exceed `maxDynamicWebhookRoutes` by a small margin; the `webhook` tool name is unqualified, so
confirm no non-trigger tool claims it; `test` renders the template without firing, which is the
dry-run primitive, not a full replay.

## Control surfaces: slash commands (phase 3)

The same operations reach the model and the human through **one handler**. A slash dispatch arrives
as a single raw line (`SlashCommandParser` splits on the first whitespace and hands the rest over —
there is no flag parser anywhere in the harness), so `TriggerToolArgumentBridge` rewrites that line
into exactly the arguments the model would have produced and lets the existing handlers run
unchanged. For `/schedule`, the subcommand also selects *which* of the seven schedule tools runs.

`SlashCommandConfiguration.ToolDispatchCommand` already existed and was unused, so the commands
themselves are **configuration, not Swift** — no change to `SlashCommandDispatchService`'s hardcoded
name switch. Add to `PromptConfig.json`:

```jsonc
"slashCommands": {
  "toolDispatchCommands": [
    {
      "command": "schedule",
      "toolName": "schedule_create",
      "argMode": "parsed",
      "ownerOnly": true,
      "bypassTier": "queued",
      "description": "Manage scheduled triggers.",
      "argumentHint": "list | create --cron <expr> <prompt> | pause <id> | resume <id> | rm <id> | run <id>",
      "hiddenKeywords": "cron reminder timer recurring task automation"
    },
    {
      "command": "webhook",
      "toolName": "webhook",
      "argMode": "parsed",
      "ownerOnly": true,
      "bypassTier": "queued",
      "description": "Manage inbound webhook subscriptions.",
      "argumentHint": "list | subscribe <name> [--prompt …] | pause <name> | delete <name> | test <name> --payload '{…}'",
      "hiddenKeywords": "hook http callback subscribe integration"
    }
  ]
}
```

`toolName` on the `/schedule` row is only the dispatch entry point — the bridge rewrites the call to
the tool the subcommand names, so `/schedule pause abc` runs `schedule_pause`.

The parser supports `--key value`, `--key=value`, bare `--flag` (true), and single/double quotes —
quoting matters because a prompt is the point of `/schedule create` and prompts contain spaces.

**Not done, deliberately:** an unauthorized `ownerOnly` command still falls through to plain text
(`SlashCommandDispatchService` maps `.unauthorized` to `nil`), so `/webhook delete prod` typed by a
non-owner becomes a chat message rather than a denial. Changing that is a three-line edit, but
`SlashCommandDispatchServiceOwnerGateTests` asserts the current semantics and that test was not in
scope here — worth doing as its own change with the test updated alongside.

## Upcoming work (next steps)

| Step | Work |
|------|------|
| — | Tool-output provenance audit via `ToolResultExternalContentMiddleware` (see [`ToolSystem` README](../../core/ToolSystem/README.md)) |

**Step 15 (done):** All non-user, non-harness tool output is wrapped by `ToolResultExternalContentMiddleware` at runtime delivery order 200. Trigger inbound content continues to use `TriggerPromptBuilder` + the same `ExternalContentEnvelope` primitive.

## Trigger message format

Trigger messages are user-role messages that begin with a metadata line:

```text
[trigger] key1=value1; key2=value2

Message body text...
```

This format helps models distinguish automation-driven input (cron jobs, scripts, external agents) from live user chat.

### Codec utilities (in-tree)

| File | Role |
|------|------|
| [`Prompt/TriggerContentBuilder.swift`](Prompt/TriggerContentBuilder.swift) | Build/parse `[trigger]` metadata line + body |
| [`Prompt/Message+Trigger.swift`](Prompt/Message+Trigger.swift) | `Message` / `CachedMessage` read-side helpers |
| [`Scheduling/CronSchedule.swift`](Scheduling/CronSchedule.swift) | Five-field cron parsing + `nextDate(after:)` |
| [`HTTP/TriggerRESTRouteModule.swift`](HTTP/TriggerRESTRouteModule.swift) | `TriggerMessageRequest` + content preparation |

`TriggerPromptBuilder` calls `TriggerContentBuilder.buildFullContent` when assembling harness trigger prompts.

### Reading trigger content

- Full content is stored in `content` (`[trigger] ...` + blank line + message body).
- Parsed helpers: `triggerMetadata: [String: String]?`, `messageBodyContent: String`.
- Use metadata for UI display (source/type) and trust/auth decisions.

### Removed API ingress

All API/WebSocket trigger-ingress surfaces are removed from current contracts:

- `POST /api/messages/trigger` (removed)
- `POST /api/conversations/{id}/messages/trigger` (removed)
- WebSocket `type:send_trigger_message` (removed)

Trigger dispatch goes through the harness trigger gate (replay CLI, file-event queue, webhooks, cron, or channel listeners)—not through interactive client APIs.

## Related

- [`SubAgentPool`](../../core/SubAgentPool/README.md) — delegated spawn + completion machinery
