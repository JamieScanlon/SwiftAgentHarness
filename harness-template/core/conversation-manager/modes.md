# Interaction Modes

## TL;DR

Treat the conversation's `state.mode` as an **id into a `ModeRegistry` of `ModeProfile` records**, not as a hard-coded enum. A `ModeProfile` is a structured descriptor with one *slice per consuming inner-ring layer* — Tool System, Context Engine, Agent Runtime, Model Pool, Sub-Agent Pool — plus optional enter/exit hooks. Each layer reads only its slice; unknown profile fields are ignored. Adding a new mode is registering a new profile, not editing every layer.

The system prompt is assembled by the Context Engine each turn from a **sectioned template** (Identity / Capabilities / Constraints / Mode directive / Memory / Skills / Tool guidance / Attachments / Extra instructions). A profile's `context` slice plugs into specific sections — directive, suppressions, overrides — rather than blob-prepending a string.

A `PermissionMode` registry (`default` / `plan` / `acceptEdits` / `bypassPermissions` / `dontAsk` / `auto`) plus `EnterPlanModeTool` / `ExitPlanModeTool` transition tools and a `prepareContextForPlanMode` hook are the closest single-binary-CLI realization, narrowed to the permission slice. The recommendation here generalizes that shape to all five inner-ring slices.

---

## Recommendation

### Why mode is a first-class field on the conversation

Mode is a **long-lived property of the conversation**, not a per-turn flag. Switching mid-conversation is a user-meaningful event ("now we're working, not chatting"); the conversation's history should reflect it; multi-client UIs need to render the change consistently; sub-agents and branches need to know what to inherit. Per-turn options that don't survive between turns belong in `runOptions`, not in mode. The Conversation Manager owns the field for the same reason it owns attachments, system-prompt overrides, and routing — it's the resource of record for "what's true about this conversation right now."

The Manager *owns* mode but does not *enforce* it. Enforcement is distributed across the layers that actually do the work — that's by design, because the alternative (Manager dictating to every other layer) puts cross-layer policy in the wrong place and forces the Manager to know about every consuming layer's internals.

### `ModeProfile` shape

A profile is a structured descriptor with one slice per consuming inner-ring layer:

```ts
type ModeProfile = {
  id: string                            // "chat" | "agent" | "plan" | custom
  label: string                         // user-facing name
  description: string
  symbol?: string                       // for status-line rendering
  extends?: string                      // optional inheritance from another profile

  // Tool System reads this
  tools?: {
    allow?: string[] | "*"
    deny?: string[]
    approvalPolicy?: "never" | "side-effects" | "all"
  }

  // Context Engine reads this
  context?: {
    compaction?: "off" | "shallow" | "full"
    modeDirective?: string              // fills the "Mode directive" prompt section
    sectionOverrides?: Partial<Record<PromptSection, string>>
    suppressSections?: PromptSection[]  // sections this mode omits entirely
    memoryInjection?: "on" | "off" | "skills-only"
    includeSkills?: boolean
    includeToolGuidance?: boolean
  }

  // Agent Runtime reads this
  runtime?: {
    maxIterations?: number              // chat = 1, agent = unbounded
    autoContinue?: boolean
    stopOnApprovalRequest?: boolean
    termination?: TerminationPolicy     // how the loop decides a turn is over
  }

  // Model Pool reads this
  model?: {
    query?: ModelQuery                  // capability-based selection
    fallback?: ModelQuery
    thinkingConfig?: ThinkingConfig     // per-mode thinking default; overrides settings default, overridden by conversation.routing.modelOptions.thinkingConfig
  }

  // Sub-Agent Pool reads this
  subAgents?: {
    allow?: string[] | "*"
    maxDepth?: number
    childModeOnSpawn?: string           // mode id new sub-agents default to
  }

  // Optional transition hooks (run on enter/exit)
  hooks?: {
    onEnter?: (ctx: TransitionContext) => Promise<void>
    onExit?: (ctx: TransitionContext) => Promise<void>
  }
}
```

