# Extensibility

## TL;DR

Extensibility is the **plugin/hook host**: the seam where third-party and operator code attaches behavior to the inner ring without forking it. The single most important decision is the *shape* of a plugin — and the prescriptive answer is a **capability-typed record**, not a base class. A plugin declares only the slots it fills; core composes behavior from what is present.

The prescriptive shape:

1. **Capability-typed plugin record over an ABC.** A plugin is a `register(api)` callback that calls `api.registerX(...)` for each capability it provides — `registerTool`, `registerChannel`, `registerProvider`, `registerSpeechProvider`, `registerCommand`, `registerHook`, `registerHttpRoute`, and ~30 more. No required-method base class. Surfaces vary too wildly for one ABC; an ABC either forces empty stubs or bakes the richest plugin's assumptions into the contract. (Same reasoning as [provider plugins](../../backends/providers/) and [surface plugins](../../surfaces/interface/).)
2. **Manifest-first validation — read metadata before executing code.** A static `plugin.json` declares identity, config schema, auth choices, provider endpoints, channel env vars, UI hints, and capability-ownership *snapshots*. The loader validates config, answers "which plugins matter for this command/provider/channel," and renders `plugins inspect` — all **without booting plugin runtime**. Code entrypoints and install metadata live elsewhere (the code, `package.json`).
3. **Two hook systems, deliberately kept distinct.** *Internal hooks* (`HOOK.md` + `handler.ts`, filesystem-discovered, operator-installed) fire on command and Gateway lifecycle events. *Plugin SDK hooks* (`api.on(event, handler, { priority })`, in-process, registered in code) intercept the agent turn, tool calls, message flow, and sub-agent routing. They have different trust boundaries, different catalogs, and different audiences; collapsing them into one mechanism loses both.
4. **Hook semantics: descending priority, terminal block, decision-vs-observation typing.** Handlers run sequentially in descending `priority`; same-priority preserves registration order. A small set of hooks accept a *decision* (block / cancel / override / `requireApproval`); the rest are observation-only. The decision-vs-observation split is in the type, so a plugin can't accidentally mutate from an observation hook.
5. **Multi-bundle loader that normalizes without importing.** One loader auto-detects native, Codex, Claude, and Cursor bundle layouts and maps each into the *same* registry (skills, commands, hook packs, MCP servers, LSP defaults) **without importing the bundle's runtime code**. Compatibility is a content-mapping problem, not a runtime-emulation problem — the trust boundary stays narrow.
6. **MCP as both client and server.** The harness is an MCP *client* (it launches stdio / connects HTTP servers and exposes their tools to the model through the [Tool System](../../core/tool-system/)) and an MCP *server* (the Gateway exposes endpoints other agents call). Tool catalogs are sorted deterministically before registration so upstream `listTools()` reordering doesn't thrash the prompt-cache tool block.
7. **Packaging, distribution, and trust are the registry's job, not core's.** A skills/plugins registry owns provenance, version pinning, and security review. A bundled scanner runs on installer metadata and skill code at install time; `critical` findings block by default; a `before_install` hook lets a plugin observe or veto. Untrusted skills run sandboxed by default.

The recommended shape treats *registration* (what a plugin provides), *validation* (what the manifest declares before code runs), *interception* (the two hook systems), and *distribution* (registry, scan, trust) as four orthogonal concerns. Conflating any two is where extensibility systems calcify: a base-class plugin model can't express partial capability; a hook system without a decision/observation split can't be reasoned about; a loader that imports bundle code to inspect it can't keep a narrow trust boundary.

Slash commands are broken out as their own page — see [`./slash-commands.md`](./slash-commands.md). The telemetry hook points this page enumerates feed [Observability](../observability/); the capability slots it registers are detailed on [Providers](../../backends/providers/) (model/media slots) and [Interface](../../surfaces/interface/) (channel/surface slots).

---

## How this fits the architecture

