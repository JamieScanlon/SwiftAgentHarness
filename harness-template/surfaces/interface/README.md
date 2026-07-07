# Interface

> **Role:** Surface (client of the [Communication Layer](../../core/communication-layer/)). Not an inner-ring layer.
> **Status:** Drafted 2026-05-29. Leaf pages in this folder go deeper on individual capability slots.

## TL;DR

The **interface** is wherever a human (or an autonomous [trigger](../triggers/)) meets the harness: it ingests input and renders output. It is a **surface** — a client of the Communication Layer — never an inner-ring concern. The agent core must never import a surface; a surface implements a frozen contract and subscribes to the conversation's event stream.

The prescriptive shape is a **uniform Surface contract**: a capability-typed plugin record (not an ABC, not bespoke per-surface code) whose slots the surface fills as far as its medium allows, with core supplying the gaps. Concretely:

1. **One shared output tool, never per-surface tools.** The model emits a single `message` / output intent regardless of whether it is talking to a terminal, Slack, or a webview. Surfaces translate that intent into native shapes. The model's tool vocabulary does not grow when you add a channel.
2. **Output is portable; input is surface-native.** Render a portable `MessagePresentation` (semantic blocks: text / context / divider / buttons / select) that each surface maps to its best native control. Input — composer, IME, paste, autocomplete — is inherently surface-specific; the only portable inbound artifact is the normalized, trust-classed envelope handed to the Triggers router.
3. **Core owns degradation.** A surface declares `presentationCapabilities`; if it can't render a block type (or the adapter is absent), **core** renders conservative text (title as first line, button labels inline, select options listed). Provider-native fields never leak into the shared output schema.
4. **Streaming granularity is a surface capability, not a global setting.** A capability ladder — token-delta (terminals, native web) → block (coarse messages) → preview-edit (partial / progress) → final-only — chosen by what the surface can afford. Most messaging channels cannot accept token-delta edits without hitting rate limits, so they get blocks or preview edits.
5. **Liveness is a first-class primitive.** Typing indicators, presence, tool-progress lines, and spinners keep multi-step turns visually alive. Presence is Comm-Layer-owned and surface-rendered.
6. **Separate approval classification from approval delivery.** *What* needs approval and the rich per-tool data is classified at the Tool System / exec layer; *how* the approval is delivered is a per-surface capability (native cards on Slack/Discord/Teams, a text `/approve` fallback for headless surfaces). Coupling the approval shape to both the tool and the surface — as a single-surface TUI does — produces beautiful but un-portable UX.
7. **Agent-driven UI is a surface capability dispatched as a tool.** For surfaces that can host a webview, let the agent render arbitrary interactive UI back (canvas / A2UI / artifacts). It is advertised to the model and dispatched through the Tool System like any other tool, not a side channel.
8. **Personality, voice, and return affordances are interface concerns.** A `SOUL.md`-style voice file ("what does my agent feel like to talk to"), realtime voice in/out as provider slots, and an away-summary recap for surfaces a user steps away from all belong conceptually to the surface even when assembled elsewhere.

The consensus is strongest on (1), (2), and (4): every harness that reaches more than one surface ends up with some encoding of "the agent core never imports a surface; surfaces implement a frozen contract."

## How this fits the architecture

A surface is a **client of the Communication Layer**, addressed against a conversation, not a connection. The [Communication Layer](../../core/communication-layer/) already provides the multiplexed event bus, reconcile-and-watch, and replay; the [Conversation Manager](../../core/conversation-manager/) owns the conversation resource; [Triggers](../triggers/) already classify inbound provenance into trust levels. The interface is therefore *thin by design*: it does not own conversation state, model dispatch, or tool execution. It owns rendering, input capture, and the surface-native session grammar that maps a channel/thread/DM onto a conversation key.

**The asymmetry: input is surface-native, output is portable.** This is the single most clarifying framing for the layer. Output can be described once as semantic intent and rendered everywhere because the agent only ever needs to express *what to show*, not *how*. Input cannot: a terminal composer with IME and bracketed paste, a Slack slash command, a wake-word voice activation, and an ACP editor request have nothing portable in common except that, once received, each normalizes to the same trust-classed inbound envelope. So the portable inbound contract is the *envelope*, not the composer. Build per-surface input; build portable output.