The user's three example modes drop in cleanly without any layer learning new vocabulary:

| Mode | tools | context | runtime | model |
|---|---|---|---|---|
| `chat` | `allow: []` | `compaction: "off"`, `includeSkills: false`, `includeToolGuidance: false`, directive: "be conversational, concise" | `maxIterations: 1`, `termination: bare-message` | fast/cheap tier; `thinkingConfig: "disabled"` |
| `agent` | `allow: ["*", "finish", "ask_user", "think"]` | `compaction: "full"`, full sections | unbounded; `termination: terminal-tool` + forced-choice recovery | capable tier; `thinkingConfig: "adaptive"` |
| `plan` | `allow: ["read_*", "search", "fetch", "write_doc", "exit_plan_mode"]`, `deny: ["bash", "exec", "edit_file", "write_file"]` | `compaction: "full"`, directive: "research and plan; do not execute side effects" | bounded; `termination: terminal-tool` (`exit_plan_mode`), `stopOnApprovalRequest: true` | reasoning-strong; `thinkingConfig: { level: "high" }` |

Plan mode's "no shell" property is just the Tool System reading `tools.deny` from whichever profile is active. No layer special-cases the string `"plan"`.

### Termination policy

`runtime.termination` is the slice that answers *how does the loop know a turn is over*. It earns a named type because that question has two legitimate answers and the right one is mode-shaped, not global.

```ts
type TerminationPolicy = {
  policy: "bare-message" | "terminal-tool"
  recovery?: {                            // only meaningful under "terminal-tool"
    strategy: "forced-tool-choice"
    rollbackStalledTurn?: boolean         // re-roll instead of polluting history
    maxAttempts?: number                  // consecutive stalls before bounded-stop
    reminder?: "off" | "escalating"       // ephemeral, non-user-role nudge
  }
}
```

- **`bare-message` (chat).** The turn ends when the assistant emits a message with no tool calls — the conventional chat affordance: one input → reasoning/tool use → a final spoken answer → stop. Five of six OSS harnesses use this as their only rule.
- **`terminal-tool` (agent).** The loop continues by default and ends only when the model calls a *halt-signal* tool — `finish` to complete, `ask_user` to escalate a block. A bare message (no tool call, no terminal tool) is **always** treated as a stall, not a stop: the loop re-issues the turn under forced tool choice (rolling the stalled turn out of history) so the model is compelled to act. This is the autonomous run-to-completion shape; it removes the "model narrated instead of acting, user had to type *continue*" failure mode, where each stall left in history few-shots the next.

  Recovery is **intrinsic** to this policy, not an opt-in toggle. There is deliberately no knob to make a bare message stop under `terminal-tool`: doing so would discard the policy's entire purpose (refusing to read silence as "done") and collapse it into `bare-message` under another name. The genuine middle ground — an agent that may *either* call `finish` *or* yield by going quiet — is a distinct named policy (`"hybrid"`) if you ever need it, not a flag that silently duplicates `bare-message`. The `recovery` block only tunes *how* the stall is handled (rollback, attempt cap, reminder style), never *whether*.

The decision is driven by the slice, not by a mode-name check: the Agent Runtime executes **one generic loop** parameterized by `termination`. Which tool is a halt signal is *not* named in the mode either — it's a `haltsLoop` property of the tool definition read by the Tool System. So an agent mode contributes exactly two things across two slices: the terminal tools in its `tools.allow`, and the policy in its `runtime.termination`. Neither references a mode name. See [../agent-runtime/ § Termination policy and stall recovery](../agent-runtime/#termination-policy-and-stall-recovery) for the loop mechanics, the `evaluateTermination` decision function, the two-budget recovery cap, and the provider-agnostic forced-tool-choice mapping.

Plan mode is the same `terminal-tool` policy whose halt signal is `exit_plan_mode`; it typically runs with `recovery` off and `stopOnApprovalRequest: true`. It is not special-cased — it is a third configuration of the same loop.

### The `ModeRegistry`

