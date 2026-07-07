# Channels (Messaging-as-Interface) — Recommended Architecture

## TL;DR

A **channel** is a messaging platform (Slack, Discord, Telegram, WhatsApp, Matrix, …) used as the agent's interface — the canonical UX is a chat app, not a terminal. The hard part isn't connecting to one platform; it's running across *many* platforms with wildly different capabilities behind one contract, without the core learning what "a Slack thread" is. This page goes deeper than the [interface README](./README.md) on that contract at scale.

The prescriptive shape:

1. **A capability record per channel, not an ABC.** A channel plugin is a record of ~40 *optional* adapter slots (`config`, `security`, `pairing`, `outbound`, `threading`, `messaging`, `streaming`, `heartbeat`, `approvalCapability`, …); it declares only what its platform supports and core composes behavior from what's present. An `ABC` with required `connect`/`send`/`send_image`/… either forces empty stubs on thin platforms or bakes the richest platform's surface into the base.
2. **One shared `message` tool in core — channels ship no send/edit/react tools.** The model emits output through a single core-owned tool; the channel's `outbound` adapter delivers it. The plugin describes any platform-specific media params via `describeMessageTool(...)`, but it does not invent its own output verb. (Same factoring as the README's `message` + portable presentation.)
3. **Session grammar maps native ids to the conversation key.** A platform's `(account, channel, thread, DM)` tuple resolves to a [Conversation Manager](../../core/conversation-manager/) session key through a plugin hook (`resolveSessionConversation`) that returns a base conversation id, an optional thread id, and ordered parent-fallback candidates (narrowest → broadest). Core owns the outer session-key shape; the plugin owns the platform-specific parsing.
4. **Security lives in the inbound slot, and inbound is untrusted by default.** DM policy, allowlists, mention-gating, self/echo filtering, and identifier redaction in logs are the channel's `security` adapter. Channel content is `channel-untrusted` until a policy admits it ([triggers/input-provenance](../triggers/)); the default DM scope isolates per channel-peer, never one shared session ([persistence](../../backends/persistence/)).
5. **Shared base behavior is core helpers, not a base class.** Retry with backoff+jitter, typing keepalive, reconnection, background-task cancellation/drain, fatal-error surfacing — every channel needs these, but they belong in *core helpers the record calls*, not baked into an inheritance chain. This is the one place the ABC looks attractive (real shared code) and the one place the record still wins (the code moves to core, the variation stays in the slot).
6. **Per-channel length caps and a threading idiom.** Each channel declares a hard `textChunkLimit` the [streaming chunker](./streaming.md) clamps to; "clean main message, verbose tool detail in a thread" is the reusable readability pattern for keeping chat legible.
7. **Approvals are a capability with a universal fallback.** Native approval cards/buttons where the platform supports them, `/approve` as the floor everywhere ([approval-ux](./approval-ux.md)).

A channel plugin is a [`registerChannel`](../../cross-cutting/extensibility/) capability registration: core owns the message tool, the session-key shape, dispatch, and the shared lifecycle helpers; the plugin owns config, security, session grammar, outbound, and threading. The largest channel sets in practice run 20+ platforms this way off one contract.

---

## Why messaging is a different surface shape

A [terminal surface](./tui.md) is one display the harness owns outright. A channel surface is the inverse: **the platform owns the UX, and there are many platforms, each with a different feature set.** Slack has Block Kit, threads, and a native streaming API; a basic IRC bridge has plain text and nothing else; WhatsApp has media but no buttons. The surface contract has to span all of them without flattening to the weakest or assuming the richest.

This is the exact pressure the [interface README](./README.md) capability-record model is built for, and channels are where it's most acute, for two reasons:

- **Capabilities vary by an order of magnitude across platforms.** Buttons, threads, reactions, edits, native streaming, media kinds, typing indicators — every platform supports a different subset. A contract that lists all of them as required methods is wrong for almost every platform.
- **The roster grows by third parties.** New platforms get added (often by plugin authors, not the core team), so the contract has to admit a *new* channel without editing core and without that channel implementing slots its platform can't honor.

