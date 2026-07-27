# TUI — the terminal surface

The terminal is the surface with **the most control and the least portability**. It owns a
raw character grid, so it repaints freely and sits at the top of the
[streaming ladder](../Streaming/) — it token-streams where a channel can only block-stream.
Everything that control buys is terminal-specific: a differential renderer, a
synchronized-output frame, a cursor marker for IME, a Kitty graphics escape. None of it
means anything to Slack.

So: **invest in the renderer freely, but let nothing terminal-shaped leak out.** The only
things crossing the boundary are the inbound envelope (`ComposerSubmission`) and the
conversation event stream.

## Wiring a client

```swift
let terminal = ProcessTerminal()
guard ProcessTerminal.unavailabilityReason == nil else { /* not a tty, or not macOS */ }

let app = TUIApp(terminal: terminal)
await app.setHost(RuntimeTUIHost(
    session: agentRuntimeSessionService,
    conversationID: conversationID,
    ownerAccountID: conversation.ownerAccountID,
    onQuitRequested: { await app.stop(); exit(0) }
))
await app.registerSurface(conversationID: conversationID)   // rich message-tool output
await app.setFileCompletionRoot(workspaceRoot)              // optional: @-completion
await app.start()
```

Out of process, swap the host — `ClosureTUIAppHost` has zero coupling to any runtime type:

```swift
await app.setHost(ClosureTUIAppHost(
    submit: { try await transport.send($0) },
    cancelTurn: { await transport.cancelRun() },
    quit: { await shutdown() },
    resolveApproval: { id, action in await transport.resolveExecApproval(id, action) },
    slashCommandRegistry: { await transport.conversationScopedRegistry() }
))
```

Attach the event stream per conversation:

```swift
let streaming = TUIRunStreamingService(hub: conversationEventsTopicHub)
await streaming.attach(conversationID: conversationID, app: app)
defer { await streaming.detach(conversationID: conversationID) }
```

### Host rules

