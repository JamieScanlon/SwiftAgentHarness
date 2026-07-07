# TUI (Terminal Surfaces) — Recommended Architecture

## TL;DR

The terminal is a [surface](./README.md) like any other — a client of the [Communication Layer](../../core/communication-layer/) that ingests input and renders output — but it is the surface with the most control and the least portability. It owns its own display, so it can repaint freely (it's the one surface that token-streams cheaply, per [streaming.md](./streaming.md)); and almost everything it does is terminal-specific, so none of its rendering or input machinery is reusable by other surfaces.

The prescriptive shape:

1. **Own the render loop with a differential renderer for a first-class TUI.** Compute the new frame, diff it against the last, and repaint only what changed — wrapped in synchronized-output markers so each frame swaps atomically with no flicker. A reconciler framework (the React-for-terminals style, or a Python TUI framework) is the right call when you want ecosystem velocity over frame-level control; a hand-written differential renderer is the right call when the TUI is a primary, performance-sensitive surface.
2. **Three rendering strategies.** (1) *first render* — emit all lines without clearing scrollback; (2) *width change or change above the viewport* — clear and full re-render; (3) *normal update* — move the cursor to the first changed line, clear to end, render only changed lines. This is the whole renderer.
3. **A minimal `Component` contract.** `render(width) → string[]` (one string per line, **each line no wider than `width`**), plus optional `handleInput(data)` and `invalidate()`. Reset styles (SGR) and hyperlinks (OSC 8) at the end of every line so styling never bleeds across lines.
4. **A `Focusable` extension for cursor and IME.** A focused component emits a zero-width cursor marker; the renderer positions the *hardware* terminal cursor there and shows it, so IME candidate windows (CJK input) appear in the right place. Containers must propagate focus to embedded inputs.
5. **Abstract the terminal behind an interface.** `write` / `moveBy` / `clearLine` / `clearScreen` / `columns` / `rows` behind a `Terminal` interface, with a real implementation over the process stdio and a virtual/headless one for tests. The renderer never touches `process.stdout` directly — this is what makes a TUI testable.
6. **The input composer is terminal-local and non-portable.** Editor, IME, bracketed paste, autocomplete for file paths and slash commands — none of it crosses to other surfaces. The portable artifact is the *inbound envelope* the composer produces, not the composer (see [README § input](./README.md) and [triggers/input-provenance](../triggers/)).
7. **A rich component vocabulary is a single-surface luxury.** A hundred-plus bespoke components (transcript lists, file-diff views, tool panes, mode dialogs) are affordable precisely *because* there is exactly one surface. This is the cost a multi-surface harness avoids by investing in portable [`MessagePresentation`](./README.md) instead — and the reason the two strategies diverge.

The terminal renderer, input composer, and component library all live entirely inside the surface plugin. The core emits one event stream; the TUI decides how to paint it. Nothing here is an inner-ring concern.

---

## Why the terminal is a distinct surface

Two facts make the terminal unlike every other surface, and they pull in opposite directions.

**It has maximum control.** The terminal is a raw character grid the surface owns outright. There's no platform rate limit on "edits," no Block Kit schema, no webview sandbox — just bytes and escape sequences. This is why the terminal sits at the top of the [streaming capability ladder](./streaming.md): it can repaint on every token essentially for free, so it *should* token-stream where channels can only block-stream.

**It has minimum portability.** Everything that control buys you is terminal-specific. A differential renderer, a synchronized-output frame, a fake cursor for IME, a Kitty-protocol inline image, a bracketed-paste handler — none of it means anything to Slack or a webview. So the terminal is exactly where the [interface README's](./README.md) "surface-native input, portable presentation" split earns its keep: the *rendering* is bespoke and stays in the plugin; the only thing that leaves the terminal is the inbound envelope (what the user typed, normalized) and the only thing that enters it is the conversation event stream (which the renderer paints however it likes).

The practical consequence: **invest in the terminal's renderer freely, but never let terminal concepts leak into the core or the portable presentation contract.** A core that knows about "panes" or "scrollback" has absorbed a surface detail it will regret when the second surface arrives.

---

## Recommendation

### Framework choice: own the loop, or rent a reconciler

The first decision is whether to control the render loop yourself or delegate to a UI framework. Three viable positions:

- **Hand-written differential renderer** — you compute frames and diff them. Maximum control over flicker, frame timing, and large-transcript performance; minimum dependency weight; but you write the renderer, the layout, and the components. **Recommended when the TUI is a primary, performance-sensitive surface** (a coding agent whose main interface is the terminal).
- **Reconciler framework (React-for-terminals style)** — declarative components, a familiar ecosystem, fast feature velocity. But the reconciler re-renders on each update and you inherit its flicker model and its per-frame cost; large transcripts and high token-rates are where it strains. **Recommended when development velocity and component reuse matter more than frame control**, and the transcript sizes stay modest.
- **Established TUI framework (Python-TUI style)** — a batteries-included widget toolkit. Good when the harness is already in that language and wants layout/widgets for free; same reconciler-style trade-off on frame control.

The recommendation is not "always hand-write." It's: **match the renderer to how central the terminal is.** If the terminal is *the* product, own the loop — the control pays for the code. If the terminal is one surface among several and you'd rather spend effort on portable presentation, a reconciler framework is the rational rent.

### Differential rendering — the core of a hand-written renderer

If you own the loop, the renderer is small and the strategy is fixed. Maintain the last rendered frame; on each update, pick one of three strategies:

1. **First render.** Output all lines *without* clearing scrollback — the conversation so far stays in the user's history where they can scroll to it.
2. **Width change, or a change above the viewport.** Clear the screen and full re-render. (A reflow or an edit to already-scrolled content can't be patched incrementally; repaint.)
3. **Normal update.** Move the cursor to the first changed line, clear to end, render only the changed lines. This is the hot path and the reason the renderer is cheap — a streaming token touches one or two lines, not the whole screen.

Wrap **every** update in **synchronized output** (`\x1b[?2026h` … `\x1b[?2026l`) so the terminal composites the whole frame and swaps it atomically. Without this, a fast repaint tears — the user sees half-drawn frames. With it, even token-rate updates are flicker-free. Synchronized output plus "repaint only changed lines" is the entire trick to a smooth terminal; there is no third ingredient.

### The `Component` contract

Keep the component interface minimal — three methods:

```ts
interface Component {
  render(width: number): string[]   // one string per line; each line ≤ width
  handleInput?(data: string): void   // raw terminal input when focused (may carry ANSI)
  invalidate?(): void                // drop cached render state; re-render next frame
}
```

Two invariants make the renderer's life simple and must be enforced:

- **Each returned line must not exceed `width`.** The renderer trusts this to place lines; a too-wide line corrupts the frame. Provide width-aware helpers (visible-width measurement that ignores ANSI, truncate-to-width, ANSI-aware wrapping) and error loudly if a component violates the bound.
- **Styles never carry across lines.** Append a full style reset (SGR) and a hyperlink reset (OSC 8) at the end of *every* rendered line, and reapply per line for multi-line styled text. Terminal styling is stateful; without per-line resets, one component's color bleeds into the next.

`invalidate()` exists for caching (below). `handleInput()` is only called on the focused component.

### Focus and IME

Text input needs a visible cursor *and* correct IME positioning, which the renderer can't infer from text alone. Add a `Focusable` extension:

- A focused component emits a **zero-width cursor marker** (an APC escape the terminal ignores visually) at the cursor position inside its rendered output.
- The renderer scans the frame for the marker, positions the **hardware** terminal cursor there, and shows it. The component draws its own *fake* cursor styling (reverse video) for the visual; the hardware cursor is what the OS uses to anchor the IME candidate window.
- This matters for CJK (Chinese/Japanese/Korean) and other IME input: without a correctly-placed hardware cursor, the candidate window appears in the wrong place. **Container components must propagate focus to their embedded input child** — a dialog that wraps an input has to forward `focused` down, or IME breaks inside dialogs.

The reverse-video fake cursor handles the common case; the hardware-cursor positioning is what makes international input correct. Both are needed.

### Abstract the terminal for testability

The renderer should talk to a `Terminal` interface, not `process.stdout`:

```ts
interface Terminal {
  start(onInput, onResize): void; stop(): void
  write(data: string): void
  get columns(): number; get rows(): number
  moveBy(lines): void; hideCursor(): void; showCursor(): void
  clearLine(): void; clearFromCursor(): void; clearScreen(): void
}
```

Ship two implementations: a **process terminal** over real stdio, and a **virtual/headless terminal** (backed by a headless terminal emulator) for tests. This is the single highest-leverage testability decision for a TUI — it lets you assert on rendered frames in CI without a real TTY, which is otherwise nearly impossible to test. The renderer, layout, and components all become unit-testable because none of them reach for the real terminal.

### Performance: caching and large transcripts

Two performance concerns dominate a terminal surface:

- **Per-component render caching.** A component caches its `render(width)` output keyed on width and re-renders only when its inputs change or `invalidate()` is called. Most components don't change most frames; caching keeps the normal-update path touching only the lines that actually moved.
- **Large-transcript virtualization.** A long conversation has thousands of lines; rendering them all every frame is wasteful. Virtualize the transcript — render only the visible window plus a small margin — so cost scales with the viewport, not the history. This is the terminal analogue of any virtualized list and is essential once sessions get long.

The hand-written renderer's advantage shows up exactly here: you control what re-renders, so a streaming token at the bottom of a 10,000-line transcript repaints two lines, not ten thousand.

### The input composer is terminal-local

The composer — editor with multi-line editing, IME, bracketed paste (with explicit markers for large >10-line pastes so they aren't interpreted as typed input), autocomplete for file paths and slash commands — is rich, valuable, and **entirely non-portable**. None of it crosses to another surface.

State the boundary clearly: the composer's *job* is to produce a normalized **inbound envelope** (text, attachments, provenance), and that envelope is the portable artifact. The keystrokes, the paste handling, the autocomplete popups are surface-local implementation. A different surface (a chat channel, a webview) produces the same envelope shape through completely different input machinery. Don't try to share composer code across surfaces; share the envelope contract. (See [triggers/input-provenance](../triggers/) for the envelope's trust fields.)

### Overlays, inline images, multi-pane

The control the terminal affords lets a TUI host genuinely rich UI:

- **Overlays** — modal components drawn on top of existing content (dialogs, menus, pickers) with anchor- or percentage-based positioning and focus management. The renderer composites them above the base frame.
- **Inline images** — real images via terminal graphics protocols (Kitty, iTerm2) where supported, with a text-placeholder fallback elsewhere. This is the terminal's version of rich media; richer agent-authored UI belongs on a webview surface ([canvas.md](./canvas.md)).
- **Multi-pane layout** — chat + file-diff + tool-output panes, resizable, with focus moving between them.

All of this is legitimate and worth building for a primary TUI — but all of it is surface-local. It is *not* a model for what other surfaces can render, and it must not shape the portable presentation contract.

### Rich component vocabulary is a single-surface luxury

A mature TUI accumulates a large bespoke component library — virtualized message lists, file-edit diff views, tool-specific renderers, plan/mode dialogs, status lines — easily a hundred-plus components. This is **affordable precisely because there is exactly one surface to render them on.** Every component targets the terminal and only the terminal.

This is the fork in the road the [interface README](./README.md) is built around. A single-surface harness pours effort into a rich terminal component vocabulary and wins a great TUI. A multi-surface harness *cannot* — it would have to reimplement every component for Slack, for a webview, for each channel — so it invests instead in **portable `MessagePresentation`** with a core-owned text fallback, accepting a less lavish terminal in exchange for every surface rendering acceptably from one contract. Neither is wrong; they're the two coherent answers to "how many surfaces am I really building for?" Know which one you're choosing before the component count makes it for you.

---

## Alternatives

### Reconciler framework (React-for-terminals style)

Build the TUI as declarative components reconciled to terminal output by a framework that re-renders on each update.

**When this works:** when feature velocity and a familiar component model matter more than frame-level control, and transcripts stay modest. The ecosystem (layout engine, component libraries, hooks) is real leverage, and a large, polished component vocabulary is genuinely productive to build this way.

**Why not as the default for a performance-critical TUI:** the reconciler re-renders on each token, and you inherit its flicker model and per-frame cost. At high token-rates and large transcripts this strains — the very hot path where a hand-written differential renderer (repaint changed lines only, synchronized output) is built to win. You also can't easily reach below the framework to fix a frame-timing problem. Great for velocity; constraining at the performance ceiling.

### Established TUI framework (Python-TUI style)

Use a batteries-included terminal widget toolkit in the harness's own language.

**When this works:** when the harness is already in that language and wants layout, widgets, and event handling for free. Same declarative-reconciler trade-off as above; a fast way to a competent TUI without writing a renderer.

**Why not as the default:** same ceiling on frame control, plus you're bound to the toolkit's widget model and release cadence. Fine when the terminal is one surface among several rather than the marquee one.

### Dual-frontend behind one protocol

Decouple the renderer entirely: define a `BackendEvent` / `FrontendRequest` protocol and let *multiple* frontends implement it — e.g. a reconciler-based terminal frontend launched out-of-process and a native TUI-framework app, both speaking the same protocol to one backend.

**When this works:** when you genuinely want two terminal frontends (say, a rich out-of-process one and a lightweight fallback) and are willing to freeze a protocol between backend and frontend. The protocol *is* the surface contract, frozen enough that two different rendering stacks implement it — a clean design when the requirement is real.

**Why not as the default:** it's the same protocol-decoupling the [Communication Layer](../../core/communication-layer/) already provides at the conversation level, re-created one layer down. For a single terminal frontend it's pure overhead — a protocol boundary with one implementer. Reach for it only when two frontends actually exist; otherwise let the Comm-Layer event stream be the boundary and render directly.

---

## Anti-patterns

- **Full-screen repaint every frame.** Repainting the whole screen on each token tears and flickers and wastes cycles. Diff against the last frame and repaint only changed lines; wrap updates in synchronized output for atomic swaps.

- **Skipping synchronized output.** Even a correct line-diff renderer tears without atomic frame swaps on fast updates. The `\x1b[?2026h … \x1b[?2026l` wrap is cheap and non-optional for a smooth TUI.

- **Components that exceed the width bound.** A `render(width)` that returns a too-wide line corrupts the frame and the renderer's line accounting. Enforce the bound with width-aware truncation/wrapping and fail loudly on violation.

- **Styles bleeding across lines.** Terminal styling is stateful; without a per-line SGR + OSC 8 reset, one component's color or hyperlink leaks into the next. Reset at the end of every line.

- **Rendering straight to `process.stdout`.** A renderer wired directly to real stdio can't be tested without a TTY. Put a `Terminal` interface in front, with a headless implementation for CI.

- **Forgetting hardware-cursor positioning for IME.** Drawing only a fake (reverse-video) cursor leaves CJK candidate windows mispositioned. Emit a cursor marker, place the hardware cursor on it, and propagate focus into container-embedded inputs.

- **Rendering the whole transcript every frame.** Cost grows with history instead of the viewport, and long sessions crawl. Virtualize: render the visible window plus a margin; cache per-component output keyed on width.

- **Treating bracketed paste as typed input.** A large multi-line paste interpreted keystroke-by-keystroke triggers autocompletes, submits, and chaos. Handle bracketed paste explicitly, with markers for large pastes.

- **Leaking terminal concepts into the core or portable presentation.** Panes, scrollback, cursor markers, graphics protocols are surface-local. A core or a `MessagePresentation` contract that knows about them has absorbed a detail no other surface shares. Keep terminal rendering inside the surface plugin.

- **Sharing composer code across surfaces.** The terminal composer is non-portable; trying to reuse it for a channel or webview fails because the input models are unrelated. Share the *inbound envelope* contract, not the composer.

---

## Cross-references

- [Interface README](./README.md) — the surface contract, surface-native input vs portable presentation, the single-surface-vs-multi-surface fork this page's "component vocabulary" section turns on.
- [streaming.md](./streaming.md) — the terminal is the top rung of the streaming ladder; token-delta rendering belongs here, done differentially.
- [Communication Layer](../../core/communication-layer/) — the conversation event stream the renderer paints; the protocol boundary the dual-frontend alternative re-creates.
- [canvas.md](./canvas.md) — when rich UI outgrows the terminal (agent-authored web UI on a webview surface).
- [approval-ux.md](./approval-ux.md) — approval dialogs rendered as terminal overlays.
- [triggers/input-provenance](../triggers/) — the inbound envelope and its trust fields, the portable artifact the composer produces.