So the channel layer is where "declare what you support; core composes" stops being a nicety and becomes the only model that scales. The corollary, repeated throughout: **keep platform concepts out of core.** Core knows "a conversation, a session key, a message to deliver"; it must not know what a Slack thread or a Telegram forum topic is. Those live in the channel plugin's session grammar.

---

## Recommendation

### Capability record over ABC

Model a channel as a record of optional adapter slots:

```
ChannelPlugin = {
  id, meta, capabilities,            // identity + what this platform can do
  config, configSchema, setup,        // account resolution, setup wizard
  security, pairing, allowlist,       // inbound trust: DM policy, approval, allowlists
  mentions, groups,                   // mention-gating, group semantics
  outbound,                           // deliver text/media/polls to the platform
  messaging, threading, streaming,    // session grammar, reply threading, preview streaming
  heartbeat,                          // optional typing/busy signals
  approvalCapability,                 // native approval delivery (optional)
  status, doctor, lifecycle, secrets, // ops: health, diagnostics, start/stop, secret refs
  ...                                 // ~40 slots total, nearly all optional
}
```

A thin platform fills five slots; a rich one fills thirty. Core iterates the slots that are present and composes the channel's behavior from them. Three properties make this the right shape:

- **Partial capability is the norm.** Most platforms can't do most things. Optional slots let each declare exactly its subset; an ABC would make a plain-text bridge stub out `send_image`, `edit_message`, `send_reaction`, and a dozen more.
- **Capability evolution is additive.** A new platform feature (say, native streaming) is a new optional slot; no existing channel breaks. Adding a method to an ABC breaks every subclass.
- **Third-party channels register cleanly.** A plugin author ships a record; they can't be forced to implement a method their platform lacks, and core never imports their code to discover what they support — the `capabilities` field and the present slots say it.

The ABC's appeal is that the base class can carry shared behavior (below) — but that's solvable with helpers without paying the required-method tax. See [Alternatives § ABC-per-platform](#abc-per-platform).

### One shared `message` tool in core

Channels do **not** ship their own `send` / `edit` / `react` tools. Core owns exactly one `message` tool that the model invokes to produce output; the channel's `outbound` adapter is what actually delivers it to the platform. This is the [README's](./README.md) `message` + portable-presentation factoring, and it matters most here:

- **The model learns one output verb, not one per platform.** If every channel registered its own `slack_send`, `discord_send`, `telegram_send`, the model's tool surface would balloon and fragment, and a sub-agent written against one channel couldn't run on another.
- **Portable presentation degrades per platform in one place.** The model emits a portable presentation; core renders it to the platform via the channel's `outbound`, with a text fallback when the platform can't do the rich form. The channel doesn't reimplement "how to say a message," only "how to put bytes on this wire."
- **Platform-specific media params are declared, not hardcoded.** A channel that needs extra message-tool params (an avatar URL, a cover image) exposes them through `describeMessageTool(...)` — ideally an action-keyed map so unrelated actions don't inherit each other's media args — and core uses that list for sandbox path normalization and outbound media policy. No per-channel special cases leak into the shared tool.

The rule: **core owns the verb; the channel owns the wire.**

### Session grammar: native ids → session key

Every platform identifies conversations differently — a Slack channel+thread, a Telegram chat+topic, a Discord guild+channel, a DM. The [Conversation Manager](../../core/conversation-manager/) needs *one* session-key shape; the channel needs to map its native ids onto it. Put that mapping in a plugin hook:

- `resolveSessionConversation(rawId)` returns a **base conversation id**, an optional **thread id**, an explicit `baseConversationId`, and **ordered parent-fallback candidates** (narrowest parent → broadest/base). Core owns the outer session-key shape and generic thread bookkeeping; the plugin owns the platform-specific parsing.
- **Parent fallbacks let a thread reply find its base conversation** when the thread itself has no session yet — the agent answers in-thread but with the parent chat's context, ordered so the most specific match wins.
- Keep this parsing importable before the full runtime boots (a bootstrap-safe variant) so read-only commands (`status`, `list`) can resolve session keys without starting the channel.

The companion decision is **DM scope** — when channel inbound arrives, which conversation does it land in? The default must isolate per channel-peer (and per account on a multi-tenant gateway), never a single shared session — a shared default leaks one user's DMs into another's. This is specified on the [persistence](../../backends/persistence/) page; the channel surfaces the identity fields the scope resolver keys on.