The mode registry is a **sibling of the other registries** in the auxiliary taxonomy (Tools, Skills, MCP servers, Memory). Loaded by the Conversation Manager at startup. Three operations matter:

```ts
interface ModeRegistry {
  register(profile: ModeProfile): void                    // at startup or via plugin
  list(): ModeProfile[]                                   // for UIs rendering a picker
  resolve(id: string): ModeProfile                        // every consuming layer calls this
}
```

`resolve` walks the `extends` chain and returns a flattened, fully-resolved profile so consumers don't have to. Resolution is cached by id; cache busts on `register` of the same id (hot reload during development).

The registry's bootstrap inputs:

- **Built-in profiles** the harness ships with (`default`, `agent` at minimum; `chat` and `plan` if applicable).
- **Plugin contributions** — plugins call `register(...)` during their bootstrap phase, in the same way they contribute tools or skills.
- **Config-file profiles** — read from a project-level config (e.g., `.harness/modes/*.yaml`) for per-project mode definitions without writing code.

A profile id is global; conflicts at registration time error rather than silently overwrite. To customize a built-in mode, register a new id that `extends: "agent"` and override the slices that differ.

### Per-layer integration

Every consuming layer queries `registry.resolve(conv.state.mode)` at the start of its work and reads only the slice it owns.

**Tool System** queries the `.tools` slice when assembling the tool list each turn. The mode's `allow` / `deny` composes with the conversation-level `routing.toolWhitelist` (intersection — both must permit). The `approvalPolicy` field feeds the permission gate. This filtered view is also what `GET /conversations/{id}/tools` returns — the global registry narrowed by conversation whitelist ∩ active mode. Per-run whitelists (passed via `appendInput` options) may narrow the set further at runtime but are not reflected in the endpoint response. See [../tool-system/](../tool-system/) and [../communication-layer/](../communication-layer/).

**Context Engine** reads `.context` during the `assemble` phase to decide compaction policy, fill the Mode directive section of the system prompt, and decide which sections to emit at all. See "System-prompt assembly under modes" below for detail. See [../context-engine/](../context-engine/).

**Agent Runtime** reads `.runtime` to bound iterations, decide autoContinue, and — via `.runtime.termination` — choose *how a turn ends*. Chat mode's `bare-message` policy stops on a no-tool-call turn (with `maxIterations: 1`, one input → one response → stop). Agent mode's `terminal-tool` policy continues until the model calls a halt-signal tool and recovers stalls via forced tool choice. Plan mode's `terminal-tool` policy halts on `exit_plan_mode` and parks on `stopOnApprovalRequest: true`. The runtime runs one generic loop over these as data — see [../agent-runtime/](../agent-runtime/).

**Model Pool** reads `.model.query` as the per-conversation default model query, composing with the conversation-level `routing.modelQuery` (mode is the default; per-conversation override wins). Plan mode might prefer a reasoning-strong model; chat mode a cheap fast one.

The Pool also reads `.model.thinkingConfig` to determine whether extended thinking is enabled for calls in this mode. Resolution order: settings-level default → mode profile → `conversation.routing.modelOptions.thinkingConfig` (per-conversation runtime override, wins last). A user toggling thinking on or off at runtime patches `conversation.routing.modelOptions.thinkingConfig` without changing the active mode. See [../model-pool/](../model-pool/) for the full type definitions and resolution logic.

**Sub-Agent Pool** reads `.subAgents` to decide which delegates to expose and what mode new sub-agents default to. See "Sub-agent inheritance" below.

The Conversation Manager itself reads only `.hooks` (to fire on transitions) and `.label` / `.symbol` (to publish on the state topic for UI rendering). It does not read the per-layer slices — those are private contracts between the profile and each consuming layer.

### System-prompt assembly under modes

The system prompt is **not one string**; it's a structured artifact assembled each turn by the Context Engine's `assemble` phase. A reasonable section ordering:

```
[Identity]              who/what the agent is
[Capabilities]          what it can do (high-level, not a tool catalogue)
[Constraints]           hard rules — safety, scope, boundaries
[Mode directive]        the mode-shaped behavioral block
[Memory]                injected from the Memory store
[Skills]                loaded skill summaries
[Tool guidance]         high-level guidance about tool use
[Attachments]           inline content or summaries of attached resources
[Extra instructions]    per-conversation `prompt.extraInstructions`
```

Each section is independently filled by a contributor. The Engine emits them in order; contributors don't fight over placement.

A `ModeProfile.context` slice plugs into this in four levers, in increasing order of strength. Most modes only need the first two.

**1. Section directive — fills the Mode directive section.** The most common case. `context.modeDirective` is the string the Engine slots into the Mode directive section. Identity, Capabilities, Constraints come from harness defaults; the directive adds the mode-specific framing on top.

```ts
{
  id: "plan",
  context: {
    modeDirective: `
You are in PLAN mode. Research the problem, gather context, and produce a
written plan. You will NOT execute side effects: do not run shell commands,
do not modify files outside the plan document. End every response with a
"Next steps" section the user can approve. When the plan is complete and
unambiguous, call the exit_plan_mode tool — do NOT ask the user textually
whether to proceed.
    `.trim()
  }
}
```

**2. Section suppressions — turn whole sections off.** Booleans/enums on the profile, not strings. Chat mode turns off Tool guidance, Skills, and Memory:

```ts
{
  id: "chat",
  context: {
    memoryInjection: "off",
    includeSkills: false,
    includeToolGuidance: false,
    modeDirective: "You are in conversational mode. Be concise."
  }
}
```

The Engine reads these flags at assemble time and just doesn't emit those sections. Cleaner than putting "ignore your tools" into a `modeDirective` and hoping the model listens.

**3. Section overrides — replace a section's content.** For modes that need to redefine a default section, not just add to it. A `code-review` mode might replace Identity and Capabilities entirely:

```ts
{
  id: "code-review",
  context: {
    sectionOverrides: {
      identity: "You are a senior software engineer doing code review...",
      capabilities: "You can read code, suggest changes via a write_review tool..."
    }
  }
}
```

Heavier than a directive — most modes shouldn't need it — but available when the persona needs to shift fundamentally.

**4. Full-prompt override — escape hatch.** Conversation-level `prompt.systemOverride` already exists in the schema and replaces the whole assembled prompt. A mode can default a conversation to using an override. This is the least composable lever — once you override the whole prompt, memory injection / skills / per-conversation extra-instructions all stop applying unless re-added. Use sparingly.