- **Send raw composer text.** The control-input boundary runs inside the send path with
  the conversation-scoped registry and real authorization. Classifying first duplicates it
  with weaker authorization. See [the interface README](../README.md#control-input).
- **`registerSurface` is explicit and reversible.** `MessageOutputDeliveryRegistry` is
  process-global and holds the deliverer — and therefore the app — until released. `stop()`
  unregisters.
- **Don't retain the app from the host** unless you call `stop()`; `TUIApp` holds its host
  strongly, because a weak host silently deallocates when built inline and turns every
  submission into a no-op with no diagnostic.

## Architecture

```
Terminal/      Terminal protocol; ProcessTerminal (stdio) and VirtualTerminal (headless)
Render/        DifferentialRenderer, Component contract, Focusable, CachingComponent
Text/          ANSI width/truncate/wrap/style, CursorMarker, TUITextSanitizer
Layout/        Stack, Split, Box, OverlayHost
Composer/      InputComposer, bracketed paste, autocomplete, ComposerSubmission
Components/    Transcript, MessageView, dialogs, status line, presentation rendering
Images/        Kitty / iTerm2 inline image protocols
Runtime/       TUIApp, TUIAppHost, TUIKey decoder, streaming attach, surface plugin
```

### The renderer

Three strategies, and that is the whole thing: **first render** (emit lines without
clearing scrollback), **width change or a change above the viewport** (clear and repaint),
**normal update** (move to the first changed line, clear to end, write only what changed).
Every update is wrapped in synchronized output (`CSI ?2026h … l`) so frames swap atomically.

Two details that are easy to get wrong and were:

- Downward cursor movement uses newlines, not `CSI B`. `CSI B` clamps at the bottom margin
  and cannot scroll, so a frame growing while anchored to the bottom overwrites its own
  last line.
- Lines are separated by `\r\n`. Raw mode clears `OPOST` (and with it `ONLCR`), so a bare
  LF moves down without returning to column 0 and the whole frame staircases.

### The `Component` contract

`render(width) -> [String]`, one string per line, **each line no wider than `width`**, plus
optional `handleInput` and `invalidate`. The width bound is enforced by
`TUIComponentRender` with a `preconditionFailure` — a violation corrupts the renderer's
line accounting, and failing loudly beats a garbled screen. Because that trap aborts the
process with the tty still in raw mode, `WidthInvariantTests` renders every component at
every width from 1 to 80, plus 100/120/160/200; **keep that test green**.

Containers use `TUIComponentRender.renderClamped`, which truncates an over-wide child
rather than trapping: a container owns its children's geometry, so absorbing the error is
strictly better than killing the process.

### Testability

`VirtualTerminal` is a headless emulator and the oracle every renderer test asserts
against. It deliberately reproduces real-TTY behaviour under the modes `ProcessTerminal`
sets — `LF` does not imply a carriage return, `ESC[J` erases to end of *display*, writing
past the last column wraps, wide characters occupy two cells. Fidelity here is not
pedantry: an emulator that is kinder than a real terminal certifies bugs instead of
catching them.

### Input

`TUIKeyDecoder` turns raw bytes into ordered `TUIKey` values, holding incomplete escape
sequences across reads. Note that one `read()` routinely carries several keystrokes, so
comparing a whole buffer against `"\r"` is not a substitute for decoding — fast typing
produces `"abc\r"`.

Input is drained by **one serial consumer**. A task per read gives up ordering between
reads, which transposes characters on a fast paste and can deliver Enter before the text
it was meant to submit. Turn consumption runs on its own task so the input loop keeps
draining — otherwise no keystroke is decoded while the model streams, including the Ctrl-C
meant to cancel it.

Raw mode clears `ISIG`, so **Ctrl-C arrives as a byte, not a signal** — it is the only quit
path the user has. `ProcessTerminal` installs `atexit` and signal handlers so a crash never
leaves the shell in raw mode.

### Composer

Multi-line editing, IME-correct cursor placement, bracketed paste, autocomplete. All
terminal-local and non-portable; the portable artifact is `ComposerSubmission`.

Large pastes collapse to a `[Pasted N lines]` placeholder in the buffer and expand in full
at submission, so the composer viewport stays usable without losing a byte. Paste
provenance is sticky until `clear()` — it describes the submission, and it feeds the
control-input trust decision.

Autocomplete has two triggers: `/` as the first token of the first line (slash commands),
and `@` at a word start (workspace files, off until a host calls
`setFileCompletionRoot`). `FilePathCompleter` is confined to its root by default.

### Approvals

`ApprovalPresentation` renders as a modal overlay. Overlays capture input unconditionally,
decisions are collected synchronously via `takeDecision()`, and the decision is reported
through `ExecApprovalInbound.resolve`. **Dismissing an approval — Esc or Ctrl-C — resolves
it as a denial**, because silently dropping the modal leaves the runtime blocked on an
approval the user believes they closed.

### Inline images

Kitty and iTerm2 graphics protocols, detected from `$TERM` / `$TERM_PROGRAM` /
`$KITTY_WINDOW_ID`, with a text placeholder everywhere else. Detection is conservative:
Apple Terminal exports `TERM_PROGRAM` but does not display images, so it gets the
placeholder.

## Mapping to the template

Implements [`harness-template/surfaces/interface/tui.md`](../../../../../harness-template/surfaces/interface/tui.md).
Known deviations:

- **`select` blocks are not rendered natively** — no interactive widget in the transcript;
  they degrade to a bulleted list.
- **`ProcessTerminal` is macOS-only.** The package declares Apple platforms, so a Linux
  implementation could not be compiled or tested here. `unavailabilityReason` reports
  `.unsupportedPlatform` rather than handing back a silently dead terminal.
- **No executable demo target yet.** Tracked separately.

## API notes

- `TUIApp.consume(partials:orchestration:final:)` is **deprecated**: it takes the final
  payload up front, so it cannot be driven from a live event stream. Use
  `consume(_ response:)` or `TUIRunStreamingService`.
- `TUIApp.start()` is `async`.
- `AutocompleteSource` was replaced by `AutocompleteKind`; the old enum carried a registry
  or path array that never fit how completion is actually driven, and had no callers.
- `Focusable` is class-constrained (`AnyObject`) so containers can propagate focus through
  an existential.
- `RenderStrategy` gained a `.noChange` case.