### Security lives in the inbound slot

Channel content is the canonical *untrusted* input: anyone who can message the bot can reach it. So the `security` / `pairing` / `allowlist` slots are load-bearing, not optional polish:

- **DM policy and allowlists** decide who may talk to the agent at all; **pairing** is the explicit approval flow for first contact.
- **Mention-gating** (in a group, respond only when mentioned, with a configurable scope) and **self/echo filtering** (never process the bot's own messages, or a sibling bot's) prevent loops and noise.
- **Identifier redaction in logs** keeps phone numbers, user ids, and handles out of the log stream — a real PII exposure if skipped, and it ties into the [observability](../../cross-cutting/observability/) redaction-at-emit-boundary rule.

The trust class is the spine: inbound channel content is `channel-untrusted` until a policy admits it, and the [Context Engine](../../core/context-engine/) envelope-wraps it accordingly ([triggers/input-provenance](../triggers/)). A channel that injects raw inbound text as if it were the operator's instruction is the headline security failure of the whole surface.

### Shared base behavior — core helpers, not a base class

Every channel needs the same operational machinery: retry with exponential backoff + jitter on transient sends, typing keepalive while the agent works, reconnection after a dropped socket, background-task cancellation/drain on session reset, and fatal-error surfacing (a misconfigured token shouldn't silently swallow the user's messages — surface it). This is real, substantial shared code.

The ABC's instinct is to put it in the base class and inherit it. The record's answer is **core helpers the channel calls**: a shared retry wrapper, a typing-keepalive lifecycle core drives via the `heartbeat` slot, a reconnection helper, a drain routine. The behavior is identical; the difference is *where it lives*. Helpers keep the shared code in core (one implementation, testable in isolation) while the per-platform variation stays in the slots — and a thin channel that doesn't need, say, typing keepalive simply doesn't wire the heartbeat slot, rather than inheriting a method it must override to no-op. The shared machinery is the ABC's best argument; moving it to helpers is how the record keeps that benefit without the required-method cost.

### Per-channel length caps and the threading idiom

Two readability mechanics worth standardizing:

- **A hard `textChunkLimit` per channel.** Each platform has a maximum message length; the channel declares it and the [streaming chunker](./streaming.md) clamps `maxChars` to it so a block can never exceed what the platform accepts. A soft cap (e.g. max lines per message) can further split tall replies to avoid UI clipping.
- **"Clean main message, verbose detail in a thread."** Post the answer as the main message and push tool-call detail, logs, and reasoning into a thread (where the platform supports threading). This keeps the channel legible — the casual reader sees the answer; the curious reader opens the thread. It's the channel analogue of the terminal's tool-output pane, and a reusable default for any threaded platform.

### Approvals as a capability with a universal fallback

When a tool call needs approval mid-turn, deliver it natively where the platform can (interactive buttons/cards via the `approvalCapability` slot) and fall back to a `/approve` command everywhere else. Core owns the approval lifecycle, request filtering, routing, dedupe, expiry, and the "this approval went to your DMs" reroute notices; the channel supplies only target normalization plus transport/presentation facts. Detail on [approval-ux](./approval-ux.md); the channel-specific point is that approval is *one optional capability slot*, not a reason to fork the channel contract.

---

## Alternatives

### ABC-per-platform

A `BasePlatformAdapter(ABC)` with required methods (`connect`, `disconnect`, `send`, `get_chat_info`) plus optional default-stubbed media methods (`send_image`, `send_voice`, `send_document`, `edit_message`, `send_typing`, …), subclassed once per platform, with retry/typing/reconnect/drain in the base class.

**When this works:** when the platform set is **fixed and shipped by the harness itself**, and the platforms genuinely share a method surface. The base class then carries the shared operational code for free, and a closed roster of ~20 first-party platforms that all really do `connect`/`send` is a reasonable fit. The shared-base-behavior argument is real here.

**Why not as the default:** it bakes the *delivery verb* (`send`, `send_image`, …) into the interface instead of exposing one shared `message` tool with portable presentation, so the model's output surface fragments per platform. It forces empty stubs on thin platforms and bakes the richest platform's method set into the base. And it has no clean third-party-registration story — an installed plugin can't subclass a shipped ABC without core importing its code. The capability record subsumes it: move the base-class machinery into core helpers, expose `message` + `outbound`, and the per-platform variation lives in optional slots.

