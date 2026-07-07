# Canvas (Agent-Driven UI) — Recommended Architecture

## TL;DR

Some surfaces can host a webview, which lets the agent render *arbitrary interactive UI* back to the user — a chart, a form, a small app — instead of only text and buttons. This page goes deeper than the [interface README](./README.md) (§ Rec 8) on how to host that safely.

The prescriptive shape:

1. **"Render UI" is a Tool-System tool, not a side channel.** The capability is advertised to the model and dispatched through the [Tool System](../../core/tool-system/) like any other tool, consistent with the [tool-call-vs-context-resource framing](../../core/). It is not a bespoke back door the model reaches through some private API.
2. **The webview is sandboxed and content-addressed to a session.** Agent-authored HTML/CSS/JS lives under a **session-scoped directory** and is served through a **custom URL scheme** (`canvas://<session>/<path>`) — no loopback HTTP server for local content. Directory traversal is blocked; files must live under the session root.
3. **A small agent API over the existing wire.** present / hide, navigate (local path, `http(s)`, or `file://`), eval JS, snapshot — exposed over the [Gateway WebSocket](../../core/communication-layer/), the same control plane every other capability uses.
4. **Declarative UI push beats a raw diff-renderer for interactive surfaces.** Host a declarative agent-to-UI protocol (A2UI-style: `beginRendering` / `surfaceUpdate` / `dataModelUpdate` / `deleteSurface`) so the agent describes *what the UI should be* and the host reconciles it, rather than the agent imperatively diffing DOM.
5. **The UI→agent return path is confirmation-gated, untrusted input.** A deep link (`agent://?message=…`) that lets the canvas start an agent run is a privileged action initiated by *rendered, possibly-model-authored content* — gate it behind explicit confirmation (or a valid key), and treat anything it carries as untrusted inbound ([input-provenance](../triggers/)).
6. **Capability-gated, with graceful fallback.** Agent-driven UI is one optional [surface slot](./README.md); only surfaces that can host a webview advertise it. Everywhere else, the same intent degrades — to a static artifact, a link, or text.

A webview that can read arbitrary files or trigger agent runs without confirmation is an injection surface. The whole design is "expose rich UI as a normal tool, then confine the webview hard."

---

## Where this fits

Agent-driven UI is the richest rung of output: beyond text ([streaming](./streaming.md)) and beyond buttons ([approval-ux](./approval-ux.md)), it's *arbitrary interactive UI*. But it's available on almost no surfaces — a terminal can't host a webview, a messaging channel can't, only a desktop app or a browser-backed surface can. So it is emphatically a **per-surface capability**, declared by the surfaces that can do it and absent everywhere else, exactly as the [capability-record surface model](./README.md) intends.

Two framings keep it from becoming a special case:

- **It's a tool, not a new architectural plane.** The model already produces output through the Tool System and the shared output path. "Render this UI" is one more tool capability advertised to the model — dispatched, approved, and audited like any other tool call. This is what keeps agent UI consistent with the rest of the harness instead of a parallel rendering stack the core has to special-case.
- **It's a sandbox problem first.** The moment the agent can author HTML/JS that runs in a webview with any access to the local machine or the agent loop, you have an injection surface — the same concern the [execution-environments](../../backends/execution-environments/) page treats for code. The recommendations below are mostly about confinement.

---

## Recommendation

### Render-UI as a Tool-System tool

Expose agent-driven UI as a capability the model invokes through the [Tool System](../../core/tool-system/), not as a private side channel. Concretely: the "render UI" / "push to canvas" operation is a tool with a schema, advertised to the model only on surfaces that host a webview, dispatched and recorded like any other tool call.

Why this matters beyond tidiness:

- **It inherits the tool machinery for free** — approval classification, audit/observability, the permission model. A UI push that loads remote content or triggers side effects can be gated by the same [approval](./approval-ux.md) path as any sensitive tool.
- **It stays consistent with the tool-call-vs-context-resource split.** Rendering UI is something the model *invokes* (a tool call), not something it *consumes* (a context resource). Modeling it as a tool keeps that boundary clean; a bespoke "the model can also secretly draw UI" channel muddies it.
- **The model's vocabulary doesn't fork.** As with the [one shared output tool](./README.md), the agent gains UI as a capability, not as a per-surface API it has to know the shape of.

