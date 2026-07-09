# Approval UX — Recommended Architecture

## TL;DR

When a tool call needs human sign-off, two questions arise and they belong to different layers: **what** needs approving (and the rich data that justifies it) is decided once, at the [Tool System](../../core/tool-system/permissions.md) / [exec](../../backends/execution-environments/) layer; **how** the approval is asked is a per-surface capability. This page goes deeper than the [interface README](./README.md) (§ Rec 6–7) on the delivery half.

The prescriptive shape:

1. **Separate classification from delivery — the central lesson.** The classifier produces one surface-agnostic *approval request* (title, description, the rich payload: a diff, a command, a destructive flag, a severity). Every surface renders that same request as the best control it can offer. Coupling the approval's shape to *both* the tool and the surface is the trap (below).
2. **An approval is just a `MessagePresentation`.** Because the [portable presentation vocabulary](./README.md) already includes a `buttons` block, an approval request rides the same portable-output path as any message: describe it once, render it natively, degrade it to text. There is no separate "approval rendering" subsystem.
3. **Native control where the surface can; a `/approve` text fallback everywhere.** Interactive cards/buttons on capable platforms (via the channel's `approvalCapability` slot or a terminal overlay); a chat `/approve` command as the universal floor. The runtime prompt is told to rely on native UI first and fall back to text.
4. **Core owns the approval lifecycle; the surface owns only presentation and transport.** Request filtering, routing, dedupe, expiry, and "this approval went to your DMs" reroute notices are core's. The surface maps the request to a native payload, delivers it, and reports the decision back.
5. **One decision vocabulary.** `allow-once | allow-always | deny | timeout | cancelled`, plus a declared `timeoutBehavior` (`allow` or `deny`) so an unanswered request resolves deterministically. `allow-always` writes a persisted permission rule; `allow-once` does not.
6. **The rich per-tool data travels as presentation content, not as a surface-coupled widget.** A file-edit diff becomes presentation blocks the classifier emits; it does *not* become a `FileEditPermissionRequest` component that only one renderer understands.

The producer describes the approval once; core guarantees a conservative text rendering for any surface that can't do better. Beautiful per-tool, per-surface approval cards are the thing to *not* build — see [Alternatives](#per-tool-permission-components-the-cautionary-tale).

---

## The classification / delivery split

This split is the whole architecture, so it's worth stating precisely who owns what.

| Concern | Owner | Example |
|---|---|---|
| *Whether* a call needs approval | [Tool System](../../core/tool-system/permissions.md) / [exec](../../backends/execution-environments/) | "this `bash` runs outside the sandbox" → needs approval |
| The *rich justification* data | classifier (same layer) | the exact command; a unified diff; a destructive-flag; a severity |
| Packaging that into a portable request | classifier → core | a `MessagePresentation` (title + description + diff blocks + buttons) |
| *How* it's asked on this surface | **Interface (this page)** | Slack interactive card / terminal overlay / `/approve` line |
| Collecting and routing the decision | **Interface + core** | button click or `/approve` → `allow-once`; core dedupes and applies |
| Lifecycle: expiry, reroute, dedupe | **core** | timeout after N seconds; "routed to your DMs" notice |

The reason the split is load-bearing: **the classifier has the data and the surface has the controls, and neither has the other's.** The exec layer knows a command is dangerous and can produce the diff; it has no idea whether the user is on Slack or a terminal. The Slack surface knows how to render a Block Kit card; it has no idea what makes *this* call dangerous. Force them together — one component that both decides danger and renders a card — and you can't reuse the classification across surfaces or the rendering across tools. Keep them apart and a single classified request renders everywhere, while a single surface renders every tool's approval. (This mirrors the exec-approval argument on [execution-environments](../../backends/execution-environments/): classify centrally, deliver per-surface.)

---

## Recommendation

### An approval is a `MessagePresentation`

The unlock that makes delivery portable is realizing an approval request needs nothing the message-presentation vocabulary doesn't already have. A request is: a title, a description, some rich context (a diff, a command block), and a set of choices. That maps directly onto the portable blocks:

```
approvalRequest = MessagePresentation {
  blocks: [
    { type: "text",    text: "Run command outside the sandbox?" },
    { type: "context", text: "rm -rf ./build  (destructive)" },
    { type: "buttons", buttons: [
        { id: "allow-once",   label: "Allow once" },
        { id: "allow-always", label: "Always allow", style: "primary" },
        { id: "deny",         label: "Deny",        style: "danger" },
    ]},
  ]
}
```

Because this is the *same* `MessagePresentation` an ordinary agent message uses, it flows through the *same* outbound path: the surface's `renderPresentation` maps it to a native card (Block Kit, an inline keyboard, an Adaptive Card, a terminal overlay with selectable buttons), and **core's text fallback** renders it conservatively when the surface can't — title as a line, the command inline, the choices listed as "`/approve` to allow, `/deny` to reject." No producer ever branches on surface type; no surface needs an approval-specific rendering path distinct from its message-rendering path.

This is why approval delivery can be portable while approval classification stays per-tool: the *classification* carries tool-specific richness, but it's expressed in a *surface-agnostic* presentation that every renderer already knows how to degrade.

### Native control, with a universal `/approve` fallback

Deliver the best control each surface affords:

- **Capable channels** (interactive buttons/cards): the channel's `approvalCapability` slot ([channels](./channels.md)) renders the native card and binds the buttons to decisions.
- **Terminal**: an overlay with selectable options ([tui](./tui.md)).
- **Headless / limited surfaces**: the text path — the request rendered as text plus a `/approve` (and `/deny`) command. This is the floor that must exist on *every* surface.

Two supporting rules:

- **Tell the runtime prompt to prefer native UI.** The model should assume an approval will be delivered as a native control and not narrate "type yes to continue" — the surface decides the affordance, and on a button surface a textual prompt is redundant and confusing.
- **`/approve` is always available**, even on rich surfaces, as the escape hatch when a card fails to render or a button doesn't fire. It's both the fallback for limited surfaces and the universal recovery path.

### Core owns the lifecycle; the surface owns presentation + transport

Keep the surface thin. The channel/terminal supplies only *target normalization* (where does this card go?) and *transport/presentation* (render it, send it, update it on resolution). Everything stateful is core's:

- **Request filtering and routing** — which pending request a given decision resolves; which surface/DM a request is delivered to.
- **Dedupe** — the same approval must not fire twice if a platform redelivers.
- **Expiry** — a request unanswered past its `timeoutMs` resolves per its `timeoutBehavior`.
- **Reroute notices** — when an approval is delivered somewhere other than the initiating chat (e.g. routed to the owner's DMs), core posts the "approval went to DMs" notice back to the origin, aggregating actual deliveries rather than letting each channel guess.

This keeps a new surface cheap: implement render + deliver + report-decision, inherit filtering/dedupe/expiry/reroute for free.

### One decision vocabulary

Normalize every surface's input to one set of outcomes:

- `allow-once` — permit this call only.
- `allow-always` — permit and **persist a permission rule** so future matching calls auto-approve (scope it: this exact command, this tool, this directory — the rule shape lives at the [Tool System](../../core/tool-system/permissions.md) layer).
- `deny` — reject this call; the model gets a tool error it can react to.
- `timeout` — no answer within `timeoutMs`; resolved by `timeoutBehavior` (`allow` or `deny`, declared per request — default `deny` for anything destructive).
- `cancelled` — the turn was cancelled out from under the request.

A surface collects a button click or a slash command and maps it to one of these; core applies it. `allow-always` is the only outcome with persistence, and it's why the decision is richer than a boolean — "yes" and "yes, and stop asking" are different facts.

### Rich data as content, not as a widget

The justification a user needs to decide — a unified diff for a file edit, the exact shell command, the URL for a fetch, the destructive-flag — is *valuable* and should be shown. The discipline is **where it lives**: the classifier emits it as presentation content (text/context blocks, a diff rendered into the presentation), not as a tool-and-surface-specific component. A file-edit approval is "a presentation containing a diff," which any surface renders as best it can (a terminal shows the colored diff; Slack shows a code block; a headless surface shows the patch as text). It is *not* a `FileEditPermissionRequest` widget that exists only in one renderer. Same richness, portable shape.

---

## Alternatives

### Per-tool permission components (the cautionary tale)

A single-surface harness can build a dedicated approval component per tool: a bash-permission view, a file-edit view with an inline syntax-highlighted diff, a web-fetch view, a notebook-edit view, a computer-use view — a dozen-plus bespoke components, plus a generic fallback component for everything unclassified.

**When this works:** when there is **exactly one surface** (an IDE-coupled terminal agent) and it will stay that way. The result is genuinely excellent: each approval shows precisely the right information in precisely the right shape, with affordances tuned per tool. For a single-surface product this is the *right* investment — richer than a portable presentation can be.

**Why it's the cautionary tale:** the approval shape is coupled to **both the tool and the surface**. `FileEditPermissionRequest` knows it's a file edit *and* knows it's rendering in this one renderer. The moment a second surface appears (the same agent over Slack), every component needs a rewrite, because none of them describe the approval *portably* — they render it directly. This is the exact coupling the classification/delivery split exists to prevent. Lift the *information* (show the diff, show the command) but express it as portable presentation content, so the richness survives the second surface.

### HITL middleware with a generic `ask_user`

The thin alternative: instead of per-tool components or an approval capability, expose one generic `ask_user` tool (text or multiple-choice questions) backed by a human-in-the-loop middleware that interrupts the run, surfaces the question, and resumes with the answer.

**When this works:** when you want minimal machinery and the framework already provides an interrupt/resume primitive. It's portable by construction (one tool, one rendering), trivial to implement, and doubles as a general clarification mechanism, not just approvals. A good fit for a harness that treats "ask the human" as one uniform capability.

**Why not as the default for approvals specifically:** it's lower-fidelity for the *approval* case. A generic question can't carry the structured `allow-once / allow-always` distinction, the persisted-rule semantics, the destructive-severity styling, or the timeout-behavior contract without bolting them on — at which point you're rebuilding the classified-request model anyway. It also routes approval through the model's tool loop rather than core's lifecycle, so dedupe/expiry/reroute aren't free. Use it for clarification questions; use the classified-request + capability-delivery model for tool approvals. The two can coexist — `ask_user` for "which approach do you want?", the approval path for "may I run this?".

---

## Anti-patterns

- **Coupling the approval shape to the tool *and* the surface.** Per-tool cards that exist in only one renderer can't deliver to a second surface without a rewrite. Classify per-tool (rich data), deliver per-surface (portable presentation), always with a text fallback.

- **No text fallback for rich approvals.** If a surface can't render buttons and core doesn't degrade, the user sees an un-actionable message and the turn stalls. Core must render conservative text + `/approve` from the same request.

- **A boolean decision.** "Approve? yes/no" loses `allow-always` and the persisted-rule it implies, so the user re-approves the same safe command forever. Use the full vocabulary; persist on `allow-always`.

- **Undefined timeout behavior.** An approval that hangs forever (or silently allows) on no answer is a correctness and safety bug. Declare `timeoutBehavior` per request; default destructive actions to `deny` on timeout.

- **Approval logic inside the surface.** A surface that decides *whether* something needs approval has absorbed classification it can't do consistently across surfaces. The surface only delivers and reports; classification is the Tool System / exec layer's.

- **The model narrating text prompts on a button surface.** "Type yes to continue" is redundant and confusing where a native card is delivered. Tell the runtime to assume native delivery and let the surface own the affordance.

- **Per-channel approval follow-up messages.** Channels each emitting their own "approval went elsewhere" notices produces duplicates and drift. Core owns reroute notices, aggregating actual deliveries before posting back to the origin.

- **Losing the rich justification in the name of portability.** Portability is not an excuse to show a bare "Approve tool call?" Carry the diff/command/URL as presentation content so every surface shows *why*, degrading gracefully rather than omitting.

---

## Cross-references

- [Interface README](./README.md) — § Rec 6–7 (classification vs delivery), the `MessagePresentation` vocabulary (`buttons` block), `presentationCapabilities`, core-owned text fallback.
- [Tool System permissions](../../core/tool-system/permissions.md) — where approval is *classified* and where persisted permission rules (`allow-always`) live.
- [Execution Environments](../../backends/execution-environments/) — the exec-approval argument this page's split mirrors.
- [channels.md](./channels.md) — the `approvalCapability` slot, native card delivery, and the `/approve` floor.
- [tui.md](./tui.md) — approval as a terminal overlay.
- [Extensibility](../../cross-cutting/extensibility/) — the `before_tool_call` `requireApproval` return and the `onResolution` decision callback (the plugin-driven approval path).
- [canvas.md](./canvas.md) — when an approval wants richer interactive UI than buttons (agent-hosted web UI).