Extensibility is **cross-cutting**: it is not a layer in the inner ring, it is the host that lets external code attach *to* every layer in the ring. The [core spine](../../core/README.md) names it as one of two cross-cutting concerns (with [Observability](../observability/)) precisely because it has no single home — a plugin can register a tool (Tool System), a provider (Model Pool), a channel (Interface), a compaction provider (Context Engine), a memory corpus (Memory), or a sub-agent harness (Sub-Agent Pool).

That breadth forces a discipline: **the extension host owns the registration contract and the load lifecycle; each inner-ring layer owns what a registration of its kind *means*.** The host knows how to validate a manifest, resolve a bundle, order hooks, and scan an install. It does *not* know what a "provider" or a "channel" does — it hands the registration to the owning layer. The seam is the typed `api.registerX(...)` method: the host provides it, the layer defines the payload type and consumes it.

### Extension points are not all the same kind

Four distinct kinds of extension point, each with a different contract. The most common design error is treating them uniformly.

| Kind | What it is | Contract | Examples |
|---|---|---|---|
| **Capability slot** | A typed seat the harness selects *one* implementation per agent from | `registerProvider`, `registerChannel`, `registerSpeechProvider`, `registerImageGenerationProvider`, `registerWebSearchProvider`, `registerContextEngine`, `registerCompactionProvider`, `registerAgentHarness`, `registerMemoryRuntime` | one text provider + one image provider + one channel, composed per agent |
| **Additive surface** | A registry the harness aggregates *all* of | `registerTool`, `registerCommand`, `registerHttpRoute`, `registerGatewayMethod`, `registerService`, `registerCli` | every registered tool is available; commands union |
| **Hook** | An interception point on a lifecycle event | `api.on(event, handler, { priority })` / `HOOK.md` | `before_tool_call`, `gateway:startup` |
| **Content pack** | Static assets mapped into core features | bundle layout detection | skills, command markdown, LSP defaults, MCP server config |

The capability-slot-vs-additive-surface distinction is load-bearing. A *slot* is an exclusive choice resolved per agent (you run one image-gen provider at a time); an *additive surface* is a union (every tool a plugin registers is callable). Registering a channel is a slot fill; registering a tool is an additive contribution. A plugin model that can't tell these apart either forces tools to be mutually exclusive or lets two providers fight over the same agent.

### What is an extension point vs. what is core

A standing temptation is to make everything pluggable. The corrective: **a thing is an extension point only if a real second implementation exists or is plausible.** Capability slots earn their seat because the harness genuinely needs OpenAI *and* Anthropic *and* Ollama, Slack *and* Discord *and* WhatsApp. The Agent Runtime loop, the Conversation Manager's lifecycle, and the persistence Protocol are *not* extension points — they are the stable spine plugins attach to. Exposing them as hooks (a `registerConversationManager` slot) buys nothing and turns every core refactor into a breaking-change negotiation with plugin authors.