### The webview sandbox

This is the load-bearing safety work. Agent-authored content is untrusted by construction — the model wrote it, possibly influenced by untrusted input — so the webview that runs it must be confined:

- **Session-scoped content directory.** Each session gets its own canvas root (e.g. `…/canvas/<session>/…`, alongside the session's other [persisted](../../backends/persistence/) state). The agent writes files there; nothing outside it is reachable.
- **A custom URL scheme, not a loopback server.** Serve local content through a custom scheme (`canvas://<session>/<path>` → `<canvasRoot>/<session>/<path>`), so there's no localhost HTTP server to find, port-scan, or reach from other processes. The scheme handler is the single chokepoint where every load is authorized.
- **Block directory traversal; confine to the session root.** The scheme handler rejects `..` and any resolved path that escapes the session root. This is the one rule that, if missed, turns the canvas into an arbitrary-file-read primitive.
- **External `http(s)` only on explicit navigation.** Local content is the default; loading remote URLs happens only when the agent explicitly navigates there, never implicitly.
- **A hard disable switch.** Canvas is an optional capability the operator can turn off entirely; when off, canvas tool calls return a clear "disabled" result rather than silently doing nothing.

The mental model: the webview is a [sandbox](../../backends/execution-environments/) for *rendering*, and the custom scheme is its only door. Everything the canvas can load passes through the scheme handler, which authorizes against the session root.

### The agent API surface

Keep the agent's control of the canvas small and route it over the **existing** [Gateway WebSocket](../../core/communication-layer/) control plane — not a new transport:

- **present / hide** — show or dismiss the panel.
- **navigate** — to a local canvas path, an `http(s)` URL, or a `file://` URL (subject to the sandbox rules above).
- **eval JS** — run script in the canvas context (powerful; treat as privileged).
- **snapshot** — capture an image of the current canvas, so the agent can *see* what it rendered and reason about it (closing the loop for a model that can't otherwise observe its own UI).

`snapshot` is the quietly important one: it lets the agent verify its own output, the visual analogue of reading a tool result. Without it, the agent renders blind.

### Declarative UI push over a raw diff-renderer

Two ways the agent can drive what's on screen:

- **Declarative push (recommended).** The agent describes the UI as a tree of components and data, and a host reconciles the screen to match — a protocol like A2UI with `beginRendering`, `surfaceUpdate`, `dataModelUpdate`, `deleteSurface` over the canvas host. The agent says *what the UI is*; the host figures out the DOM.
- **Imperative diff-rendering.** The agent emits DOM/HTML diffs the webview applies directly.

Prefer the declarative protocol for genuinely *interactive* surfaces. It separates the data model from the view (so updates are data-shaped, not DOM-shaped), it constrains the agent to a known component vocabulary (a smaller attack surface than arbitrary script), and it lets the host own reconciliation and lifecycle (`deleteSurface` cleans up; `dataModelUpdate` re-renders without a full rebuild). Raw HTML/JS is the right tool for a *static* artifact (below); a live, stateful surface wants the declarative model.

### The UI→agent return path is confirmation-gated

The canvas can be two-way: a rendered button can fire a deep link (`agent://?message=…`) that starts a new agent run. This is genuinely useful — the user clicks "Refine this design" and the agent picks it up — but it is the **highest-risk** part of the feature, because the trigger originates in *rendered content the model may have authored*, possibly influenced by untrusted input. So:

- **Gate every UI→agent trigger behind explicit user confirmation** (or a valid pre-shared key for trusted automation). A canvas must not be able to silently drive the agent loop.
- **Treat the deep link's payload as untrusted inbound**, classified through the same [provenance machinery](../triggers/) as any channel message — never as an operator instruction.

The asymmetry is the point: agent→UI (rendering) is low-risk and can be fluid; UI→agent (triggering runs) is high-risk and must be gated. Don't let the convenience of the return path erode the confirmation gate.

### Capability-gated, with graceful fallback

Agent-driven UI is one optional surface slot. Only surfaces that can host a webview advertise it; the model is offered the capability only there. Everywhere else, the *same intent* degrades down the output ladder:

- a static rendered artifact (a link to an HTML file) where there's no live webview,
- a [`MessagePresentation`](./README.md) (buttons/select) where there's structured-but-not-arbitrary UI,
- plain text as the floor.

The producer expresses "I want to show the user this"; the surface renders the richest form it can. A model that *assumes* a canvas exists and breaks on a terminal has violated the capability-gating contract.

---

## Alternatives

### Static artifact server (the lightweight version)

Instead of a live, two-way canvas, render the agent's output as a **static HTML artifact** served from a simple server (or a file), with no agent API, no push protocol, and no return path.

**When this works:** when you want "the agent can produce a rich visual" without the cost and risk of a live surface — a generated report, a chart, a one-off mini-page the user opens and reads. It's dramatically simpler: write a file, hand back a link, done. No webview control API, no deep links, far less attack surface.

**Why not as the ceiling:** it's render-once and one-way. The agent can't update it in place, can't read back interaction, can't host a stateful form. For *interactive* UI you need the live canvas. But the static artifact is the right **default** and the right fallback — most "show me a visual" needs are satisfied by it, and it's where surfaces without a live canvas land. Build the static path first; add the live canvas only where two-way interactivity earns its risk.

### Bespoke native UI per app

Have each host app implement custom native UI for agent output (native panels, platform widgets) instead of a webview hosting portable content.

**When this works:** a single first-party app that wants pixel-perfect native UI and will maintain it.

**Why not as the default:** it's per-app and non-portable — every host re-implements every UI, and the agent has to target each one. A webview hosting a declarative protocol gives one agent-facing contract that any webview-capable surface can render, which is the whole point of treating agent UI as a portable capability rather than a per-host feature.

---

## Anti-patterns

- **Agent-driven UI as an unsandboxed side channel.** A webview that reads arbitrary files or runs with ambient local access is an injection surface. Confine content to the session root, block traversal, serve via a custom scheme, and dispatch "render UI" through the Tool System.

- **A UI→agent trigger with no confirmation.** A deep link that starts an agent run from rendered (model-authored) content is a self-driving-loop and prompt-injection risk. Gate it behind explicit confirmation or a valid key; treat its payload as untrusted.

- **A loopback HTTP server for local canvas content.** A localhost server is discoverable and reachable by other local processes. A custom URL scheme with a single authorizing handler is the tighter boundary for local content.

- **Imperative DOM diffs for a stateful surface.** Raw HTML/JS for a live interactive surface is a large attack surface and couples the agent to DOM mechanics. Use a declarative component protocol that separates data from view and constrains the vocabulary.

- **Assuming a canvas everywhere.** Agent-driven UI exists on almost no surfaces. A model or producer that assumes a webview breaks on terminals and channels. Capability-gate it; degrade to static artifact / presentation / text.

- **A bespoke transport for the canvas.** Inventing a separate socket for canvas control duplicates the control plane. Route present/navigate/eval/snapshot over the existing Gateway WebSocket.

- **No way to disable it.** Agent-authored UI is a meaningful trust grant; an operator must be able to turn it off entirely, with canvas calls returning a clear disabled result.

---

## Cross-references

- [Interface README](./README.md) — § Rec 8 (agent-driven UI as a Tool-System capability), the capability-record surface model, the output ladder this sits atop.
- [Tool System](../../core/tool-system/) — where "render UI" is dispatched, approved, and audited like any tool.
- [Core](../../core/) — the tool-call-vs-context-resource framing that makes rendering UI a *tool call*, not a context resource.
- [Execution Environments](../../backends/execution-environments/) — the sandbox discipline the webview confinement mirrors.
- [Communication Layer](../../core/communication-layer/) — the Gateway WebSocket the agent API rides.
- [Persistence](../../backends/persistence/) — the session-scoped directory canvas content lives in.
- [approval-ux.md](./approval-ux.md) — gating sensitive canvas actions; the structured-UI rung below arbitrary UI.
- [Triggers / input-provenance](../triggers/) — classifying UI→agent deep-link payloads as untrusted inbound.