The assembled prompt lands as a `SystemPromptAssembly` checkpoint in `derivedEvents` (per [README.md § Concurrency](./README.md#concurrency-and-the-compaction-lock)) — the mode's contribution is auditable for any turn just like every other transformation.

### Mode-transition hooks

Some modes need to do work on enter or exit beyond what the per-turn slices express. Plan mode, for example, can run a `prepareContextForPlanMode` function on enter (sets up the plan file, attaches a plan-mode system message reminding the agent of the plan-file path) and a transition hook on exit (clears the plan-mode flag, archives the plan). The plan artifact these hooks provision has its own lifecycle contract — identity, fork/resume semantics, compaction survival, tiered recovery — specified in [planning.md](./planning.md).

The profile's `hooks.onEnter` and `hooks.onExit` are async functions the Conversation Manager runs synchronously around the mode change:

```ts
type TransitionContext = {
  conversationId: string
  fromMode: string                // previous mode id
  toMode: string                  // new mode id
  manager: ConversationManagerAPI // limited subset for hook use
}
```

The Manager's mode-change sequence:

1. Validate `toMode` exists in registry.
2. Run current profile's `hooks.onExit(ctx)` — cleanup of the outgoing mode's state.
3. Atomically swap `state.mode`.
4. Run new profile's `hooks.onEnter(ctx)` — setup of the incoming mode's state.
5. Append `ModeChangeMessage` to `rawEvents`.
6. Emit `modeChanged` on `conversation/{id}/state`.

If either hook throws, the swap is rolled back and the mode change fails. Hooks should be idempotent — they may run during recovery after a crash.

Hooks should be sparing. If a mode is doing significant work in `onEnter`, that's a signal the work belongs in a per-turn slice instead — fewer side effects, easier to reason about, naturally re-runs on subsequent turns. Reach for hooks only when the mode change has out-of-band consequences (filesystem state, attachment manipulation, external notifications).

### Mode change at runtime

Mode is changed via the Manager's standard `update` operation:

```ts
manager.update(conversationId, { state: { mode: "plan" } })
```

The Manager:

1. Validates the mode id against the registry. Unknown mode → reject.
2. Checks `state.runStatus`. If `running`, **reject by default** — same family as the mid-run prompt-override anti-pattern. Optionally queue the change to take effect on the next turn (mark `state.pendingMode`; clear and apply it on `runStatus → idle`).
3. Runs the transition hooks per the sequence above.
4. Appends a `ModeChangeMessage` to `rawEvents` so the switch is part of conversation history and survives branching.
5. Emits `modeChanged` on `conversation/{id}/state` with both old and new mode for diffing.

The next turn's projection is assembled fresh — there is no system-prompt or context cache that survives a mode change. The Engine's `assemble` consults the new profile.

```ts
interface ModeChangeMessage extends Message {
  kind: "modeChange"
  fromMode: string
  toMode: string
  initiatedBy: "user" | "agent" | "trigger" | "system"
  reason?: string                 // optional — e.g. "user pressed shift+tab", "ExitPlanMode tool called"
}
```

`ModeChangeMessage` is a `Message` subtype, not a `Checkpoint`. It's part of the source-of-truth log — the projection function may emit a synthetic system-prompt note on the boundary ("[mode changed to plan at this point]") so the model has visible signal of the transition.

### Mode-callable transition tools

A strong pattern: expose mode transitions as **tools the model can call**. `EnterPlanModeTool` and `ExitPlanModeTool` are tools whose only effect is to call `manager.update(...)` with the appropriate target mode (and run the hooks).

This is the cleanest answer to "how does the agent know it's done planning?" — it calls the exit tool, the Runtime sees the mode flip, the next turn assembles under the new mode. The exit tool's prompt should make the contract explicit ("call this when your plan is complete; do not ask the user textually whether to proceed"). 

Mode-callable tools are themselves filtered by the active mode's `tools.allow`. Plan mode's allow-list must include `exit_plan_mode`; default mode's allow-list must include `enter_plan_mode` if the agent should be able to enter plan mode itself.

### Sub-agent inheritance

Sub-agent runs are nested conversations (per [README.md § Sub-agent runs as nested conversations](./README.md#sub-agent-runs-as-nested-conversations)). Mode inheritance is a spawn-time decision, not an automatic carry-over from the parent. The recommendation:

- **Default: pin to `agent` mode** for sub-agents regardless of parent mode, unless the parent's profile specifies otherwise via `subAgents.childModeOnSpawn`.
- **Sub-agent profiles are a thing.** A `research-subagent` profile that's plan-shaped (no exec, reasoning model) but tighter on delegate allow-list is a useful pattern for spawning constrained workers from an agent-mode parent.
- **The parent's mode never silently applies to children.** A chat-mode parent shouldn't accidentally run sub-agents in chat mode (which has `maxIterations: 1` — they'd halt on the first turn).
- **Thinking is suppressed for sub-agents by default.** The spawned mode profile's `model.thinkingConfig` defaults to `"disabled"` unless the profile explicitly sets otherwise. A parent with `thinkingConfig: { level: "high" }` must not silently propagate that budget into every sub-agent it spawns — the token cost compounds rapidly across parallel delegates. Sub-agent profiles that genuinely need thinking (e.g., a deep-research sub-agent) should declare it explicitly in their profile.

The spawn call decides; the parent mode's `subAgents.childModeOnSpawn` is the configurable default; the harness's hard default is `agent`.

### Branching behavior

A branch inherits `state.mode` from the parent at the branch point. The `ModeChangeMessage` history through the branch point is inherited along with the rest of `rawEvents`, so the branch's mode-change history is consistent with the parent's. After branching, mode can be changed independently — the branch and the parent diverge as they would for any other conversation property.

**Caveat for sub-agent forks.** A sub-agent spawned with `context: "fork"` is a branch under this rule — so it inherits the parent's mode, and with it the parent's tool/skill allow-list, *by default*. That is correct for a user-initiated branch and wrong for a delegated worker. Branching copies *context* (the inherited `rawEvents`); it must not be allowed to copy *capability*. Reassign the child's mode from its own role immediately after the fork, and route every spawn shape (fork and isolated) through one capability-assignment step, so a constrained worker can't silently run with the full parent toolset. See [Sub-Agent Pool § Anti-patterns](../sub-agent-pool/README.md#anti-patterns).

If the branch is at a point *before* a parent's mode change, the branch's current mode is whatever was active at the branch point, not the parent's current mode. This falls out of inheriting `rawEvents` through the branch point and replaying the mode-change events.

### Persistence

`state.mode` is part of the conversation metadata persisted by the backend (per [README.md § Persistence as a backend driver](./README.md#persistence-as-a-backend-driver)). Mode-profile *contents* are not persisted with the conversation — only the id is. A conversation that referenced a profile that was removed from the registry resolves to the harness's `default` profile with a warning logged.

This is deliberate: profiles are infrastructure (defined in code or config); a conversation's mode is data (a pointer into infrastructure). The same separation as for tool schemas (registered in code; conversations reference them by name).

### Surfacing modes

`registry.list()` is what UIs render as a mode picker. The profile's `label`, `description`, and `symbol` fields are the user-facing surface. A symbol convention (`⏵⏵` for accept-edits-style modes; a pause icon for plan mode) is a useful pattern for at-a-glance mode rendering.

Slash commands like `/mode plan` are sugar over `manager.update(id, { state: { mode: "plan" } })`. If your harness has hotkeys for mode cycling, the cycle order should follow `registry.list()` ordering, with `default` first.

### HTTP exposure of the registry

`registry.list()` is a server-side interface method; multi-client and web UIs need an HTTP transport to it. The recommendation is a top-level REST resource:

```
GET /api/modes
→ { profiles: ModeProfileDTO[] }
```

The endpoint is stateless — no conversation id required — because profiles are infrastructure, identical across conversations, and pre-conversation UIs (new-conversation flows, settings pages) need the catalogue before any conversation id exists. The list is ordered to match `registry.list()` so client-side hotkey cycle order matches server-side ordering.

This follows the same shape as other "list available X" endpoints in harnesses that have an HTTP surface — `GET /api/settings/models` and `GET /api/mcp/servers` for model and MCP-server catalogues. The mode registry is a sibling registry; the endpoint is its sibling endpoint.

**DTO, not raw profile.** Don't serialize `ModeProfile` directly. The internal type carries function-valued fields (`hooks.onEnter`, `hooks.onExit`) and capability predicates (`model.query`) that don't serialize cleanly and aren't useful to clients. Spec a public DTO instead:

```ts
type ModeProfileDTO = {
  id: string
  label: string
  description: string
  symbol?: string
  // Display-oriented summaries derived from the resolved profile.
  // Hints for picker UIs ("no tools", "reasoning-strong"), NOT a
  // round-trippable representation of the slices.
  summary: {
    toolPolicy?: "all" | "none" | "restricted"   // derived from tools.allow/deny
    compaction?: "off" | "shallow" | "full"
    maxIterations?: number | "unbounded"
    modelTier?: string                            // human-friendly model query summary
  }
}
```

The DTO is the wire contract; the internal `ModeProfile` shape can evolve without breaking clients. Sanitization happens at the serializer; `resolve` still returns the full profile to in-process layers.

**Hot-reload via change events.** Plugins can `register(...)` during bootstrap and config-file profiles may be hot-reloaded in development, so the registry isn't strictly immutable for the server's lifetime. A pure GET goes stale. Pair the endpoint with a server-wide event:

```
event:   registryChanged
topic:   server/registries
payload: { registry: "modes" }
```

This rides the same event channel that already carries per-conversation `modeChanged` notifications; it's just published on a server-wide topic rather than a conversation-scoped one. Clients re-issue `GET /api/modes` on receipt. A polling fallback (`Cache-Control` + `Last-Modified` on the GET) is acceptable for clients that aren't on the event stream.

For WS-first harnesses with no pre-conversation HTTP surface , pushing the registry snapshot on connect over the same WebSocket and skipping REST is a defensible variant — acceptable when there's no pre-conversation UI that needs the catalogue.

**REST and the state topic own different things.** Worth stating explicitly:

- **REST `/api/modes`** owns the **catalogue** — what modes exist, what they're called, what they look like. Stable, cacheable, shared across conversations, fetched before any conversation id is known.
- **`conversation/{id}/state`** owns the **active mode** — what mode this conversation is currently in. Per-conversation, live, fetched as part of subscribing to a specific conversation. The `modeChanged` event already lives here.

UIs combine the two: subscribe to the state topic to know which mode to highlight as active; consult the REST catalogue to render the rest of the picker.

How UIs *trigger* a mode change (the HTTP shape of `manager.update`) is part of the broader Manager HTTP surface and out of scope for this document; the registry endpoint described here is read-only.

---

## Alternatives

### Hard-coded enum (current state in five of six harnesses)

Mode is a string union in the schema; consuming layers `switch` on its value. Simple, no registry, no profile shape.

**When this works:** when you have exactly two modes that will never change (e.g., a research prototype) and no extension story. Most implementations treat mode (where they have one) as ad-hoc flags read by specific code paths.

**Why not as default:** every new mode requires editing every consuming layer. The architecture's goal of a clean three-Pool / inner-ring separation breaks down the moment cross-cutting policy is hard-coded in each layer's switch statements. The registry pattern keeps each layer ignorant of the mode catalogue.

### Per-turn flags only (no long-lived mode)

Drop mode as a conversation property; instead, per-turn `runOptions` carries flags like `tools: "read-only"`, `compaction: "off"`. The user reasserts options on every input.

**When this works:** for harnesses where every turn is a fresh decision (one-shot batch jobs, scheduled tasks, scripted automations). Triggers-driven workflows often look this way.

**Why not as default:** loses the user-meaningful "we're in plan mode now" continuity. UIs can't render an active mode. Sub-agent inheritance has nothing to inherit. Multi-client UIs can't surface "the other client just switched modes." Mode and per-turn options are different lifecycles; collapsing them costs more than it saves.

### Mode as a registered skill

Treat each mode as a skill loaded by the Skills registry; switching modes loads a different skill bundle.

**When this works:** when modes correspond to identity-shaped personas with self-contained prompts (a "tutor mode," a "translator mode") and don't need cross-layer behavior changes. Modes that only affect the system prompt fit this well.

**Why not as default:** modes affect Tool System, Context Engine, Agent Runtime, Model Pool, Sub-Agent Pool — not just the prompt. Skills are good at "more knowledge for the model"; modes are about "different behavior across the harness." Wrong abstraction unless your modes happen to be prompt-only.

### Permission-only modes (single-binary CLI alternative)

A registry of named modes that *only* affect the permission slice — `default` / `plan` / `acceptEdits` / `bypassPermissions` / `dontAsk` / `auto`. Other slices (model selection, compaction, runtime bounds) are not part of the profile.

**When this works:** when permission policy is the dominant axis modes vary along. Permission modes capture nuanced auto-approval patterns without needing the full profile shape.

**Why not as default:** when plan mode also wants a different model query, a different system-prompt directive, and a bounded iteration count, you end up with parallel hard-coded checks elsewhere — `if (mode === 'plan') ...` in the system-prompt assembler, the model selector, the runtime. Generalizing the registry to all five inner-ring slices subsumes the permission-only design without losing it.

The recommendation here is "extend the permission-only pattern to all slices," not "replace it." The permission-only registry is a fine starting point if the harness is small.

---

## Anti-patterns

- **Mode as a hard-coded enum read via `switch` in every consuming layer.** Every new mode requires touching every layer. Generalizes badly. Use a registry of profiles whose slices each layer reads.
- **Per-layer mode-name checks (`if (mode === 'plan') { ... }`) anywhere outside the registry resolution path.** The point of profiles is that layers don't know mode names. If you're string-comparing the mode id outside the Manager's hooks, you're undoing the abstraction.
- **Mid-run mode change applied mid-stream.** Reject during `runStatus: running`, or queue for the next turn. Don't swap the system prompt or tool list while the model is generating. Same family as the prompt-override anti-pattern in the README.
- **Mode emits a synthetic "user message" instead of changing the system prompt.** Inserting `[user]: switching to plan mode now` into the conversation and hoping the model honors it. The model is much more likely to comply with a real system-prompt directive than a turn buried in history.
- **Blob-prepending the system prompt.** Mode dumps a long string in front of whatever the harness already produced. Loses composition with memory, skills, and per-conversation overrides; the dump can contradict or override defaults silently. Use sectioned assembly with a Mode directive section and explicit suppressions.
- **Mode change with no `ModeChangeMessage` in `rawEvents`.** History becomes opaque. Branching from before the change replays under the wrong mode. Auditing "when did this conversation switch to plan?" requires log-scraping. Persist the transition as a real event.
- **Mode hooks doing significant per-turn work.** If `onEnter` injects a memory snapshot the agent will need on every subsequent turn, that's a per-turn concern (Context Engine reading the profile each turn), not a one-shot enter hook. Hooks should only handle out-of-band state changes (filesystem, attachments, external notifications).
- **Sub-agents silently inheriting parent mode.** A chat-mode parent spawning a sub-agent in chat mode (`maxIterations: 1`) makes the sub-agent halt after one turn. The parent's mode doesn't apply to children unless `subAgents.childModeOnSpawn` says it does. The sneaky version is the **fork** path: because a `context: "fork"` sub-agent is a branch, the branch-inherits-mode rule hands it the parent's mode — and full tool/skill allow-list — unless you reassign capability from the child's role *after* the fork. Forking copies context, never capability; default machine-spawned children to least privilege.
- **Persisting profile contents on the conversation record.** Now the profile and the conversation can drift. Persist only the profile id; resolve at use time. If a profile is removed, the conversation falls back to `default` with a warning — better than executing under stale policy.
- **Mode profiles that override `Identity` without restoring `Constraints`.** Replacing the Identity section without re-emitting Constraints (safety rules, scope rules) drops baseline guardrails. `sectionOverrides` should be additive over the harness's mandatory sections; the assembler should refuse to omit Constraints regardless of profile.
- **No model-callable transition tool for plan-style modes.** Forces the user to manually toggle the mode when the agent is "done planning." A model-callable `exit_plan_mode` tool whose only effect is the mode-change sequence keeps the loop self-driving.
- **Serializing the full `ModeProfile` over the wire.** Functions don't serialize; capability predicates often don't either; and exposing the internal shape couples client code to internal refactors. Define a `ModeProfileDTO` as the wire contract and let the internal type evolve independently.
- **HTTP registry endpoint with no change-event hookup.** Profiles can change at runtime (plugin reload, config watcher). A pure GET goes stale silently and the picker UI shows yesterday's modes. Pair the GET with a registry-changed event on the server-wide event channel, or fall back to cache-control headers if clients aren't on the stream.
- **Exposing the catalogue only via per-conversation state.** Forces UIs to open a conversation before they know what modes exist. Pre-conversation surfaces (new-conversation controls, settings pages) need the catalogue without a conversation id. Use REST (or a server-wide WS topic) for the catalogue; reserve per-conversation streams for active-mode state.

---
