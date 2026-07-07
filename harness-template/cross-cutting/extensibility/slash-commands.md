# Slash Commands — Recommended Architecture

## TL;DR

Define every slash command as a single shared `Command` record with a typed `dispatch` discriminator (`local` | `prompt` | `tool` | `ui-modal`), a structured `args` schema (positional with optional `captureRemaining`, per-command `formatArgs` for `key:value` round-trip), an explicit `loadedFrom` provenance enum, a `scope: text | native | both` surface gate, and a `tier: essential | standard | power` for progressive disclosure. Build the registry by merging six well-ordered sources (bundled → built-in plugin → workspace file → workflow → user plugin → user skill), failing loud at startup on any duplicate via an `assertCommandRegistry` invariant check. Parse `/cmd args` and `/cmd: args` colon form, strip `@botname` mentions at the adapter boundary, resolve aliases to canonical, dispatch by mode. Run completion, validation, and dispatch from one place; render the same canonical text command from every surface so Discord native UIs, Slack slash registrations, Telegram bots, and TUI text input all converge through the same executor.


## Why this belongs in the harness

Slash commands are the canonical user→harness control plane. They turn a chat composer into a CLI without leaving the conversation, which means they have to be present on every surface the harness ships — terminal, web, mobile, Slack, Discord, Telegram, email-with-prefix, anywhere users type. Five of the six reference harnesses ship between 20 and 80 built-in commands; the sixth ships 40 plus a typed plugin-contribution API. None of them treat slash commands as optional.

The reason a harness needs a *standard implementation* — and the reason this page exists — is that slash commands sit at the intersection of five layers and reach into a sixth:

- **Surfaces** parse them out of user input.
- **Conversation Manager** sees them in the message log (and may need to redact sensitive args from the transcript).
- **Agent Runtime** may end up submitting their output as a user turn.
- **Tool System** may end up dispatching them as deterministic tool calls.
- **Memory / Context Engine** sees their effects when skills with `paths:` globs become visible mid-conversation.
- **Extensibility** is where the registry, the plugin contribution path, and the hook seams live.

Without a unified shape, every surface re-invents parsing (one harness does this in three places, in two languages), every command re-invents arg tokenisation (one implementation has ~240 lines of nested `tokens[0]` switching), every plugin author has to learn a different contribution shape, and conflicts manifest as silent collisions (some implementations filter extension commands silently when they collide with built-ins; the extension author gets no warning their command is hidden).

The synthesis below is what falls out when you take each harness's best decision on each axis and put them together.

---

## Layer placement

The slash-command system lives in **Extensibility** (cross-cutting) as the registry owner and plugin-contribution host. It exposes itself to other layers through three contracts:

- **To Surfaces** — `parseSlashCommand(text): ParsedCommand | null` and `getCommands(): Command[]`. Surfaces use these for parsing and autocomplete. Surfaces own the inbound transport (TUI input, Slack event, Discord interaction).
- **To Agent Runtime** — `executeCommand(parsed, ctx): Promise<CommandResult>`. The Runtime calls this when the message it's about to process is a slash command. The `CommandResult` it gets back tells it whether to: render text locally, expand into the user turn and proceed, dispatch a tool and wait, render a modal and pause, or skip the turn entirely.
- **To Conversation Manager** — slash commands flow into the message log like any other user input, but with `isSensitive` redaction applied to args when declared. Sub-agent commands (`context: 'fork'`) spawn nested conversations through the Conversation Manager.

The registry itself is a process-singleton built once at startup and refreshable via hot reload (`/reload-plugins`, `/reload`). Resolution (text → `Command`) and dispatch (`Command` → effect) are the same code path on every surface — a shared module, not a per-surface re-implementation. The shared module pattern defines what "shared" means.

---

## Recommendation

### The `Command` record

The single shared shape. 

