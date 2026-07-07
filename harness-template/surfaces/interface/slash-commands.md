# Slash Commands (Control Surface) — Recommended Architecture

## TL;DR

Slash commands are the user's **control surface** — the way a human steers the harness (start a session, set the model, ask for status) inside the same input box they use to talk to the agent. The command *system* has two halves: a registry/dispatch half (the `Command` record, dispatch modes, parser, validator, native-UI registration table — all on the [extensibility slash-commands page](../../cross-cutting/extensibility/slash-commands.md)) and a **control-input half**, which is this page. This page covers how raw user input is classified at the surface boundary, how the control surface degrades per surface, and how commands are completed and authorized.

The prescriptive shape:

1. **Three syntactic categories, classified at the input boundary.** *Commands* (`/...` as the whole message) run instead of a model turn. *Directives* (`/think`, `/model`, `/verbose`) tune the turn and are **stripped before the model sees them**. *Inline shortcuts* (`/help`, `/status`) run immediately and the remaining text continues as a normal turn. The discipline that matters: **directives and shortcuts never reach the model as content.**
2. **Directives behave differently inline vs. directive-only.** In a normal message, a directive is an *inline hint* for this turn only (doesn't persist). In a message that is *only* directives, it *persists* to the session and replies with an acknowledgement. Same token, two scopes, decided by whether there's accompanying prose.
3. **The control surface degrades per surface — exactly like output.** Text commands (`/...` parsed from the message) work on *every* surface. Native registration (platform slash-command pickers) is a progressive enhancement where the platform supports it. Never make a command *only* reachable natively; text is the floor.
4. **Completion is surface-native; the registry is shared.** The composer renders completions in the surface's idiom (terminal autocomplete, native platform pickers) off one shared command registry. The input-handler owns the *presentation* of completion; the registry owns the *data*.
5. **Commands and directives are privileged input — authorize them.** They change session and runtime state, so they're gated (allowlists, owner-only for sensitive ones, access groups). An *unauthorized* sender's `/command` is treated as **plain text** — it falls through to the model as ordinary content rather than executing. That fall-through is a security property, not a bug.
6. **Skills can surface as commands.** A user-invocable skill appears in the command set (and natively where supported), so "run this procedure" is one slash away. Namespaced by skill name.
7. **Ship a core command set.** A small, predictable baseline (`/new`, `/reset`, `/compact`, `/stop`, `/status`, `/think`, `/model`, `/usage`, `/approve`, `/help`) so every deployment has the same muscle memory.

The control surface is the **input-side mirror** of the README's output story: just as output is one portable presentation rendered per surface, the control surface is one shared command registry *parsed* and *completed* per surface, with a universal text floor.

---

## Why this is a surface concern (and what isn't)

The [extensibility slash-commands page](../../cross-cutting/extensibility/slash-commands.md) is the home for the command *system*: the typed `Command` record, the `dispatch` discriminator (`local` / `prompt` / `tool` / `ui-modal`), the argument grammar, the startup validator, conflict policy, hot reload, and the per-platform native-registration table (Discord/Telegram/Slack name rules). None of that is repeated here.

What's left — and genuinely surface-shaped — is the **control-input boundary**: the moment a user's keystrokes become *either* a command, a directive, or a model turn. That classification happens at the surface, before dispatch, and it's where the surface-specific concerns live: how raw input is parsed, how completion is presented in this medium, how the control surface degrades when the platform is thin, and how privileged input is authorized. The registry decides *what a command is*; the surface decides *how the user reaches and triggers it*.

The relationship to the rest of the interface contract: commands are the control-plane counterpart to [streaming](./streaming.md) (output cadence) and [approval-ux](./approval-ux.md) (decisions). All three are "one shared model, rendered/parsed per surface, with a text floor."

---

## Recommendation

### Three syntactic categories at the input boundary

Parse every inbound message into one of three shapes *before* deciding whether the model runs:

- **Commands** — a standalone `/...` message. The whole message is the command; the model does **not** run this turn. `/new`, `/compact`, `/status`. (A shell escape like `! <cmd>` is the same shape with a different sigil.)
- **Directives** — tuning tokens (`/think <level>`, `/model <name>`, `/verbose`, `/reasoning`, `/elevated`, `/queue`) that modify *how* the turn runs. They are **stripped from the message before the model sees it**, so the model never reads `/think high` as content — it just runs at the higher thinking level.
- **Inline shortcuts** — a small set (`/help`, `/commands`, `/status`, `/whoami`) that run immediately and then let the *remaining* text continue through the normal flow. "`/status` what's the weather" prints status and then answers the question.

The load-bearing discipline is the **strip-before-model rule**: directives and shortcuts are control signals, not content. If `/think high explain X` reaches the model verbatim, the model wastes attention parsing a directive it shouldn't see, and worse, a directive's *effect* (raise thinking level) gets confused with its *text*. Strip the control tokens, apply their effect, pass only the genuine prose to the model.

### Directive scope: inline hint vs. session setting

A directive means two different things depending on whether it stands alone:

- **In a normal message** (directive + prose): an **inline hint** for *this turn only*. `/think high summarize the logs` runs this one turn at high thinking; the session's default is unchanged.
- **In a directive-only message** (nothing but directives): a **persisted session setting**, acknowledged back. `/think high` on its own sets the session to high thinking until changed.

This is the right ergonomics: a user can reach for more thinking on a single hard question without permanently changing their session, *or* flip the session default deliberately — using the same token, disambiguated by context. The session-setting case writes through to the [Conversation Manager](../../core/conversation-manager/)'s session state; the inline-hint case is scoped to the one turn and discarded.

### The control surface degrades per surface

This is the input-side mirror of portable output. Two registration paths, with a strict precedence:

- **Text commands always work.** Parsing `/...` out of an inbound message needs nothing from the platform; it's pure surface-side string handling. This is the floor on *every* surface — terminals, webchat, and channels with no native command support all get text commands.
- **Native registration is a progressive enhancement.** Where a platform has first-class slash commands (native pickers, argument hints), register there too, automatically where the platform allows it and via app-side setup where it doesn't. Native gives discoverability and inline argument UI; it doesn't *replace* text.

The rule: **never make a command reachable only natively.** A native-only command vanishes on any surface without native support — which is most of them. Native is additive discoverability over a text floor that's always present. (The mechanics of *how* each platform registers — name sanitization, command-count caps, reserved names — are the extensibility page's table; the surface-side principle is just "text floor, native enhancement.")