Reference implementations split cleanly on this. The most extensive exposes ~15 capability slots and ~25 hook events but keeps the runtime loop, the comm-layer wire protocol, and the persistence Protocol as core. The thinnest ships a near-zero plugin host and demonstrates a channel integration as an *external app* (a standalone bot that imports the library) rather than an in-process plugin — a legitimate point on the spectrum for a library-shaped harness, covered under [Alternatives](#library-with-no-plugin-host-integration-as-external-app).

---

## The extension-point catalog

What a plugin can register, grouped by kind. This is the surface the `register(api)` callback exposes; it is the concrete form of the four-kind taxonomy above.

### Capability slots (exclusive, one-per-agent)

```
registerProvider                         text inference (LLM)
registerCliBackend                       local CLI inference backend (codex-cli/gpt-5)
registerChannel                          messaging channel (Slack, Discord, WhatsApp, ...)
registerSpeechProvider                   TTS / STT
registerRealtimeTranscriptionProvider    streaming transcription
registerRealtimeVoiceProvider            duplex realtime voice
registerMediaUnderstandingProvider       image/audio/video analysis
registerImageGenerationProvider          image generation
registerMusicGenerationProvider          music generation
registerVideoGenerationProvider          video generation
registerWebFetchProvider                 fetch / scrape
registerWebSearchProvider                web search
registerContextEngine                    the assembled-context builder
registerCompactionProvider               the compaction strategy
registerAgentHarness                     low-level agent executor (experimental)
registerMemoryRuntime / ...Capability    pluggable memory backend
```

These are the same slots the [Providers](../../backends/providers/#capability-scope-as-parallel-slots) page argues for as *parallel registration slots, not flavors of one provider type*, and the [Interface](../../surfaces/interface/) page argues for on the surface side. Extensibility is where the *registration mechanism* for all of them lives; the owning layer defines each payload.

### Additive surfaces (union, all-registered)

```
registerTool(tool, { optional? })        agent tool — the Tool System dispatch target
registerCommand(def)                     slash command — see ./slash-commands.md
registerHttpRoute(params)                Gateway HTTP endpoint
registerGatewayMethod(name, handler)     Gateway RPC method (scope-gated)
registerGatewayDiscoveryService(svc)     local discovery advertiser (mDNS)
registerCli(registrar, { descriptors })  CLI subcommand (lazy via descriptors)
registerService(service)                 background service (gateway-lifecycle bound)
registerInteractiveHandler(reg)          interactive prompt handler
registerAgentToolResultMiddleware(...)   rewrite tool result before it re-enters the model
registerMemoryPromptSupplement(builder)  additive memory-adjacent prompt section
registerMemoryCorpusSupplement(adapter)  additive memory search/read corpus
```

Two guardrails worth stating as invariants. **Reserved admin namespaces stay admin-scoped.** Gateway methods under `config.*`, `exec.approvals.*`, `wizard.*`, `update.*` resolve to operator-admin scope even if a plugin tries to register a narrower scope; plugin-owned methods use plugin-specific prefixes. **Tool-result middleware is a trusted seam.** Rewriting a tool result *before the runtime feeds it back to the model* is high-privilege (it can inject model-visible context); restrict it to bundled/trusted plugins and require each to declare the runtimes it targets (`["native", "codex"]`). External plugins get ordinary hooks, not this seam.

### Hooks (interception)

Two systems — see [§Two hook systems](#two-hook-systems-kept-distinct). The plugin-SDK catalog, with **bold** = accepts a decision:

```
Agent turn:    before_model_resolve, before_prompt_build, before_agent_start(compat),
               *before_agent_reply, agent_end
Conversation:  model_call_started/ended, llm_input, llm_output
Tools:         *before_tool_call, after_tool_call, *tool_result_persist, *before_message_write
Messages:      *inbound_claim, message_received, *message_sending, message_sent,
               *before_dispatch, *reply_dispatch
Sessions:      session_start/end, before_compaction, after_compaction, before_reset
Subagents:     subagent_spawning, subagent_delivery_target, subagent_spawned, subagent_ended
Lifecycle:     gateway_start, gateway_stop, *before_install
```

The internal `HOOK.md` catalog is smaller and operator-facing: `command:new`, `command:reset`, `command:stop`, `command`, `session:compact:before`, `session:compact:after`, `session:patch`, `agent:bootstrap`, `gateway:startup`, `message:received`, `message:transcribed`, `message:preprocessed`, `message:sent`.

---

## Recommendation

### Capability-typed plugin record, not a base class

A plugin is a `register(api)` callback that calls the typed `api.registerX(...)` methods for the slots it fills. The `api` object is built per-plugin (`buildPluginApi`) with the plugin's identity, config, logger, and a resolved root path; methods the host doesn't wire for this plugin are no-ops, so a plugin only ever sees the surface it's allowed to touch.

Why a record beats an ABC, concretely:

- **Partial capability is the common case.** A weather plugin registers one tool and nothing else. A voice plugin fills three slots (speech + realtime transcription + realtime voice). An `AbstractPlugin` with `connect()` / `send()` / `getTools()` forces the weather plugin to stub two-thirds of the interface and forces the voice plugin's three concerns into one object. The record lets each declare exactly what it provides.
- **Capability evolution is additive.** Adding `registerVideoGenerationProvider` is a new optional method; no existing plugin breaks. Adding a method to an ABC breaks every subclass.
- **Inspection is cheap.** Because registration is a set of typed calls, the host can record *which* slots a plugin touched and classify it (`plain-capability` / `hybrid-capability` / `hook-only` / `non-capability`) for `plugins inspect` — without the plugin implementing a "describe yourself" method.

The single shared output for channels is the instructive counter-pressure: even with capability records, **core owns one shared `message` tool**, and channels register *scoped action discovery* and provider-specific session/thread grammar rather than their own send verb. The record models *what varies* (the channel's capabilities); the *invariant* (there is one way to emit a message) stays in core. This is the same `message` + `renderPresentation` factoring the [Interface](../../surfaces/interface/) page prescribes.

### Manifest-first validation: read metadata before executing code

Every native plugin ships a static manifest (`plugin.json`) in its root. The host reads it **before loading plugin code** to validate configuration, answer activation questions, and render inspection surfaces. What belongs in the manifest:

- plugin identity, config JSON Schema, config UI hints
- auth / onboarding / setup metadata (alias, auto-enable, provider env vars, auth choices)
- activation hints for control-plane surfaces (which command/provider/channel this plugin owns)
- shorthand model-family ownership (`modelSupport.modelPrefixes`)
- static capability-ownership *snapshots* (`contracts`)
- channel-specific config metadata merged into catalog and validation

What does **not** belong: registering runtime behavior, declaring code entrypoints, npm install metadata. Those live in the plugin code and `package.json`.

The payoff is an **activation planner** that answers "which plugins matter for this command / provider / channel" *without booting any plugin's runtime registry*. Startup stays fast (you boot only the plugins a request actually needs), `plugins inspect <id>` stays offline and cheap, and a malformed manifest is a clean, early, code-free failure instead of a crash on first use. Make manifest validation a hard gate: a missing or invalid manifest is a plugin error that blocks config validation for that plugin and nothing else.

This is the exact discipline the [Providers](../../backends/providers/#the-manifest) page prescribes for provider manifests — extensibility generalizes it to every plugin kind.

### Two hook systems, kept distinct

There are two legitimately different interception needs, and the recommendation is to serve them with two mechanisms rather than one over-general one.

**Internal hooks (`HOOK.md`).** Filesystem-discovered, operator-installed, scoped to command and Gateway lifecycle events. Each hook is a directory with a `HOOK.md` (YAML frontmatter: `events`, `requires`, `os`, `export`, `always`) and a `handler.ts`. The `requires` field gates load-time eligibility on `bins`, `anyBins`, `env`, and `config` paths — so a hook that shells out to `ffmpeg` simply doesn't load where `ffmpeg` is absent, rather than failing at runtime. The Gateway loads internal hooks only after the operator enables hooks or configures at least one entry, so the default install pays nothing. This is the right shape for *operator automation*: "when a session compacts, append a note to my log"; "on `/reset`, archive the transcript." It's scriptable, inspectable (`hooks list` / `hooks check` / `hooks info`), and doesn't require writing a plugin.

**Plugin SDK hooks (`api.on`).** In-process, registered in code with an explicit priority. This is the right shape for *behavioral extension*: rewriting tool params, injecting prompt context, claiming an inbound message, requiring approval. It sees structured, typed events and can return decisions.

Why not unify them: they differ on **trust boundary** (a `HOOK.md` handler is operator-installed local code; a plugin hook ships inside a distributed plugin and runs under that plugin's permission grants), on **discovery** (filesystem vs. code registration), and on **audience** (operators automating their box vs. integrators extending behavior). A single mechanism would either over-privilege the operator script or under-serve the plugin. Document them as two things; let `hooks list` show both standalone and plugin-managed hooks so the operator has one view.

### Hook semantics: priority, terminal block, decision vs. observation

The execution contract for plugin-SDK hooks, which a correct host must enforce:

- **Descending priority, registration-order tiebreak.** Handlers run sequentially from highest priority to lowest. Same-priority handlers run in registration order. Deterministic ordering is non-negotiable — non-deterministic hook order makes plugin interactions impossible to debug.
- **Decision vs. observation is typed.** Only a named subset of hooks (`before_agent_reply`, `before_tool_call`, `tool_result_persist`, `before_message_write`, `inbound_claim`, `message_sending`, `before_dispatch`, `reply_dispatch`, `before_install`) may return a decision. The rest are observation-only and their return value is ignored. Put this in the type so an observation hook *cannot* express a mutation.
- **`block: true` is terminal; `block: false` is not a decision.** A blocking return short-circuits lower-priority handlers. An explicit `false` means "no opinion," not "force-allow" — so a higher-priority abstain doesn't silently override a lower-priority block.
- **Approval is a structured return, not a side effect.** `before_tool_call` returns `requireApproval: { title, description, severity, timeoutMs, timeoutBehavior, pluginId, onResolution }`. The runtime pauses the turn, delivers the approval through the surface (native cards on Slack/Discord/Teams; `/approve` as the universal fallback), and calls `onResolution(decision)` with `allow-once | allow-always | deny | timeout | cancelled`. A lower-priority `block: true` can still block *after* a higher-priority hook asked for approval — block beats approve. This is the same approval machinery the [Interface](../../surfaces/interface/) page describes from the *delivery* side; classification (what *needs* approval) lives in the [Tool System](../../core/tool-system/).
- **Conversation-content access is gated.** Hooks that see prompts/history/responses (`llm_input`, `llm_output`, `agent_end`) require explicit per-plugin opt-in (`hooks.allowConversationAccess`), and prompt-mutating hooks can be disabled per plugin (`hooks.allowPromptInjection: false`). Telemetry-only hooks (`model_call_started/ended`) deliberately receive *sanitized* metadata — timing, outcome, provider/model, a bounded request-id hash — and never raw prompt or response content. This is the seam [Observability](../observability/) attaches to without taking on a PII-redaction burden at every call site.

### Multi-bundle loader: normalize without importing

A single loader auto-detects bundle layouts and maps each into the same internal registry:

- **native** (`plugin.json`) — full in-process plugin, any capability
- **Codex** (`.codex-plugin/plugin.json`)
- **Claude** (`.claude-plugin/plugin.json`, or the default Claude component layout with no manifest)
- **Cursor** (`.cursor-plugin/plugin.json`)

The hard rule: **map content, do not import runtime code.** Bundles are content/metadata packs with a *narrower trust boundary* than native plugins — they contribute skills, command markdown, hook packs (`HOOK.md` + `handler.ts`), MCP server config, and LSP/settings defaults, but they don't run arbitrary in-process registration code. So the loader reads declared skill roots, command roots, hook-pack roots, and MCP entries and normalizes them through the *same* paths a native plugin would use (Claude `commands/` and Cursor `.cursor/commands/` load as skill roots; Codex hook packs load through the normal `HOOK.md` loader; bundle MCP servers merge into the embedded agent's `mcpServers`). Detection surfaces in `plugins inspect` as `Format: bundle` with a `codex` / `claude` / `cursor` subtype.

Two reasons this is the right factoring. First, it lets the harness *consume the existing ecosystem* — a Claude command pack or Codex skill bundle installs and works without its author rewriting it as a native plugin. Second, the import-free boundary is what keeps "install a third-party bundle" from meaning "execute a third-party author's registration code in my process": a bundle can only reach the features the mapper explicitly wires, so the blast radius of a malicious or buggy bundle is bounded by the mapping, not by the host's full API.

### MCP as both client and server

Treat MCP as a first-class, bidirectional integration, not a tool sub-feature.

- **Client.** The harness launches stdio MCP servers (child process) or connects to HTTP MCP servers, lists their tools, and exposes them through the [Tool System](../../core/tool-system/) as ordinary dispatch targets — subject to the same approval and denylist machinery as native tools (`tools.deny: ["bundle-mcp"]` opts an agent out). Capability changes mid-session are reloadable as deltas. **Sort the tool catalog deterministically before registration** so an upstream server reordering its `listTools()` response doesn't invalidate the prompt-cache tool block — a real, easy-to-miss cache-thrash bug.
- **Server.** The Gateway exposes MCP server endpoints so other agents/clients can call into this harness. Plugins advertise their own MCP servers via bundle metadata.

One scoping decision worth making explicitly: **reject session-level MCP configuration on the external bridge (ACP).** Configure MCP on the Gateway/agent, not per inbound session — session-scoped server spawning from untrusted callers is a process-spawn attack surface with no upside.

### Slash commands

Commands are an additive surface with enough design surface to warrant their own page: see [`./slash-commands.md`](./slash-commands.md). The short version it expands: a unified `Command` record with a typed `dispatch` discriminator (`local` | `prompt` | `tool` | `ui-modal`), a structured `args` schema with per-command `formatArgs` round-trip, explicit `loadedFrom` provenance, a `scope: text | native | both` surface gate, a `tier` for progressive disclosure, and an `assertCommandRegistry` startup invariant check.

### Packaging, distribution, and trust live in the registry

Distribution is a registry concern, and the recommendation is to keep it *out of core* — core defines the install lifecycle and the scan hook; the registry owns provenance and review.

- **A skills/plugins registry** is the public distribution channel, with provenance and security review explicitly assigned to it. `<harness> skills install <slug>` for workspace install; `<harness> publish --all` for the publish workflow; a marketplace for discovery (Claude-marketplace bundles install as `<plugin>@<marketplace>`).
- **Version pinning by content identity.** Pin installed plugins to a git commit SHA (or content hash), not a floating tag, so an install is reproducible and an upstream force-push can't silently change installed behavior.
- **Install-time scanning, with a veto hook.** A bundled scanner runs on installer metadata *and* skill code at install time. `critical` findings block by default. The `before_install` plugin hook lets a plugin observe the scan result and block — so an organization can ship a policy plugin that vetoes installs failing its rules.
- **Sandbox untrusted code by default.** Untrusted skills run in the [execution sandbox](../../backends/execution-environments/) by default; trust is opt-in, not opt-out. A dependency denylist and an install ledger (what was installed, from where, at what SHA, scanned with what result) give the audit trail.

### Agent-written skills with quarantine

The most forward-leaning extension point, and the cleanest answer to the "memory → skill promotion" question flagged as undrafted on the [Memory](../../core/memory/) page: an optional plugin (a "skill workshop") lets the agent *propose* new workspace skills based on observed procedures ("next time, verify GIF attribution before posting"). The discipline that makes it safe:

- **Pending-approval by default.** The agent proposes; a human approves before the skill becomes active. Auto-write only in explicitly trusted workspaces.
- **The dangerous-code scanner quarantines unsafe proposals** before they can run — the same scanner the install path uses.
- **Hot refresh without restart.** Approving a proposed skill refreshes the skill snapshot in place; no Gateway bounce.

This closes the loop between [Memory](../../core/memory/) (the agent notices a recurring procedure) and extensibility (it becomes a reusable, reviewed skill) without letting the agent write executable extensions to itself unsupervised.

---

## Alternatives

### Git-marketplace plugins with settings-configured hooks (the reference-implementation shape)

One single-binary developer CLI's model: plugins are git repositories registered through a marketplace; a loaded-plugin record carries a manifest plus typed component paths (`commands`, `agents`, `skills`, `hooks`, `output-styles`), MCP servers, and LSP servers. Version pinning is by commit SHA. Built-in plugins ship in-binary (`{name}@builtin`) and toggle from a `/plugin` UI. Crucially, **hooks are configured through a `settings.json` block**, not registered via an in-process `api.on` — a hook is a declarative `{ matcher, command }` entry that shells out, with a structured JSON stdout protocol (`continue`, `suppressOutput`, `stopReason`, permission updates, prompt-elicitation).

**When this works:** when the harness is a single-user developer CLI and the distribution story is "point at a git repo." Git-as-distribution gives version pinning, provenance, and rollback for free; settings-configured shell hooks are dead simple to author and need no SDK. The component-path model (`commands/`, `agents/`, `skills/`) maps cleanly to a filesystem and is exactly what the multi-bundle loader above *consumes* as the Claude bundle format.

**Why not as the default for a multi-surface harness:** declarative shell hooks can't hold in-process state, can't return a structured `requireApproval` with an `onResolution` callback, and pay a process-spawn per event — fine at CLI cadence, costly on a Gateway fielding channel inbounds. And the plugin model is component-typed (here are my commands/agents/skills) rather than capability-typed (here is the image-gen provider I fill), so it has no natural seat for the provider/channel/speech slots a messaging harness needs. The capability-record model is the generalization; the component-path model is the subset that a filesystem bundle expresses.

### Middleware-first composition (graph-executor framework)

A framework-coupled harness composes behavior as an ordered stack of framework middlewares (a configurable-model middleware, a subagent middleware, a profile middleware) rather than a plugin host with capability slots. Extension = add a middleware to the stack.

**When this works:** when the harness has already committed to a graph-executor framework as its runtime. Middleware ordering is a genuinely good interception model — it's the same descending-priority chain the hook system above formalizes — and for cross-cutting concerns (caching, retries, prompt shaping) it's clean.

**Why not as the default:** middleware is an *interception* primitive, not a *registration* primitive. It has no manifest, no capability-slot typing, no install/trust lifecycle, no multi-bundle compatibility. You can express "rewrite every model call" beautifully and "install a third-party Slack channel with its own config schema and auth" not at all. The piece worth borrowing is the ordered-middleware chain as the shape of the hook pipeline; the piece to leave is making it the *only* extension mechanism.

### One ABC per capability (the messaging-gateway shape)

The shape several harnesses reach for first: a `BasePlatformAdapter(ABC)` (or `BaseProvider`, `BaseChannel`) with required methods (`connect` / `disconnect` / `send` / `send_typing` / `get_chat_info`) and optional default-stubbed media methods, subclassed per platform.

**When this works:** when the set of implementations is *fixed and shipped by the harness itself* and they genuinely share a method surface — 20 messaging platforms that all really do `connect`/`send`. The base class then carries shared retry / keepalive / reconnection / length-cap logic for free, which is real leverage.

**Why not as the default:** an ABC bakes the richest implementation's method set into the contract and forces empty stubs everywhere else, and it has no story for *third-party* registration (you can't subclass a shipped ABC from an installed plugin without the harness importing your code). It also conflates the *delivery verb* into the interface (`send` is a required method) instead of exposing one shared output tool with portable presentation. Capability records subsume it: the shared retry/keepalive logic moves into core helpers the channel record calls, and the per-platform variation stays in the record. (Same trade the [Interface](../../surfaces/interface/) and [Providers](../../backends/providers/) pages make.)

### Library with no plugin host (integration as external app)

A library-shaped harness ships essentially no plugin host; an integration like a Slack bot is a *separate application* that imports the library, rather than an in-process plugin the harness loads.

**When this works:** when the harness is deliberately a *library*, not a platform — the smallest, most embeddable thing that "talks to a model and runs a loop," which other code composes. There's nothing to install because there's no host; you write a program. This is a coherent and defensible scope (it's the same scope choice the [Providers](../../backends/providers/) page notes for a wire-codec library).

**Why not as the default for a harness with surfaces:** the moment you want operators (not programmers) to add a channel, install a skill, or toggle a provider without writing and deploying an app, you need a host: a manifest format, a loader, a registry, a config UI. The external-app model pushes all of that onto every integrator. Ship the host once the audience includes non-developers.

---

## Anti-patterns

- **Plugin as an ABC with required methods.** Forces empty stubs on simple plugins and bakes the richest plugin's surface into the contract; has no seat for partial capability and no third-party registration story. Use a capability-typed record where a plugin declares only the slots it fills. (Cross-reference: the same anti-pattern on [Providers](../../backends/providers/#anti-patterns) and [Interface](../../surfaces/interface/).)

- **Capability slots and additive surfaces conflated.** Treating "register a channel" (exclusive, one-per-agent) and "register a tool" (additive union) as the same kind of registration leads to either tools that fight for exclusivity or providers that stack when only one should win. Type the two kinds distinctly.

- **Executing plugin code to read its metadata.** If you must `import()` a plugin to find out what it provides, startup is slow, `inspect` isn't offline, a buggy plugin crashes config validation, and "which plugins matter for this request" can't be answered without booting all of them. Put identity, config schema, auth, and capability snapshots in a static manifest validated before any code loads.

- **One over-general hook mechanism for operators and integrators.** Operator automation (`HOOK.md` shelling out on `/reset`) and behavioral extension (an in-process plugin requiring tool approval) have different trust boundaries, discovery, and audiences. A single mechanism over-privileges one and under-serves the other. Keep the two systems distinct; show both in one `hooks list`.

- **Non-deterministic hook ordering.** Without a defined priority order and a stable same-priority tiebreak, plugin interactions are unreproducible and undebuggable. Descending priority, registration-order tiebreak, documented.

- **Observation hooks that can mutate.** If every hook can return a mutation, you can't reason about which hooks change state. Make decision-capability part of the hook's *type*; observation hooks' return values are ignored.

- **`block: false` treated as force-allow.** An explicit "no opinion" must not override another handler's block. Only `block: true` is terminal; `false` is abstain. Otherwise a high-priority telemetry hook silently defeats a low-priority security block.

- **Importing bundle runtime code to support compatibility.** Emulating another ecosystem's plugin runtime in-process makes every foreign bundle a full-trust code execution. Map *content* (skills, commands, hook packs, MCP config) into the native registry without importing the bundle's code; keep the trust boundary narrow and the blast radius bounded by the mapping.

- **Letting upstream MCP `listTools()` order reach the prompt unsorted.** Servers reorder tools across restarts; an unsorted catalog thrashes the prompt-cache tool block and quietly inflates cost. Sort deterministically before registration.

- **Session-scoped MCP spawning from untrusted callers.** Per-inbound-session server configuration on the external bridge is a process-spawn attack surface. Configure MCP on the Gateway/agent; reject it at the session boundary.

- **Distribution, signing, and review baked into core.** Provenance, version pinning, and security review belong to the registry, with core providing only the install lifecycle and a `before_install` veto hook. Baking the trust model into core couples every policy change to a core release.

- **Floating version tags for installed plugins.** Pinning to a mutable tag means an upstream force-push silently changes installed behavior. Pin to a commit SHA or content hash; record it in an install ledger.

- **Trusting installed skills by default.** Untrusted third-party skill code should run sandboxed unless explicitly trusted; `critical` scanner findings should block by default. Opt-in trust, not opt-out.

- **Agent-written extensions with no quarantine.** Letting the agent write executable skills to itself with no scan and no approval gate is a self-modifying-code footgun. Pending-approval by default, scanner quarantine for unsafe proposals, hot-refresh on approval.

- **Reserved admin namespaces reassignable by plugins.** If a plugin can register a `config.*` or `exec.approvals.*` gateway method at a narrower scope, it can escalate. Pin reserved namespaces to operator-admin scope regardless of what the plugin requests; require plugin-specific prefixes for plugin-owned methods.

---
