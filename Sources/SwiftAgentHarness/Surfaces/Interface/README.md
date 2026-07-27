# Interface Surfaces

An **interface surface** is a client of the [Communication Layer](../../Core/CommunicationLayer/):
it ingests input from a human and renders the conversation event stream back to them.
Two live here — [`Channel/`](Channel/) (Slack, Telegram, Discord, email) and
[`TUI/`](TUI/) (the terminal) — and they are as different as two surfaces get. One speaks
a rate-limited platform API with threads and typing indicators; the other owns a raw
character grid and repaints on every token.

They share one contract anyway, because the parts that *are* common are the parts worth
sharing.

## The uniform contract

`SurfacePlugin.swift` declares what every surface answers:

| Slot | Meaning |
|---|---|
| `surfaceID` | Matches the `originSurface` provenance value used for routing and trust |
| `surfaceMeta` | Display name + kind discriminator |
| `surfaceCapabilities` | Capability *record* — which rungs and features this surface actually has |
| `presentationRenderer` | Turns a portable `MessagePresentation` into something this surface can show |
| `surfaceMessageToolDescriptor` | Optional media params contributed to the shared `message` tool schema |
| `streamingCapabilities` | Position on the [streaming ladder](Streaming/) |

**Delivery is deliberately not on the contract.** A channel needs a chat id, a thread id
and a reply target; a terminal writes into its own transcript. Forcing both through one
delivery method would mean inventing a target type the terminal has to stub. Rendering is
shared; delivery is surface-specific.

**Threading and heartbeat are channel extensions, not shared slots**, for the same reason.
A terminal has no honest implementation of either, and a contract whose members half its
implementers stub out has already decayed into a lowest-common-denominator interface. A
capability *record* lets a surface say "token streaming and native buttons, no threading"
without inheriting behaviour it must fake.

## Portable presentation, surface-native input

The split that makes this work:

- **Outbound is portable.** Core emits a `MessagePresentation` — title, tone, and blocks
  (`text`, `context`, `divider`, `buttons`, `select`). Each surface declares what it can
  render natively via `SurfacePresentationCapabilities`; `SurfacePresentationFilter` drops
  the rest. **The text floor is unconditional**: `presentation.textFallback()` is always
  present in the rendered payload, so a surface that supports nothing still shows
  something correct. Native structure is an *enhancement*, never a prerequisite.
- **Inbound is surface-native.** A terminal composer and a Slack message event have nothing
  in common mechanically. What crosses the boundary is the normalized envelope — text,
  attachments, provenance — not the input machinery. Don't try to share a composer; share
  the envelope.

## Control input

Slash commands, directives and inline shortcuts are **classified in core**, not in the
surface. `SlashCommandDispatchService.processControlInputBoundary` runs inside
`sendMessageAndStreamResponse`, where it can build a conversation-scoped registry and
derive real authorization from the conversation owner.

A surface that classifies before sending duplicates that logic with a static registry and
a default authorization — weaker on exactly the axis that matters. The genuinely
surface-local jobs are autocomplete presentation, provenance stamping, and deciding
whether to echo a line into its own transcript.

## Approvals

Core owns classification and lifecycle (dedupe, expiry, reroute, waiters). The surface's
whole job is to render the `ApprovalPresentation` and report a decision back through
`ExecApprovalInbound.resolve` — the button ids are already `ApprovalDecision` tokens, so
they feed it directly. Every surface must keep the `/approve` text floor working; native
cards are an enhancement on top, never a replacement.

## Adding a surface

1. Implement `SurfacePresentationRendering` — usually a thin wrapper over
   `SurfacePresentationFilter.render` with your capability record.
2. Declare a `SurfacePlugin` (a struct is fine; `TUISurfacePlugin` is the smaller example,
   `ChannelSurfacePlugin` the fuller one).
3. Implement `MessageOutputDelivering` and register it with
   `MessageOutputDeliveryRegistry` under your `surfaceID` — **without this, committed
   `message`-tool output for your surface is silently dropped** and only the tool result's
   text fallback survives.
4. Implement `ConversationStreamConsumer` and attach it to the conversation event stream.
5. Produce the inbound envelope with correct provenance; send raw text.

## Related

- [`Streaming/`](Streaming/) — the capability ladder and the paced delivery engine
- [`Commands/`](Commands/) — the control-input classifier and slash-command registry
- [`Channel/README.md`](Channel/README.md) — the messaging-channel surface
- [`TUI/README.md`](TUI/README.md) — the terminal surface