```ts
type Command = CommandBase & (LocalCommand | PromptCommand | ToolCommand | UiModalCommand)

type CommandBase = {
  // Identity
  key: string                          // canonical identifier, unique across the registry
  name: string                         // user-typed name (no slash); usually === key
  aliases: string[]                    // alternative names; all resolve to this key
  description: string                  // one-line help text; appears in autocomplete
  whenToUse?: string                   // long-form usage scenarios (skill-style)
  argumentHint?: string                // gray placeholder shown after command in autocomplete

  // Args
  acceptsArgs: boolean                 // defaults to args.length > 0
  args?: CommandArgDefinition[]        // structured schema; see below
  argsParsing?: 'none' | 'positional'  // defaults to 'positional' when args present
  formatArgs?: (values: CommandArgValues) => string | undefined
                                        // round-trip serialiser for native-UI fills

  // Provenance & gating
  loadedFrom: 'bundled' | 'builtin-plugin' | 'workspace-skill' | 'workflow'
            | 'user-plugin' | 'user-skill' | 'mcp'
  scope: 'text' | 'native' | 'both'    // surface visibility
  tier: 'essential' | 'standard' | 'power'  // progressive disclosure
  category?: CommandCategory           // session | options | status | management | tools | media

  // Behavior
  bypassTier: 'always' | 'connecting' | 'immediate-ui' | 'side-effect-free' | 'queued'
  isSensitive?: boolean                // redact args from the transcript
  isHidden?: boolean                   // suppress from autocomplete entirely (debug only)
  userInvocable?: boolean              // skill-only: surfaceable as a slash command
  disableModelInvocation?: boolean     // hide from the SkillTool index
  availability?: ('auth' | 'paid' | 'admin' | ...)[]
                                        // required env to even show this command
  isEnabled?: () => boolean            // runtime gate (feature flag, platform check)
  hooks?: HooksSettings                // hooks to register only during this command's run
}

type LocalCommand = {
  dispatch: 'local'
  handler: (args: string, ctx: CommandContext) => Promise<LocalCommandResult>
}

type PromptCommand = {
  dispatch: 'prompt'
  context?: 'inline' | 'fork'          // expand into current turn vs spawn sub-agent
  agent?: string                       // sub-agent type when fork
  model?: string                       // optionally pin model
  allowedTools?: string[]              // restrict tool surface for this run
  effort?: EffortValue
  getPrompt: (args: string, ctx: CommandContext) => Promise<ContentBlockParam[]>
}

type ToolCommand = {
  dispatch: 'tool'
  toolName: string                     // dispatched directly via the Tool System
  argMode: 'raw'                       // forwarded as { command, commandName, args... }
}

type UiModalCommand = {
  dispatch: 'ui-modal'
  render: (onDone: ModalOnDone, ctx: CommandContext, args: string)
        => Promise<React.ReactNode | NativeWidget>
}

type ModalOnDone = (
  result?: string,
  options?: {
    display?: 'skip' | 'system' | 'user'   // how to show the result
    shouldQuery?: boolean                   // submit a turn after the modal closes
    metaMessages?: string[]                 // hidden-but-model-visible
    nextInput?: string                      // preload composer
    submitNextInput?: boolean
  },
) => void
```

The `CommandArgDefinition` schema:

```ts
type CommandArgDefinition = {
  name: string
  description: string
  type: 'string' | 'number' | 'boolean'
  required?: boolean
  choices?: CommandArgChoice[] | CommandArgChoicesProvider
  preferAutocomplete?: boolean         // hint for the UI: open a picker rather than typing
  captureRemaining?: boolean           // last arg slurps the rest of the line
}
```

`captureRemaining: true` on the final arg is the cheap escape hatch for "the rest is freeform text" cases like `/compact [instructions]` or `/btw <question>`. Without it, structured-args would be unusable for commands that take prose.

### Dispatch modes

The four modes cover everything the six harnesses do. They're declared up front on the `Command` — *not* inferred from what the handler returns.