| Concern | Owner | Notes |
|---|---|---|
| Conversation state, branching, session key | [Conversation Manager](../../core/conversation-manager/) | Surface maps native ids onto the session key; never stores conversation state itself. |
| Event stream, reconcile-and-watch, replay | [Communication Layer](../../core/communication-layer/) | Surface subscribes at its own streaming granularity off the same stream. |
| Inbound trust classification | [Triggers](../triggers/) | Surface normalizes native input to an envelope; Triggers assigns trust level and routes. |
| What needs approval + rich per-tool data | [Tool System](../../core/tool-system/) | Surface delivers the approval and collects the decision. |
| System-prompt assembly (incl. personality) | [Context Engine](../../core/context-engine/) | Surface/workspace *authors* `SOUL.md`; Context Engine assembles it. |
| Rendering, input capture, native session grammar, streaming granularity, liveness, approval delivery, agent-driven UI hosting | **Interface (this layer)** | The surface contract. |

## What a surface plugin owns

A surface plugin is a **capability-typed record**: it declares only the slots it supports, and core composes behavior from what is present. This is the same shape as the [provider plugins](../../backends/providers/) — capability record over ABC — and for the same reason: surfaces vary wildly in what they can do (a terminal can stream tokens and host no buttons; Slack can render Block Kit but can't token-stream; a webview can host arbitrary UI), so an ABC with required methods either forces empty stubs or bakes the richest surface's assumptions into the contract.

### Plugin layout

```
surfaces/<surface-name>/
  manifest.ts        # capability declaration: which slots are implemented
  inbound.ts         # native input → normalized trust-classed envelope
  session.ts         # native ids (channel/thread/DM) → conversation session key
  outbound.ts        # MessagePresentation → native render; presentationCapabilities
  streaming.ts       # chosen granularity off the conversation event stream
  liveness.ts        # typing / presence / tool-progress (optional)
  approval.ts        # deliver approval request, collect decision (optional)
  commands.ts        # slash-command / directive registration (optional)
  canvas.ts          # agent-driven UI host (optional)
  voice.ts           # realtime transcription / voice provider wiring (optional)
  lifecycle.ts       # connect / disconnect / setup wizard / status / doctor
```

### The surface contract (capability slots)

Folding the six harnesses together, a surface implements as many of these as its medium allows; core fills the rest:

1. **Identity & lifecycle** — connect / disconnect, account & config resolution, setup wizard, status, doctor.
2. **Inbound** — receive native input, normalize to a trust-classed envelope, hand to the [Triggers](../triggers/) router. Security / pairing / allowlist / mentions live here.
3. **Session grammar** — map surface-native conversation ids (channel, thread, DM) onto the [Conversation Manager](../../core/conversation-manager/)'s session key.
4. **Outbound render** — take the agent's portable output intent and render it natively, declaring capabilities and degrading safely.
5. **Streaming** — choose granularity from the capability ladder (token-delta → block → preview-edit → final-only), driven by what the surface affords.
6. **Liveness** — typing indicators, presence, tool-progress lines, spinners.
7. **Approval UX** — deliver an approval *request* (classified elsewhere) as the best native control and collect the decision, with a text `/approve` fallback for headless/limited surfaces.
8. **Control surface** — slash commands / directives, text vs native registration, completion. *(see [slash-commands.md](slash-commands.md))*
9. **Agent-driven UI** — let the agent render arbitrary interactive UI back (canvas / A2UI / artifacts) for surfaces that can host a webview.
10. **Voice** — realtime transcription in, realtime voice out, as provider slots independent of the text channel.
11. **Personality** — a voice/tone surface (`SOUL.md`) injected into the system prompt, owned conceptually by the interface.
12. **Return affordances** — away-summary / idle-return recap for surfaces a user steps away from. *(single-surface TUI implementations.)*

### The outbound seam (the part that pays off)

The outbound adapter is where portability is won or lost. Model it as three pieces:

- **`presentationCapabilities`** — booleans the surface declares: `{ supported, buttons, selects, context, divider }`. Lets core decide upfront whether to hand the surface a rich presentation or pre-degrade it.
- **`renderPresentation(presentation) → nativePayload`** — maps the portable `MessagePresentation` to the surface's best native shape (Discord component containers, Slack Block Kit, Telegram inline keyboards, Teams Adaptive Cards, Feishu interactive cards, or plain text).
- **`sendPayload` / chunker / `textChunkLimit`** — delivery, with a per-surface hard cap on message length and a chunker that respects it.

**Core owns the fallback.** If `renderPresentation` is absent or returns "can't render this block type", core renders conservative text from the same presentation — title as the first line, button labels listed inline, select options enumerated. The producer (agent, CLI, approval flow) describes intent *once*; no producer ever branches on surface type. The explicit rule, worth stating in code review terms: **do not add provider-native fields to the shared output schema** — those are renderer outputs owned by the surface plugin.

### The portable presentation payload

```
MessagePresentation = {
  title?: string,
  tone?: "info" | "success" | "warning" | "error" | ...,
  blocks: Array<
    | { type: "text",    text: string }
    | { type: "context", text: string }     // de-emphasized / metadata
    | { type: "divider" }
    | { type: "buttons", buttons: Array<{ id, label, style? }> }
    | { type: "select",  options: Array<{ id, label }> }
  >
}
```

This is the entire portable vocabulary. It is deliberately small: anything richer is a renderer concern. The same payload describes an agent message, a CLI status line, and an approval card — which is exactly why approval delivery can be portable while approval classification stays per-tool.

## Recommendation

**1. Make the surface a capability-typed plugin record, not an ABC.** Declare slots; let core compose. Reserve the ABC shape for a fixed, known set of platforms you ship yourself; the moment surfaces vary in capability, the record wins.

**2. One shared `message` / output tool in core.** The model's tool list must not grow per surface. The surface owns config, security, pairing, session grammar, outbound, threading, and heartbeat typing — not its own send/edit/react tools.

**3. Portable output, surface-native input.** Render `MessagePresentation`; capture input however the medium demands and normalize to the inbound envelope. Do not chase a portable composer.

**4. Treat streaming granularity as a per-surface, per-attachment choice.** When a terminal client and a Slack client attach to the *same* conversation (the Comm Layer allows it), each subscribes to the same event stream and renders at its own granularity — the terminal token-streams, Slack block-streams or preview-edits. State this explicitly so nobody assumes token streaming everywhere.

**5. Build the streaming chunker carefully.** A block chunker with `minChars`/`maxChars` bounds and a break-preference ladder (paragraph → newline → sentence → whitespace → hard) that **never splits inside a code fence** (close and reopen the fence when forced). Coalesce consecutive blocks on idle gaps; optionally add a small randomized human-delay between bubbles on chatty channels; hard-cap `maxChars` at the surface's `textChunkLimit`.

**6. Liveness: typing modes + presence.** Offer `typingMode ∈ never | instant | thinking | message` (ordered by how early the indicator fires) plus a refresh cadence. Keep presence a best-effort merged map owned by the Comm Layer / gateway and *rendered* by surfaces, keyed by a stable instance id with a short TTL; don't let ephemeral one-off CLI connections spam it.

**7. Separate approval classification from delivery.** The Tool System / exec layer decides *what* requires approval and carries the rich data (a diff, a command, a destructive flag). The surface decides *how* to ask: native cards/buttons where available, a text `/approve` fallback everywhere. The runtime prompt should be told to rely on native UI first and fall back to text. This is the same split [execution-environments](../../backends/execution-environments/) argues for exec approvals.

**8. Agent-driven UI as a Tool-System tool.** Expose "render UI" (canvas / A2UI) as a capability advertised to the model and dispatched through the Tool System, consistent with the tool-call-vs-context-resource framing in [core](../../core/). Sandbox the webview (custom scheme, directory-traversal blocked, files confined to the session root) and gate any UI→agent deep links behind confirmation.

**9. Voice in/out as provider slots.** Register realtime transcription and realtime voice as distinct provider capabilities (like models), not as methods bolted onto a text channel. Surface them as wake-word and continuous-listen modes per platform.

**10. Personality and return affordances.** Keep a `SOUL.md`-style voice file separate from operating-rules instructions; the [Context Engine](../../core/context-engine/) injects it, but it is authored as an interface concern. Provide an away-summary: a *separate* small-fast-model call over recent messages only (not the compaction pipeline, throwaway output, skip cache write) that produces a 1–3 sentence "here's the task and the next step" recap when a user returns.

## Alternatives (what each harness actually does)

**Capability-record channel-as-interface at scale.** 24+ channel plugins behind a `ChannelPlugin` record of ~40 optional adapter slots; one shared `message` tool in core; a portable `MessagePresentation` contract with core-owned text fallback; block + preview streaming with a code-fence-aware chunker; `typingMode` + a gateway presence map; native approval cards + `/approve` fallback; Canvas (WKWebView) + A2UI agent-driven UI; realtime transcription/voice provider slots; `SOUL.md` personality.

**Single-surface TUI — the deeply-coupled alternative.** React+Ink rendering driven straight from the runtime with *no* surface abstraction. Per-tool permission components plus a fallback. This is the right shape for an IDE-coupled coding agent with exactly one surface — and the explicit cautionary tale for portability: the approval shape is coupled to both the tool and the surface, so the same approval can't go to Slack without a rewrite. Also the origin of the away-summary affordance worth lifting.

**Protocol-decoupled multi-frontend.** One `BackendEvent` / `FrontendRequest` protocol behind both a React-based terminal frontend (launched out-of-process) and a Python TUI app. The protocol *is* the surface contract, frozen enough that two completely different rendering stacks implement it.

**ABC-per-platform messaging gateway.** 20+ platforms behind `BasePlatformAdapter(ABC)` with required methods and optional default-stubbed media methods, plus shared retry / keepalive / reconnection / per-platform length caps in the base. Bakes the *delivery verb* into the interface and exposes no portable presentation — the instructive contrast to the `message` + `renderPresentation` factoring.

**Minimal custom differential renderer + multi-surface.** Hand-written TUI with a 3-strategy differential renderer (first-render / full re-render on width-or-above-viewport change / minimal changed-line update) and CSI 2026 synchronized output, on a minimal `Component { render(width): string[] }` contract. Plus Slack bot ("clean main messages, verbose tool details in threads") and a Lit web-ui. Shows a minimal contract + per-surface bots is viable for a library, at the cost of no portable presentation.

**Python-TUI CLI + ACP bridge.** A Python TUI app with graph-executor-framework HITL middleware + `ask_user` for permissions (no bespoke per-tool components), plus an ACP (Agent Client Protocol) bridge that treats "expose the agent to any ACP-compatible editor" as a surface. Thinnest approach; leans entirely on the framework stream for output.

## Anti-patterns

- **Per-surface output tools.** Giving the model a `slack_message` tool and a `discord_message` tool grows the tool vocabulary with every channel and leaks delivery into the model's job. One shared output tool; surfaces translate.
- **Provider-native fields in the shared output schema.** Adding `slackBlockKit` or `discordComponents` to the shared message tool. Those are renderer outputs owned by the surface plugin; the shared schema stays portable.
- **Assuming token-delta streaming everywhere.** Token-streaming to a messaging channel means an edit per token and instant rate-limit death. Streaming granularity is a surface capability; channels get blocks or preview edits.
- **Splitting a code fence mid-stream.** A chunker that breaks inside a ``` block produces broken rendering on every channel. Close and reopen the fence when a hard split is unavoidable.
- **Coupling approval shape to the tool *and* the surface.** Beautiful per-tool cards that only exist in one renderer (the single-surface coupling trap). Classify per-tool; deliver per-surface; always have a text fallback.
- **No text fallback for rich UI.** If a surface can't render buttons/cards and core doesn't degrade, the user sees nothing actionable. Core must always be able to render conservative text from the same presentation.
- **Surface importing the agent core (or vice versa).** The agent core must never `import` a surface. Decouple via a typed event protocol or a capability record so surfaces are swappable and the core is testable headless.
- **Storing conversation state in the surface.** The Conversation Manager owns conversation state; the surface only maps native ids onto the session key. Surface-held state breaks multi-client attach and reconnection.
- **Treating presence as a per-surface concern.** If each surface invents its own presence, you can't merge it. Presence is Comm-Layer-owned and surface-rendered.
- **Letting one-off connections spam presence.** Ephemeral CLI invocations shouldn't create presence entries; cap entries and TTL them.
- **Folding the away-summary into compaction.** Different model, different trigger, throwaway output. Keep it a separate small-fast-model call that skips the cache write; don't pollute the compaction pipeline.
- **Mixing personality into operating-rules instructions.** Keep the voice/tone file (`SOUL.md`) separate from the rules file (`AGENTS.md`/`CLAUDE.md`); conflating them makes both harder to tune.
- **Agent-driven UI as an unsandboxed side channel.** A webview that can read arbitrary files or trigger agent runs without confirmation is an injection surface. Confine to the session root, block traversal, confirm UI→agent deep links, and dispatch the "render UI" capability through the Tool System.