### One bot process per platform

Run a separate process/service per platform, each a standalone bot that talks to the agent over an API, rather than channels as in-process plugins under one gateway.

**When this works:** when platforms have incompatible runtime requirements (a native SDK that demands its own event loop, say) or you want hard process isolation per platform for blast-radius reasons.

**Why not as the default:** session routing, dedupe, DM-scope isolation, the shared message tool, and approval lifecycle all have to be re-solved per process or pushed into a shared service anyway — you end up rebuilding the gateway. One in-process channel registry with per-channel plugins gets isolation through the plugin boundary without N processes to operate.

### Direct platform-SDK bot, no channel abstraction

Wire the agent straight to one platform's bot SDK with no channel contract at all.

**When this works:** a single-platform product that will never add a second channel. Fastest path to one working bot.

**Why not as the default:** the first time a second platform is needed, every cross-cutting concern (session grammar, security, outbound, approvals, streaming) has to be retrofitted into an abstraction that wasn't there — usually a painful rewrite. If more than one channel is even plausible, the record contract is cheap insurance.

---

## Anti-patterns

- **Platform concepts in core.** A core that knows what a "thread" or a "forum topic" is has absorbed a channel detail the next platform contradicts. Core knows conversations and session keys; the channel's session grammar owns the native id mapping.

- **A `send`/`edit`/`react` tool per channel.** Per-platform output tools fragment the model's surface and break cross-channel portability of agents and sub-agents. One core-owned `message` tool; channels deliver via `outbound`.

- **An ABC that forces stubs on thin platforms.** Required `send_image`/`edit_message`/`send_reaction` methods make a plain-text bridge implement a dozen no-ops and bake the richest platform's surface into the base. Optional capability slots; declare what the platform supports.

- **Default DM scope = one shared session.** On a multi-user channel, a single shared conversation leaks one person's DMs into another's. Default to per-channel-peer isolation; require an explicit opt-in for a shared session.

- **Injecting raw inbound channel text as trusted instruction.** Channel content is `channel-untrusted`; treating an inbound message as if it were the operator's command is prompt-injection by construction. Run it through the security slot and envelope-wrap per its trust class.

- **No idempotency on inbound.** Platforms redeliver on reconnect; without a dedupe key the agent runs twice on the same message. Dedupe inbound on `(channel, account, peer, session, message id)` ([persistence](../../backends/persistence/)).

- **Swallowing fatal connection errors.** A bad token that yields a silent connect-loop makes the user's messages vanish with no signal. Surface fatal channel errors (a status/health slot) instead of looping quietly.

- **Logging raw identifiers.** Phone numbers, handles, and user ids in the log stream are a PII exposure. Redact identifiers at the channel boundary, consistent with the [observability](../../cross-cutting/observability/) emit-boundary redaction rule.

- **Exceeding the platform's length cap.** A block longer than the platform accepts fails or truncates. Declare a per-channel `textChunkLimit` and clamp the chunker to it; split tall replies under a soft line cap.

- **Re-implementing retry/typing/reconnect per channel.** Copy-pasted operational machinery drifts across channels. Put it in core helpers the channel calls; keep only the per-platform facts in the slots.

---

## Cross-references

- [Interface README](./README.md) — the capability-record surface model, one shared `message` tool, portable `MessagePresentation` with core-owned text fallback.
- [streaming.md](./streaming.md) — block vs preview streaming on channels, the chunker, and the per-channel `textChunkLimit` clamp.
- [approval-ux.md](./approval-ux.md) — native approval cards vs the `/approve` fallback (the `approvalCapability` slot).
- [Conversation Manager](../../core/conversation-manager/) — the session-key shape the channel's session grammar maps native ids onto.
- [Persistence](../../backends/persistence/) — DM-scope isolation defaults and inbound idempotency dedupe.
- [Triggers / input-provenance](../triggers/) — channel inbound as `channel-untrusted`, mention-gating, and the trust-classification machinery.
- [Extensibility](../../cross-cutting/extensibility/) — `registerChannel` as a capability registration; channels as first-class plugins.