| Mode        | What it does                                                        | When to use                                                                                          | Source                                                                              |
|-------------|---------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| `local`     | Runs synchronously in-process; result rendered into transcript      | Stateful UI commands (`/clear`, `/help`, `/usage`, `/cost`, `/status`)                                |                                                                                     |
| `prompt`    | Expands args into a user turn; optional `context: 'fork'` runs as sub-agent | User-authored skill commands; anything where the model should see the expanded text and proceed         |                                                                                     |
| `tool`      | Bypasses the model; dispatches a named tool with raw args           | Deterministic actions you want to behave the same way every time (`/queue`, `/model`, `/permissions`) |
| `ui-modal`  | Renders a UI; the modal's `onDone` callback controls follow-up      | Multi-step selection flows (`/theme`, `/model`-as-picker, `/permissions`)                            |                                                                                     |

Why typing the mode statically matters: The `should_bypass_active_session` function documents an entire bug class — silent message discards, four PR numbers in the docstring — that exists because the queue plumbing didn't know slash commands had different dispatch semantics. Typed up front, that class of bug is structurally impossible.

The `prompt` mode's `context: 'fork'` option lets a slash command run as a sub-agent with a separate token budget. Useful for `/review`, `/audit`, `/research-topic` — long-running analyses you don't want to bloat the main conversation context. This pattern is worth using for long-running analyses you don't want to bloat the main conversation context.

### Parser & argument grammar

One parser, one grammar, every surface. The output type is small and total:

```ts
type ParsedCommand = {
  command: Command          // resolved against the registry
  args: string              // raw remainder
  values?: CommandArgValues // structured arg values when args schema present
}

function parseSlashCommand(text: string, registry: CommandRegistry): ParsedCommand | null
```

The parser does five things, in order:

1. **Trim and verify the leading slash.** If the input doesn't start with `/`, return `null`.
2. **Extract the command name.** Split on the first whitespace *or* colon character. The colon form (`/cmd: args`) it's marginally easier to type on mobile and idiomatic in some chat clients. Strip `@botname` suffix at adapter boundaries (Telegram/Discord) — *not* in the core parser, because the adapter knows whether `@botname` is meaningful.
3. **Resolve the name to a canonical key.** Lowercase, look up in the alias→key map, return `null` if no match. Aliases live in the same map as canonical names (O(1) lookup); a separate `canonicalKeys` list keeps `/help` from listing the same command twice.
4. **Parse args.** If the command has `argsParsing: 'none'` or no schema, pass `args` as a single string. Otherwise tokenize:
   - Positional args consume tokens left-to-right until exhausted or `captureRemaining: true`.
   - `key:value` and `key=value` tokens are recognised by the per-command `formatArgs` callback's inverse (the harness should pick one convention and stick to it).
   - Quoted strings (`"`, `'`) are honored for tokens with spaces.
   - `boolean`-typed args accept `true`/`false`/`yes`/`no`/bare presence (`--verbose` style is *not* recommended — it pollutes the grammar; prefer `verbose:true`).
   - `number`-typed args parse with `parseFloat` and error on NaN.
   - `choices`-constrained args validate at parse time and surface a "did you mean..." suggestion on miss.
5. **Reject if `acceptsArgs: false` but args supplied** . Better to error than silently ignore.

The parser is deliberately small. Heavy lifting (skill expansion, MCP routing, choice resolution) happens at dispatch time, not parse time.

### Validator & startup invariants

Two layers: startup-time invariants (catch the bad data the moment the registry is built) and runtime gates (per-dispatch checks against current state).

**Startup invariants** — call `assertCommandRegistry(commands)` after all sources have been merged:

- No duplicate `key`.
- No duplicate `nativeName` across the registry.
- No duplicate text alias across the registry.
- All text aliases must start with `/`.
- `scope: 'text'` requires no `nativeName`.
- `scope: 'native' | 'both'` requires a `nativeName`.
- `scope: 'native'` rejects text aliases.
- Every `tier: 'essential'` command must have a one-line description ≤ 80 chars (autocomplete-friendly).
- Every command must have either `description` *or* `whenToUse` populated.

Fail loud at startup. The cost of letting a duplicate slip in is silent collision — the last-loaded wins, the earlier-loaded vanishes, the user has no way to know.