### Completion is surface-native, off a shared registry

Completion has the same shape as the rest of the surface contract: shared data, per-surface presentation.

- The **registry** exposes the index completion needs — names, aliases, descriptions, provenance, tier, per-argument choices. (Detailed on the [extensibility page](../../cross-cutting/extensibility/slash-commands.md#completion--discovery).)
- The **surface's input handler** renders that index in its native idiom: a terminal draws an autocomplete dropdown in the composer; a native platform surfaces its own command picker; a thin channel offers nothing and relies on `/help`. The completion *UI* is surface-local and non-portable — it's part of the [composer](./tui.md), which doesn't cross surfaces.

Keep two composer affordances *separate* from slash-command completion, because they're different input modes: `@`-prefixed mention/file completion and `!`-prefixed shell escapes live in the input handler alongside slash completion but are their own concerns, not slash commands.

### Commands and directives are privileged input — authorize them

Commands change state — they start sessions, switch models, toggle elevated execution, read or write config. So they are **privileged input** and must be authorized, not run for anyone who types them:

- **Allowlists** decide who may run commands/directives at all; **owner-only** gating restricts the sensitive ones (config, plugin management, restart, send-policy); **access groups** scope by role.
- The **fall-through rule is a security property**: when an *unauthorized* sender types `/model gpt-whatever`, it is **not** executed and **not** an error — it's treated as plain text and passed to the model as ordinary content. An attacker DMing a bot can't drive its control surface by guessing command names; their `/commands` are just words. This matters most on [untrusted channels](../triggers/), where anyone can message the agent.

The authorization decision belongs at the surface/control boundary (the surface knows the sender identity), but the *policy* is shared configuration — the same allowlist/owner model the [channels security slot](./channels.md) uses for inbound.

### Skills as commands

A user-invocable skill should be reachable as a slash command, so a saved procedure is one keystroke away rather than a prompt the user has to remember. Surface it like any other command — in the command set, in completion, and natively where the platform supports skill registration (with the same text floor when it doesn't). Namespace by skill name to avoid collisions with built-ins. The dispatch mechanics (a skill command that bypasses the model and calls a tool directly, with raw argument passing) live on the [extensibility page](../../cross-cutting/extensibility/slash-commands.md) and the [Tool System](../../core/tool-system/); the surface-side point is that the user experiences skills and built-ins as one uniform command surface.

### A core command-set baseline

Ship a small, predictable set so muscle memory transfers across deployments. A reasonable baseline:

- **Session lifecycle:** `/new [model]`, `/reset`, `/compact [instructions]`, `/stop`.
- **State & visibility:** `/status`, `/usage`, `/context`, `/tools`, `/help`, `/commands`.
- **Turn tuning (directives):** `/think <level>`, `/model [name]`, `/verbose`, `/reasoning`.
- **Decisions & control:** `/approve <id> <decision>`, `/agents`, session-binding controls (`/session idle`, `/session max-age`).

Keep the *essential* tier (~10 commands) visible by default and push the long tail behind tiered discovery ([extensibility page](../../cross-cutting/extensibility/slash-commands.md)). The goal is that `/help`, `/status`, `/new`, and `/stop` mean the same thing everywhere the harness runs.

---

## Alternatives

### Everything is a model turn (no command layer)

Skip the control surface; let the user phrase control requests in natural language ("start a new session," "use a cheaper model") and have the model call tools to effect them.

**When this works:** for a minimal assistant where control actions are rare and latency-insensitive, and you'd rather not build a parser.

**Why not as the default:** control actions become slow (a full model round-trip to do `/stop`), unreliable (the model may misinterpret "reset"), and unsafe (a destructive control action mediated by the model's judgment rather than an explicit command). Worst of all, `/stop` *needs* to work when the model is busy or stuck — exactly when routing it through the model fails. A direct command layer makes control deterministic and instant.

### Native-only commands (no text floor)

Register slash commands only through each platform's native system; don't parse `/...` from message text.

**When this works:** a single-platform deployment on a platform with rich native commands, that will never add a text-only surface.

**Why not as the default:** the command surface evaporates on any surface without native support — terminals, webchat, and several major channels. Users on those surfaces have *no* control affordance. The text floor is what makes commands universal; native is the enhancement, not the substrate.

### Directives passed through to the model

Leave `/think`, `/model` in the message and let the model (or a system-prompt convention) interpret them.

**When this works:** essentially a prototype shortcut; never robust.

**Why not:** the model spends attention parsing control tokens, the directive's effect and its text get conflated, and unauthorized senders' directives become injectable model content. Strip directives at the surface boundary and apply their effects out of band.

---

## Anti-patterns

- **Letting directives or shortcuts reach the model as content.** Control tokens aren't prose; the model shouldn't read `/think high` as text. Strip before the model, apply the effect out of band.

- **Conflating inline-hint and session-setting directive scope.** If `/think high <question>` permanently changes the session, the user can't reach for more thinking on one question without side effects. Inline directives are this-turn-only; directive-only messages persist.

- **Native-only commands.** A command reachable only through a platform's native picker disappears on every surface without native support. Always parse a text floor.

- **Executing commands for unauthorized senders.** Commands change state; running them for anyone who types `/` is an escalation. Authorize at the control boundary; treat an unauthorized command as plain text (the fall-through is a feature).

- **Routing `/stop` (and other urgent controls) through the model.** Control that only works when the model is responsive fails exactly when it's needed. Make commands a direct, model-independent path.

- **A portable completion UI.** The composer's completion dropdown is terminal-specific; trying to share it across surfaces fails because input idioms don't match. Share the registry index; render completion per surface.

- **Per-surface divergence in the core command set.** If `/status` means different things on different surfaces, muscle memory breaks. Keep the essential set identical everywhere; let only availability (not meaning) vary by surface and config.

---

## Cross-references

- [Extensibility / slash-commands](../../cross-cutting/extensibility/slash-commands.md) — the command *system*: `Command` record, dispatch modes, parser, validator, conflict policy, hot reload, per-platform native-registration table, completion-index mechanics.
- [Interface README](./README.md) — the surface contract; commands as the control-plane counterpart to portable output.
- [Tool System](../../core/tool-system/) — `dispatch: tool` commands and skills-as-commands targets; where `allow-always` permission rules live.
- [Conversation Manager](../../core/conversation-manager/) — session settings a directive-only message persists.
- [channels.md](./channels.md) — the inbound security slot and the shared allowlist/owner authorization model.
- [tui.md](./tui.md) — the composer that hosts surface-native completion; `@`/`!` prefixes as separate input modes.
- [Triggers / input-provenance](../triggers/) — why command authorization matters most on untrusted channels.