**Runtime gates** — checked at dispatch time:

- `availability` — current auth/provider environment satisfies the requirement.
- `isEnabled()` — feature flag or platform check returns true.
- `scope` matches the current surface (a `text`-only command can't be dispatched from a Discord native interaction).
- Trust class (see [`../../surfaces/triggers/triggers.md`](../../surfaces/triggers/triggers.md)) permits this command from this source.
- Remote bridge / channel-side permission check — the bridge-safety predicate gates surface-restricted commands from being forwarded over untrusted channels.
- Plugin permission gate via `before_tool_call`-style hook (see [`./README.md`](./README.md) for the hook taxonomy).

### Bypass tiers — queue interaction

Every command declares one of five tiers:

| Tier               | Semantics                                                                                       | Examples                                                              |
|--------------------|-------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| `always`           | Execute regardless of any busy state, including mid-thread-switch                               | `/quit`, `/cancel`                                                    |
| `connecting`       | Bypass only during initial server connection, not during agent/shell                            | `/version`, `/status` (the cheap variant)                             |
| `immediate-ui`     | Open modal UI immediately; real work deferred via an `_defer_action` callback                   | `/model`, `/theme`, `/agents`, `/permissions`                         |
| `side-effect-free` | Execute the side effect immediately; defer chat output until idle                               | `/mcp` (list), `/trace`, `/changelog`, `/feedback`, `/docs`           |
| `queued`           | Must wait in the queue when the app is busy                                                     | `/clear`, `/help`, `/remember`, `/compact`                            |

Then derive the frozensets — declare-once, derive-everywhere (`command_registry.py:209-239`):

```ts
const ALWAYS_IMMEDIATE = buildBypassSet('always')
const BYPASS_WHEN_CONNECTING = buildBypassSet('connecting')
const IMMEDIATE_UI = buildBypassSet('immediate-ui')
const SIDE_EFFECT_FREE = buildBypassSet('side-effect-free')
const QUEUE_BOUND = buildBypassSet('queued')
const ALL_CLASSIFIED = union of all of the above  // drift test
```

The drift test (a `for cmd in commands: assert cmd.key in ALL_CLASSIFIED`) catches the case where someone adds a command without classifying it. Without this, you get the unclassified-command bug class described below.

### Sources & load order

Six sources, merged in this order, last-wins on key collision *only after* `assertCommandRegistry` has run and rejected duplicates:

1. **`bundled`** — hard-coded built-ins shipped in the harness binary.
2. **`builtin-plugin`** — built-in plugins that contribute commands (the host's own opinionated extensions, e.g. first-party MCPs).
3. **`workspace-skill`** — skill markdown files discovered under `<cwd>/.claude/skills/`, `<cwd>/.<harness>/skills/`, etc. Use `user-invocable: true` in frontmatter to opt a skill into being a slash command.
4. **`workflow`** — workflow scripts under `<cwd>/.workflows/` or similar.
5. **`user-plugin`** — third-party plugins installed via the plugin registry. Plugin manifest declares its commands via `registerCommand` (capability-typed registration, see [`./README.md`](./README.md)).
6. **`user-skill`** — user-installed skills from `~/.claude/skills/`, `~/.<harness>/skills/`, etc.

Add **`mcp`** as a seventh, lower-priority source for MCP servers that advertise prompts as slash commands; identify them with a `(MCP)` annotation in the description, *not* a literal `(MCP)` token in the name (see anti-patterns).

The load order is "host knows best, user can override" — but `assertCommandRegistry` ensures user overrides have to be explicit, never silent. If a user-skill collides with a bundled command, the load fails at startup with a clear error pointing at both sources. Resolution: rename the skill or use numeric-suffix dedup.

Re-apply `availability` and `isEnabled()` on every `getCommands()` call, not just at load time. Auth state changes mid-session (`/login`) and the autocomplete should reflect it immediately.

### Conflict policy & namespacing

Three-strikes approach:

1. **Same harness, same source bucket** — startup error (`assertCommandRegistry`).
2. **Different source buckets** — startup error; the loader must rename or refuse. Fail at startup with a clear error; silent overrides are a footgun. Silent overrides are a footgun.
3. **Skills colliding with their own peers** — numeric-suffix dedup (`/foo`, `/foo_2`, `/foo_3`, …). Reasonable because skill authors don't always know what other skills are installed; this gives them a deterministic recovery.

For plugin authors who explicitly want to namespace their commands (`/mypl:foo`, `/mypl:bar`), the colon form is supported by the parser. Plugins can optionally set `userFacingName(): string` to strip the namespace prefix in the UI when there's no collision risk.

### Completion & discovery

The autocomplete provider reads the registry index — names + aliases + descriptions + `tier` + `category` + `loadedFrom` — and renders entries with provenance annotation. Descriptions should get a trailing `(plugin)`, `(bundled)`, `(workflow)`, `(MCP)` so users see where each command came from.

Use progressive disclosure via a tier system:

- `essential` always visible — ~10 core commands.
- `standard` visible on expand or when the filter narrows to <10 results.
- `power` only surfaces via search or with `--all` toggle.

Per-arg completions hang off the command:

```ts
type RegisteredCommand = {
  // ... other fields
  getArgumentCompletions?: (argumentPrefix: string)
    => AutocompleteItem[] | null | Promise<AutocompleteItem[] | null>
}
```

For args with declared `choices`, the registry generates the completion list automatically — the per-command callback is only needed for dynamic completions (model lists, file paths, theme names).

Built-in `@`-prefix completions are a separate concern from slash-command completion and live in the surface layer's input handler.

### Surface variants & native-UI registration

A single shared registry, per-surface adapters. Three concepts:

- **`scope: 'text' | 'native' | 'both'`** on the `Command` controls visibility per surface kind.
- **Per-surface name sanitisation** at the adapter level (Telegram regex, Discord 25×25 packing, Slack reserved-name handling).
- **Native UI builds a canonical text command and routes through the shared executor.** Discord's native form with `command-arg-mode: raw` should produce `/think high` and dispatch it through the same path as a typed `/think high` in the TUI.

Per-channel handling rules:

| Channel    | Native registration   | Constraints                                                                                                  | Reference                                                  |
|------------|----------------------|--------------------------------------------------------------------------------------------------------------|------------------------------------------------------------|
| Discord    | Carbon SDK           | 25 top-level commands × 25 subcommands; per-guild registration                                               |
| Telegram   | BotFather API        | name regex `[a-z0-9_]{1,32}`; sanitize hyphens to underscores; clamp length                                  |
| Slack      | per-command app reg  | reserved names (`/status`, `/help`, etc.) — register under a prefix and accept the reserved text alias too   |

Native commands run in isolated sessions identified by a per-surface session key prefix (`agent:<id>:discord:slash:<user>`, `agent:<id>:slack:slash:<user>`, `telegram:slash:<user>`) — see [`../../surfaces/triggers/triggers.md`](../../surfaces/triggers/triggers.md) for the session-key prefix discipline.

### Hook seams

Three hook points for plugins to intercept commands (anchored in [`./README.md`](./README.md) hook taxonomy):

- **`before_command_dispatch(command, args, ctx)`** — called after parse, before dispatch. Plugins can reject (with structured `requireApproval` for sensitive commands), rewrite args, or short-circuit with a result.
- **`after_command_dispatch(command, result, ctx)`** — called after the command's effect. Plugins can mutate the displayed result, append telemetry, trigger follow-ups.
- **`register_command(cmd)`** — plugin's contribution channel; called at startup by the loader. The plugin returns one or more `Command` records to be merged in at the `user-plugin` source layer.

A plugin can also register a tool that becomes the target of a `dispatch: 'tool'` slash command , bridging the slash registry and the tool registry without either layer knowing about the other.

Skill-contributed `hooks?: HooksSettings` on a `PromptCommand` are registered only for the duration of the command's run — useful for skills that need to install a temporary `pre-tool-call` gate while they execute.

### Hot reload

`reloadCommands()` is a single function the harness exposes:

- Clears the memoized loader cache.
- Re-discovers workspace skills, workflows, plugins (incremental: only re-read directories whose mtime has changed).
- Re-runs `assertCommandRegistry`.
- Notifies the Communication Layer (`commands/registry` topic) so subscribed surfaces refresh their autocomplete index.

User-facing slash commands that trigger this: `/reload-plugins`, `/reload`, plugin-specific reload commands. Plugin registrations done via `api.registerCommand(...)` at runtime are live without a restart.

### Lifecycle / side effects — the result shape

The `CommandResult` shape every dispatcher returns. The recommended shape:

```ts
type CommandResult = {
  // The content shown in the transcript
  content?: string
  contentDisplay?: 'skip' | 'system' | 'user'    // hidden | system message | user message (default)

  // Effects on the run
  action?: 'refresh' | 'export' | 'new-session' | 'reset' | 'stop'
        | 'clear' | 'toggle-focus' | 'navigate-usage' | 'exit'

  // Effects on the next turn
  shouldQuery?: boolean             // submit a turn after the command completes
  metaMessages?: string[]           // hidden-but-model-visible meta turns
  nextInput?: string                // preload composer with this text
  submitNextInput?: boolean         // ... and submit immediately

  // Effects on session state
  sessionPatch?: {
    modelOverride?: ModelOverride | null
    permissionMode?: PermissionMode
    // ... extensible
  }

  // For 'prompt' dispatch: the expanded prompt to send as the user turn
  submitPrompt?: ContentBlockParam[]
  submitModel?: string

  // For 'tool' dispatch: tracking
  trackRunId?: string
  pendingCurrentRun?: boolean
}
```

The shape is wider than any single harness's, but each field has a clear source in the research and a defensible reason to exist. The discipline is: every result field has a defined precedence rule (`action` runs first, then `contentDisplay` decides rendering, then `sessionPatch` applies, then `submitPrompt`/`nextInput` decide follow-up turns). The TUI / web / channel adapter implements those rules once, not per-command.

---

## Alternatives

### `args: string` instead of structured `args`

Simpler. Acceptable when: Acceptable when:

- The harness ships to a single surface (TUI only) with no native-UI ambitions.
- Built-in commands are few and well-known; per-command tokenisation is cheap.
- There's no plugin/skill author audience that needs a stable contribution shape.

Becomes a problem the moment you want Discord native commands, Slack autocompletion, or programmatic-validation. The structured shape costs ~80 lines (the `CommandArgDefinition` type + a positional parser + a `formatArgs` registry); the all-string shape costs N×40 lines (one ad-hoc tokeniser per command). Worth the structured shape if N > 10.

### Inferring dispatch mode from handler return shape

A result-field-inspection approach: every handler returns `CommandResult`, and the TUI inspects which fields are non-default to decide what to do. Saves the discriminated union but trades for:

- Harder debugging (no static type to grep for).
- Easier accidental bypass — a handler that sets both `submit_prompt` and `should_exit` has undefined behaviour.
- Harder review — a reviewer can't tell from the command's declaration whether it talks to the model or not.

Use this only when the command count is small (<20) and the team writing handlers is the same team reading the dispatcher.

### Per-surface registries

A separate command registry per surface. Acceptable when surfaces are wildly different (a web UI with a graph-based control model the TUI doesn't need). Pays for itself only when there's no overlap; in practice, ~80% of commands are surface-agnostic and the duplication tax compounds. Prefer one shared registry with `scope` gating.

### Slash commands as tools

Every slash command dispatches to a tool. Maximally uniform — there's one dispatch fabric, one schema, one audit trail. But:

- Local-only commands (`/clear`, `/help`) acquire round-trip latency through the Tool System for no benefit.
- `ui-modal` doesn't fit cleanly (modals need a surface-local callback path).
- The model-prefix path (`prompt` dispatch) requires extra plumbing to expand into a user turn rather than a tool call.

Reserve tool dispatch for the `dispatch: 'tool'` mode specifically. The other three modes have semantics the Tool System wasn't designed for.

---

## Anti-patterns

The research turned up specific patterns that should be avoided.

### A god-object `CommandResult`

A nine-field result dataclass with no precedence rules. Every dispatcher has to inspect every field; adding a tenth means touching the TUI's command-result interpreter. Better: a discriminated result type per dispatch mode, with a shared base for common fields like `content` and `sessionPatch`.

### Literal in-name markers for source disambiguation

An `(MCP)` token embedded in the command name is an anti-pattern: the parser detects MCP commands by checking whether the *second word* is literally `(MCP)`. A user who types `/notes (MCP) my note` accidentally invokes MCP routing. Use a structured `loadedFrom` field on the `Command` for disambiguation; never put it in the name.

### Untyped dispatch with a queue that doesn't know about commands

A real bug class observed in practice: several rounds of patches trying to fix the symptom, where the root cause is that the queue's "is this turn-cancellable?" check had no way to ask "is this a slash command of dispatch mode X?" because dispatch mode wasn't a thing. Type dispatch first.

### Silent collision

Filtering out duplicates silently and last-wins dict overwrite both eat duplicates without warning. The plugin author gets no feedback; the user sees the wrong command run. Fail loud at startup with `assertCommandRegistry`.

### Static suppression lists for skill/command collisions

A static alias suppression list (`_STATIC_SKILL_ALIASES = frozenset({"remember", "skill-creator"})`). Every new built-in command that happens to share a name with a popular skill has to be added to the list manually, or duplicate autocomplete entries appear. Use a generic dedup mechanism (numeric suffix) instead.

### Triple registry across languages

Multiple parallel registries in different languages. Adding `/foo` means touching multiple files in multiple languages. The web layer's typed `command.dispatch` directive is a clever salvage but it papers over a problem a shared schema would have prevented. Use one source of truth, even if it means re-exporting type definitions across language boundaries.

### Reusing one handler for two canonical commands instead of aliasing

Two commands aliasing the same handler. Two canonical entries that look identical signal "we plan to diverge but haven't yet"; in the meantime, help text lists the same command twice. Use aliases (`aliases=("subagents",)`).

### Inventing arg tokenizers inside handlers

A ~240-line nested `tokens[0]` switcher. Multiplied across N commands, this is the single largest source of "why doesn't `/foo bar:baz` work?" bug reports. Declare the args; let the parser handle them.

### Hand-coding a per-surface translator for native commands

Per-channel name regexes and length clamps in a shared sanitisation module is fine. Hand-coding "build a Discord interaction → call this slash command" plumbing per command is not. The right abstraction: native UI builds a canonical text command and dispatches it through the shared executor.

---

## Cross-references

- **Extensibility README** — the parent page covering hooks, plugins, MCP, skills, and how this fits with them. See [`./README.md`](./README.md), particularly the "Capability-typed plugin model" and "Pluggable approval flow on tool calls" sub-topics.
- **Tool System** — the dispatch target for `dispatch: 'tool'` commands. See [`../../core/tool-system/README.md`](../../core/tool-system/README.md).
- **Agent Runtime** — the consumer of `submitPrompt` and `nextInput`/`submitNextInput` results. See [`../../core/agent-runtime/README.md`](../../core/agent-runtime/README.md).
- **Conversation Manager** — owner of the message log slash commands appear in, and of the nested conversations created by `context: 'fork'` prompt commands. See [`../../core/conversation-manager/README.md`](../../core/conversation-manager/README.md).
- **Triggers** — for the trust-level model and the session-key prefix convention slash commands inherit when invoked from channels. See [`../../surfaces/triggers/triggers.md`](../../surfaces/triggers/triggers.md).
- **Interface** — surface concerns: TUI autocomplete rendering, modal dispatch UI, native channel command registration. See [`../../surfaces/interface/README.md`](../../surfaces/interface/README.md).

---
