# Computer Use

## TL;DR

**Computer use is a control channel of last resort, built as a family of display targets behind one canonical observation/action contract.** The agent sees a screen (pixels, an accessibility tree, a DOM) and drives it (pointer, keyboard, semantic element actions). The harness owns everything around that loop: routing to a cheaper channel when one exists, normalizing coordinates, binding actions to observations, gating every action, keeping screenshots from eating the context window, and letting a human watch, take over, or stop it instantly.

By late 2026 the model side has largely converged. Every major vendor folds computer use into its general models as a client-side tool rather than shipping a separate model. Frontier scores on short desktop tasks are ~85–90% on the verified desktop benchmark, above the historic human baseline. On long-horizon professional workflows, completion is still ~20%. The failures there are cognitive rather than motor: lost constraints, skipped verification, guessing instead of asking. Prompt injection through on-screen content is the dominant risk, and no vendor claims it is solved. A harness should therefore treat computer use as **capable but supervised**.

The prescriptive shape:

1. **Route before you click.** Use the control ladder: API/MCP → CLI or OS scripting → structured UI (DOM or accessibility refs) → pixels. Pixels are the fallback for apps that offer nothing better.
2. **Display targets are an execution-environment family.** Host desktop, local VM, remote desktop container, managed browser, paired device. Each sits behind one `DisplayTarget` contract that declares its perception modes, delivery modes, and isolation level.
3. **One canonical action model and one coordinate space** (logical points on the target), with a codec per model dialect. Vendor toolsets differ: screenshot pixels for two vendors, a normalized 0–999 grid for a third, and model-native grids for open grounders. The harness rescales, records the geometry of every screenshot it sends, and freezes the coordinate mode for the session.
4. **Observations are receipts and actions cite them.** An action names the observation it was planned against and is refused if the target drifted. Every outcome reports evidence (`confirmed | unverifiable | suspected-noop | partial | refused | not-executed`). An action that may already have been delivered is never auto-retried.
5. **A computer-use session is a lease.** It has a single controller per target, scoped grants (per-app or per-domain allowlists with view / click / full tiers), budgets, an injection-proof kill switch, and guaranteed cleanup. The step budget is a first allotment that grows while the harness measures progress, up to a host ceiling. Time limits belong to the host, a session that stops making progress ends early, and cost is never extended.
6. **Safety is layered, not a single gate.** Isolation by default, then scoped grants, per-action risk classification, an intent-alignment check per action, confirmation for consequential actions (honoring vendor safety signals), takeover mode for credentials, and the harness's own UI excluded from capture.
7. **Screenshots are a bounded, cache-aware resource.** Resize harness-side to the model's limits, because at least one vendor now rejects oversized images instead of downscaling them. Keep the last few and prune in batches to protect the prompt cache. Prefer text observations when they suffice.
8. **Use a computer-use specialist sub-agent by default for long tasks.** It gets its own model, its own bounded screenshot context, and narrower tool authority. It returns a structured result, so injected screen content never sits in the parent's context with the parent's permissions.
9. **Verification, ask-user, and handoff are first-class tools, not afterthoughts.** The computer-use tool family includes `verify`, `ask_user`, and `handoff` alongside the display actions, and the harness enforces checkpoints before irreversible steps.

Platform implementation for macOS (capture, accessibility, input, TCC permissions, VMs) is in [`./macos.md`](./macos.md).

---

## How this fits the architecture

Computer use is not one layer's concern. It is a backend family plus a tool family, with obligations on five other layers:

| Concern | Owner | Why |
|---|---|---|
| Screen capture, accessibility/DOM snapshots, input injection, target lifecycle | **Display-target backend** (this page) | Platform-specific drivers behind one contract, as with sandbox backends |
| Where targets run (VM, container, host), registry, observer-access auth | [Execution Environments](../execution-environments/) | Display targets register in the same backend registry and reuse its lifecycle, pruning, and observer-token machinery. Their observe/act contract is defined here, as a sibling of `SandboxBackendHandle`, not an extension of it. |
| The model-facing tool family, per-action permission classification, approvals | [Tool System](../../core/tool-system/) | The single sanctioned path to side effects. Every click is a side effect. |
| Which model plays computer use, vendor toolset versions, coordinate dialect | [Model Pool](../../core/model-pool/model-classes.md) | `computer-use` is a versioned feature of the `generate` contract. `computer-use` and `grounder` are roles. |
| Vendor toolset encoding (tool declarations, batched actions, safety-check echo) | [Providers](../providers/) | A wire concern of the provider codec |
| Screenshot retention, resizing, pruning cadence, AX-text diffs | [Context Engine](../../core/context-engine/) | Screenshots are the largest context resource in the system |
| CU specialist delegation and structured handoff | [Sub-Agent Pool](../../core/sub-agent-pool/) | Isolates screen content and authority from the parent |
| Live view, takeover, kill switch, per-action approval cards, "agent active" indicator | [Interface](../../surfaces/interface/) | Human oversight is a surface capability |
| Action log, recordings, replays, route receipts | [Observability](../../cross-cutting/observability/) | Audit for a channel that can do anything a user can |

---

## Why this belongs in the harness

- **The model gives you an action vocabulary, not a system.** Vendor computer-use tools specify what the model may emit: click, type, scroll, zoom, and so on. They say nothing about which machine the action lands on, who approved it, what happens if the window moved, how many screenshots stay in context, or how the user stops it. Every one of those is a harness decision, and getting any of them wrong is visible: clicks landing on the wrong window, a runaway context, an agent typing into a password field.
- **It is the most powerful tool the harness will ever expose.** A shell can be sandboxed by path. A desktop can do anything its user can, in any app, including apps that are themselves shells. The permission model for the rest of the Tool System assumes tools have narrow, typed effects. Computer use breaks that assumption and needs its own classification.
- **The vendor surface churns.** In 2026 alone, one vendor replaced its single computer tool with a 17-member toolset that rejects oversized images, another moved to batched `actions[]` and recommends code execution over the computer tool for its top model, and a third retired its standalone computer-use model and moved to a 0–999 grid with per-action intent fields. A harness that hard-codes one dialect rewrites its loop every few months. A harness with a canonical action model writes one codec.

---

## What a display-target plugin owns

### Manifest

```jsonc
{
  "id": "macos-host",
  "label": "This Mac (host desktop)",
  "kind": "display-target",
  "platform": "macos",
  "isolation": "host",                    // "host" | "vm" | "container" | "remote-browser" | "remote-device"
  "perception": ["pixels", "accessibility", "ocr"],   // plus "dom" for browser targets
  "delivery": ["background", "foreground"],          // background = element actions / pid-routed events
  "semanticActions": ["press", "set-value", "focus", "menu-path", "launch-app", "open-url", "run-shortcut"],
  "multiDisplay": true,
  "observerAccess": "none",               // "vnc" | "stream" | "none"
  "requires": ["screen-capture", "accessibility", "post-events"],  // platform permissions, see macos.md
  "humanPresence": "shared"               // "shared" = a person may be using this screen right now
}
```

`humanPresence` and `isolation` are policy inputs. Grants, delivery defaults, and confirmation requirements derive from them, so a VM target and the user's own desktop do not share a permission profile by accident.

### Runtime contract

```ts
interface DisplayTarget {
  readonly manifest: DisplayTargetManifest

  // Lifecycle
  lease(req: LeaseRequest): Promise<Lease>                      // single controller; fails if held
  release(lease: Lease, reason: ReleaseReason): Promise<void>   // always restores UI state (unhide, cursor, focus)
  permissions(): Promise<PermissionSnapshot>                    // polled before each action batch

  // Perception
  describe(lease: Lease): Promise<TargetLayout>                 // displays, origins, scale factors, windows/tabs
  observe(lease: Lease, req: ObserveRequest): Promise<Observation>

  // Action
  act(lease: Lease, batch: ActionBatch): Promise<ActionOutcome[]>   // stops at the first failure

  // Oversight
  liveView?(lease: Lease): Promise<{ url: string; viewOnly: boolean; expiresAt: string }>
  takeover(lease: Lease, on: boolean): Promise<void>            // pauses capture and agent input while on
}

type ObserveRequest = {
  modes: ("pixels" | "accessibility" | "dom" | "ocr")[]
  scope: { display?: string } | { window: WindowRef } | { tab: string } | { region: Rect }
  maxImage?: { longEdgePx: number; maxVisualTokens?: number }   // from the model's limits, not a constant
  diffAgainst?: string                                          // prior observation id → structured diff
}

type Observation = {
  id: string                         // receipt id; actions cite it
  at: string
  target: { pid?: number; processStart?: string; windowId?: string; tabId?: string; bounds: Rect }
  image?: { blobRef: string; geometry: ScreenshotGeometry }
  tree?: { text: string; elements: Record<string, ElementRef> }   // compact text for the model, refs for the harness
  untrusted: true                    // always; screen content is external content
}

type ScreenshotGeometry = {
  capturedRect: Rect                 // logical points in the target's global space
  imageSize: { w: number; h: number }   // pixels actually sent to the model
  scaleFactor: number                // backing scale of the captured display
}
```

The contract is deliberately the same for a VM reached over VNC, a managed Chromium reached over CDP, and the host desktop. What differs is declared in the manifest: perception and delivery modes, isolation, and human presence. Tools and policy read those declarations, not the platform.

---

## Recommendation

### The control ladder: route before you click

| Rung | Channel | Precision | Cost | Use when |
|---|---|---|---|---|
| 1 | Native API / MCP server / app integration | exact | lowest | The app or service exposes one |
| 2 | CLI or OS scripting (shell, Apple Events, shortcuts/intents, `open` URLs) | exact | low | The action is scriptable |
| 3 | Structured UI: DOM refs (browser), accessibility refs (desktop) | element-level | medium (text tokens) | The UI exposes a usable tree |
| 4 | Pixels: screenshot + coordinates | approximate | highest (image tokens, latency) | Canvas, games, custom-drawn UI, broken trees, final visual verification |

The ladder appears in the tool description and in the CU sub-agent's system prompt. The Tool System enforces it softly: `computer.*` tools are `defer_loading` / searchable rather than always-on, so a model that has an MCP tool for the job sees that tool first. The robust desktop drivers studied follow the same order: they escalate from element action to pixel only when needed.

**Hybrid observation is the default at rung 3 and 4.** Send a compact tree plus a downscaled screenshot. Use labeled screenshots, with element refs overlaid as short tags, so the model can bridge "the thing I see" and "the ref I act on." Pixels and tree are captured at slightly different times. The receipt records both timestamps, and the harness never presents them as one atomic state.

### Display targets as an execution-environment family

| Target | Isolation | Perception | Delivery | Typical use |
|---|---|---|---|---|
| **Managed browser** (local or hosted Chromium over CDP) | container / remote | dom, pixels | background | Web tasks. The default for anything that happens in a browser. |
| **Desktop container** (Linux + virtual framebuffer + window manager, VNC observer) | container | pixels, accessibility (where available) | background (own display) | General GUI tasks with no user data |
| **Local VM** (macOS or Linux guest with an in-guest driver) | vm | pixels, accessibility | background (own display) | Desktop apps that need a real OS, with clean snapshots |
| **Host desktop** (the user's own machine) | host | pixels, accessibility, ocr | background-first, foreground by consent | Tasks that need the user's apps, files, and sign-ins |
| **User's real browser** (attached via extension or remote-debugging) | host | dom, pixels | background | Logged-in web tasks, with the user present |
| **Paired device** (phone, second machine) | remote-device | pixels, accessibility | device-specific | Mobile flows |

Rules:

- **The default target is the most isolated one that can do the job.** The host desktop and the user's real browser are **opt-in per agent and per session**. This is the same posture as the execution-environments page's `allowHostControl` flag for browsers, extended to desktops. Non-operator-initiated work (triggers, channel arrivals from non-owners) never gets a host target. That follows the same trust-degradation rule as sandbox `mode: non-main`.
- **Drive a VM from inside it.** An in-guest driver gives accessibility trees, background delivery, and real screenshots. Driving from outside over VNC gives pixels only. Run a small driver in the guest image and talk to it over a forwarded port or vsock. Keep VNC for the human observer.
- **Observer access is authenticated and short-lived.** VNC or stream URLs carry password-protected, expiring tokens, as the execution-environments page already requires for browser sandboxes. This page adds one requirement: observer links are **view-only** by default, and input is accepted only while takeover is on.

### The canonical action model

```ts
type Point = { x: number; y: number }                  // logical points in the target's global space
type Target = { ref: string; observation: string }     // element ref from a cited observation
           | { point: Point; observation: string }     // pixel fallback, also cites an observation

type Action =
  | { kind: "click"; at: Target; button?: "left" | "right" | "middle"; count?: 1 | 2 | 3; modifiers?: Mod[] }
  | { kind: "move"; to: Target }
  | { kind: "drag"; path: Target[]; modifiers?: Mod[] }               // ≥2 points; down/up guaranteed
  | { kind: "pointer"; state: "down" | "up" }                          // for custom gestures
  | { kind: "scroll"; at?: Target; dx: number; dy: number; unit: "line" | "pixel" }
  | { kind: "type"; text: string; into?: Target; mode?: "keys" | "set-value" | "paste" }
  | { kind: "key"; combo: string; repeat?: number }                    // "cmd+shift+a", normalized per platform
  | { kind: "hold"; combo: string; ms: number }
  | { kind: "press"; at: Target }                                      // semantic element action (AX press / DOM click)
  | { kind: "set-value"; at: Target; value: string }                   // semantic; read back to confirm
  | { kind: "menu"; path: string[]; app?: string }                     // semantic menu walk
  | { kind: "launch"; app: string; background?: boolean } | { kind: "open-url"; url: string }
  | { kind: "wait"; ms: number } | { kind: "wait-for"; condition: string; timeoutMs: number }
  | { kind: "observe"; request: ObserveRequest }                       // screenshot / zoom / tree
  | { kind: "zoom"; region: Rect; observation: string }                // full-res crop, coords stay in parent space

type ActionOutcome = {
  action: number                     // index in the batch
  effect: "confirmed" | "unverifiable" | "suspected-noop" | "partial" | "refused" | "not-executed"
  evidence?: string                  // e.g. "value read back", "focused element changed", "no visual change"
  escalation?: "observe" | "foreground" | "pixels" | "ask-user"   // what should happen next
  observation?: string               // fresh observation id when the action produced one
}
```

Notes:

- **Semantic actions are first-class.** `press`, `set-value`, and `menu` survive window moves, scaling, and occlusion, and they work without stealing focus. Pixel `click` is the fallback. A driver may implement `click` on a ref as `press` and report which it used.
- **Every pointer action cites an observation.** Acting on a ref or point from observation `o` re-resolves the element first (same role and label, frame within tolerance, same process generation). If it drifted, the action is `refused` with `escalation: "observe"`, not guessed. Process ids are recycled, so the receipt pins process start time as well as pid.
- **Typing has three modes.** `keys` synthesizes key events, needed for shortcuts, IME, and apps that ignore value setting. `set-value` writes the field directly, which is fastest, but must be read back because some web inputs don't fire input events. `paste` saves the clipboard, writes, verifies, pastes, and restores. The driver picks the mode unless the model or policy pins one.
- **Robustness is the driver's job.** Settle briefly between move and click, release modifiers and buttons in a `finally`, guard against orphaned held keys, and chunk Unicode typing at grapheme boundaries. A stuck modifier key on the user's real machine is a support incident, not a model error.

### Coordinate contract and screenshot geometry

| Dialect | Coordinates the model emits |
|---|---|
| Anthropic computer-use toolset, OpenAI `computer` tool | pixels of the image the harness sent |
| Gemini `computer_use` | normalized 0–999 grid, independent of image size |
| Open grounding models | model-native resolution (e.g. 1920×1080 or a 1000×1000 grid) |
| Harness function tools (models without a native toolset) | the harness's choice; prefer element refs, then pixels of the sent image |

Rules:

- **The harness resizes before sending.** It never relies on server-side downscaling. At least one vendor now rejects tool-result images above its long-edge or visual-token cap rather than resizing them. Read the caps from the model's `features["computer-use"].params` and `limits.maxImageEdgePx` in [model-classes](../../core/model-pool/model-classes.md#the-descriptor-contracts-facets-offering).
- **Every image sent carries its `ScreenshotGeometry`**, and the codec maps model coordinates back through it: `x_pt = captured.minX + x_img · captured.w / image.w`. Multi-display layouts can have negative origins. HiDPI displays need the backing scale factor.
- **The coordinate mode is frozen at session start.** If configuration could switch pixels ↔ normalized mid-session, the tool description the model read and the scaling the codec applies could disagree. That is a silent misclick on every action.
- **Silent rescaling beats telling the model the scale.** A note like "multiply coordinates by 1.37" asks the model to do arithmetic it does poorly. The codec rescales and the model never sees the factor.

### Model dialects: native toolsets vs. harness tools

The Tool System registers **one computer-use tool family** per session, bound to a display-target lease. How it is presented to the model depends on the model's `computer-use` feature:

- **Native toolset available** (a versioned vendor toolset on the `generate` contract). The provider codec emits the vendor's declaration, decodes its action calls into canonical `Action`s, and encodes results back:
  - batched tool-use blocks with stop-at-first-failure, where unexecuted blocks still get a "not executed" result;
  - an ordered `actions[]` array per call;
  - per-action `intent` fields.
  - Vendor safety signals map onto the harness's confirmation machinery: pending safety checks that must be echoed as acknowledged, and `require_confirmation` decisions that need an acknowledgement in the result. **They are never auto-acknowledged** (see [§ Safety](#safety-is-layered-not-a-single-gate)).
- **No native toolset.** The harness exposes function tools with element-ref-first schemas: `observe`, `click(ref | point)`, `type`, `key`, `scroll`, `press`, `set_value`, `menu`, `launch`, `open_url`, `zoom`, `wait_for`, `verify`, `ask_user`. Use one flat object schema per tool, because some providers reject nested `anyOf` unions in tool parameters.
- **Code execution as a peer path.** At least one vendor now recommends its top model write automation scripts in a sandbox instead of driving the computer tool. The scripts are browser automation or desktop input-automation libraries. Treat that as rung 2 of the ladder (scripting) inside the leased target. Do not bypass the target. The script runs against the same leased browser or desktop under the same grants and domain policy, and it is gated as a whole script rather than per action (see [§ Alternatives](#code-execution-instead-of-a-computer-tool)).
- **Tool results must carry images as images.** The provider codec must encode a screenshot in a tool result as an image block in the vendor's format, never as base64 text inside a string. A harness that stringifies image content from tool results gives the model no vision and blows up the context. This includes images arriving from MCP servers.

### Sessions, leases, grants, and tiers

```ts
type LeaseRequest = {
  target: string                       // display-target id
  conversation: string; agent: string
  grants: Grant[]                      // requested; user approves a subset
  budgets: ResolvedBudgets             // host policy combined with the task's request; see § Budgets
  delivery: "background-only" | "foreground-allowed"
}

type Grant =
  | { app: string; tier: "view" | "click" | "full"; flags?: ("clipboard-read" | "clipboard-write" | "system-keys")[] }
  | { domain: string; tier: "view" | "click" | "full" }
```

- **One controller per target.** Acquire with an atomic, exclusive lock whose holder can be identified and checked for liveness, so a crashed holder doesn't block the target forever. A second session gets a typed `target-busy`, not a fight over the cursor.
- **Grants are per session and per app or domain, with tiers.**
  - *View*: the app appears in observations only.
  - *Click*: pointer actions, but no typing or shortcuts. This is the right default for terminals and IDEs, since typing there is shell access.
  - *Full*: everything.

  At grant time the dialog states the real blast radius of apps whose access is effectively broader than the app: shells and IDEs, file managers, and system settings. This template additionally recommends **blocking by default** the categories vendors have flagged as high-harm: investment, trading and crypto platforms and other financial services. Password managers belong on the same list. These categories need an explicit operator override.
- **Approval is one dialog at session start, not one per click.** The user approves the grant set. Per-action confirmation is reserved for consequential actions (below). Grants expire with the session. Sessions spawned without a present user (delegated or background) get a short absolute expiry, measured in tens of minutes. Budget extensions never move it.
- **Non-granted apps are hidden or excluded.** On host targets, hide non-granted windows during the agent's turn and restore them at turn end, on abort, and on crash, with a timeout so cleanup can't wedge. Exclude the harness's own UI (terminal, chat window, overlays) from every capture. The model must never read its own transcript or approval prompts off the screen.
- **Budgets grow on progress and stop at a ceiling.** Every way a session can run out produces a typed terminal reason. See [§ Budgets, progress, and extensions](#budgets-progress-and-extensions).

### Budgets, progress, and extensions

One fixed wall-clock budget cannot do two jobs. Set short, it ends real work: with model turns of 20–55 seconds, a 3-minute budget buys four to seven turns. Set long, a stuck session burns all of it before anything notices. So the budget is split by job, and each limit is set by whoever has the information to set it.

| Limit | Set by | Job | Extended? |
|---|---|---|---|
| Step allotment | the task (parent), else the host default; clamped to the ceiling | expected size of the work | yes, on progress |
| Step ceiling | host | cap on long work | only by a present user |
| No-progress window (in steps) | host | catch a session that is busy but going nowhere | no |
| Consecutive-failure escalation | host | catch a session whose actions keep failing | no; escalates to `ask_user` |
| Idle timeout | host, through the Sub-Agent Pool | catch a hung model call or driver | no |
| Time ceiling | host | wall-clock cap on the session | only by a present user |
| Deadline | the task, only when a real one exists | a cutoff the user stated | never |
| Absolute grant expiry (no user present) | host | bound unattended authority | never |
| Cost cap | host (the task may tighten it) | spend | never |

```ts
// Host configuration. The model never sets these.
type ComputerUseBudgetPolicy = {
  defaultSteps: number          // first allotment when the task names none
  ceilingSteps: number          // includes all extensions; e.g. 3 × defaultSteps
  extensionShare: number        // fraction of the first allotment added per extension; e.g. 0.5
  noProgressSteps: number       // consecutive steps without progress before the session ends; e.g. 8
  maxDuration: Duration         // wall-clock ceiling for the session
  maxUsd?: number               // never extended automatically
}

// What a lease carries: the policy combined with the task's request.
type ResolvedBudgets = {
  steps: number                 // current allotment; starts at min(task.steps ?? defaultSteps, ceilingSteps)
  ceilingSteps: number
  extensionShare: number
  noProgressSteps: number
  endsAt: string                // earliest of: start + maxDuration, task.deadline, absolute grant expiry
  maxUsd?: number
}
```

- **The parent sizes the work in steps, never in minutes.** A step is one action delivered to the driver. Actions that come back `not-executed` don't count. A parent can estimate that "open the app and fill in the form" is about fifteen actions. It can't estimate how long a different model will think, so the delegate tool exposes no time budget. Time limits belong to the host and are generous. They bound the session; they don't measure the work.
- **A deadline is a cutoff, not an estimate.** The task carries `deadline` only when the user or the task states a real one ("before my call at 3"). It can only make `endsAt` earlier, and progress never extends it. When it passes, the session ends with `deadline`.

#### What counts as progress

Progress is decided only from facts the harness recorded. It is never the model's claim that it is nearly done, and never screen text. A step **made progress** when either of these holds:

1. **A success criterion was newly verified.** A `verify` call recorded `met: true` for a criterion that had not been met before. This is the strongest signal.
2. **The agent reached a new state.** All three conditions must hold:
   - **The state is new.** Its fingerprint is not in the set of fingerprints this session has already observed. Returning to an earlier state never counts, which is what catches oscillation (open a menu, close it, open it again).
   - **An acting step caused it.** The state was first observed after an action that does something, not after `observe`, `zoom`, `wait`, or `wait-for`, and not during takeover. A page that finishes loading on its own doesn't earn progress.
   - **The action wasn't a known failure.** Its effect was `confirmed`, `partial`, or `unverifiable`, not `refused`, `suspected-noop`, or `not-executed`. Requiring `confirmed` would starve pixel-only targets, where legitimate clicks often can't be confirmed.

**The state fingerprint is coarse and structural.** It is a digest of the frontmost app, the window identity, the URL or document identity, the focused element's role, and the shape of the accessibility tree or DOM: element roles and depth, not text or values. A clock ticking, a feed adding items, or a toast changing its text then mostly doesn't produce a new fingerprint. On pixel-only targets the fingerprint is limited to app, window, and URL identity, so it is coarser there. Fingerprints are only compared, never shown to a model, so screen content can at worst make states look new, and the ceiling bounds that case.

**One progress predicate serves every check.** The extension check and the no-progress window read the same predicate, so they can never disagree about whether the session is moving. An agent wandering through genuinely new but unhelpful screens still looks like it is making progress. No rule built only on harness-recorded facts can tell wandering from exploring. The ceiling covers that case, and a verified criterion remains the stronger signal.

#### Extensions

- **When.** When the step allotment runs out, the harness grants an extension if any step since the last grant (or since the start) made progress.
- **How much.** `extensionShare` of the first allotment, rounded up, never past `ceilingSteps`.
- **At the ceiling.** With a present user, the session pauses and asks through `ask_user` whether to continue. A yes grants one more extension, and the question comes again at the next ceiling. The time ceiling works the same way. Without a present user, the session ends with `budget-exhausted`.
- **Never extended.** Cost, the deadline, and the absolute grant expiry of unattended sessions. Extensions grow the work, never the authority.
- **Visible.** Each grant is written to the action log with the facts that justified it (criteria newly verified, new states reached since the last grant) and shown on the activity indicator ("step 34 of 45, extended twice"). Grants are not approved one by one, because asking per extension causes the same approval fatigue as asking per click.

#### Ending a session that isn't moving

- **No progress.** When `noProgressSteps` consecutive steps pass without progress, the session ends with `no-progress`, whatever allotment remains. Counting steps rather than seconds makes the check behave the same on a fast model and a slow one.
- **Repeated failure.** After 2–3 consecutive failed attempts at the same subgoal, escalate to `ask_user` rather than looping. This usually fires before the no-progress window, and it remains the faster signal for a loop of refused actions.
- **Idle.** A model call or driver that produces nothing at all is caught by the Sub-Agent Pool's [idle timeout](../../core/sub-agent-pool/#idle-timeout-liveness-not-progress), which applies to every delegate. Size it for the computer-use model binding: at least twice the slowest expected model turn, since some providers stream nothing while the model thinks.

#### One clock, not two

The specialist runs as a child of the Sub-Agent Pool, and that child has its own run timeout. If that timeout is configured separately, it ends the run while the lease is still being extended, and the extensions do nothing. The child's run timeout is **derived from the lease**: `endsAt` plus a short cleanup grace, recomputed when a present user grants more time at the ceiling. The session's terminal reason, not the child's timeout, decides the result status.

### Permission classification per action

Computer use plugs into the existing Tool System machinery ([permissions](../../core/tool-system/permissions.md)) with **argument-level classification**. The tool is polymorphic, so its effect class depends on the action:

| Action class | Examples | Effect | Default gate |
|---|---|---|---|
| Observe | `observe`, `zoom`, `wait`, cursor position | read-only | allow within grant |
| Navigate | `scroll`, `move`, `launch` (granted apps only), `open-url` (**`http(s)` only**, allowed domain, opened in a granted browser target) | low | allow within grant |
| Interact | `click`, `press`, `type`, `set-value`, `key` within a granted app at its tier | mutating | allow within grant + intent check. With no intent checker bound, **confirm** on `humanPresence: shared` targets unless the operator explicitly opts out. |
| Consequential | submit/send/buy/delete/install, typing into password or payment fields, accepting terms, system-settings changes, anything a vendor safety signal flags | irreversible | **confirm** (per action, even inside a batch) |
| Out of grant | any action on a non-granted app or domain, a tier violation, global shortcuts without `system-keys`, `open-url` with a non-web scheme (`file:`, `tel:`, custom app schemes dispatch to other apps and bypass app grants) | — | deny, with the reason returned to the model |

- Classification is computed by the harness from the action, the target element (role, label, app, URL), and the grant, never from the model's own claim. The vendor `intent` field is input to the intent check, not a permission.
- **Confirmation is per action inside a batch.** One batch can complete a multi-step flow (fill form, then submit). The approval check runs before each action, and a refusal stops the batch with "not executed" for the rest.
- **Approval binding applies.** The confirmed action's canonical form (action, target ref, observation id, typed text hash) is what was approved. A drift between approval and execution invalidates it. That is the same exact-action binding the permissions page requires for shell commands.

### Safety is layered, not a single gate

No single control is sufficient. Measured attack success rates for browser agents dropped from tens of percent to near zero only when several layers were stacked, and hardening proved **domain-specific**: the same weights that resisted browser injection were highly vulnerable in another domain. The layers:

1. **Isolation.** Default to a VM, container, or managed browser with no user data. Host targets are opt-in, with extra controls.
2. **Scoped grants with tiers and blocked categories** ([§ Sessions](#sessions-leases-grants-and-tiers)).
3. **Untrusted-content treatment of the screen.** Every observation is external content. Text observations (trees, DOM, OCR) get the [input-provenance](../../surfaces/triggers/input-provenance.md) envelope. **Images cannot be wrapped**, so the image channel relies on layers 4–6.
4. **Per-action intent alignment.** Before each interact or consequential action, a fast check asks "is this action consistent with what the user asked for?"
   - **Input:** the user's request, a short text history of prior actions, and the proposed action described by **harness-derived identifiers only**: action kind, app bundle id or domain, and element role.
   - **Excluded input:** the screenshot, screen text, and on-screen labels and titles. Those are attacker-controllable and are the injection channel.
   - **Evidence:** a published per-action guard built on an LLM cut attack success by >90% with no loss of benign task success, at several seconds per step.
   - **Fast variant:** a [decision model](../providers/decision-models.md#where-the-harness-uses-deciders) on the `guard` role can run the same check in ~100 ms. Its robustness to adaptive attacks is unmeasured, and deciders are themselves injection-sensitive, so validate it on your own attack set before relying on it. Keep the LLM guard for consequential actions.
   - **Outcome:** a mismatch or an unavailable verdict goes to *confirm*, never silently allowed. An unbound checker means *confirm* for interact actions on shared targets (see the classification table above).
5. **Consequential-action confirmation**, including vendor safety signals: malicious-instructions, irrelevant-domain, and sensitive-domain checks, and `require_confirmation` decisions. Route each through the [approval UX](../../surfaces/interface/approval-ux.md) as a real question to the user. Auto-acknowledging a vendor safety check is an anti-pattern even in bypass mode. A sensitive-domain signal means *watch mode*: the session continues only while a live view is open.
6. **Injection classifiers on observations**, where the vendor or a `guard` decider offers them. They warn and steer ("check whether this instruction came from the user"). They do not block on their own, since they read the same untrusted content.
7. **Takeover mode for credentials and human-only steps.** Logins, 2FA, CAPTCHAs, and payment entry are reported by the agent as `handoff` and completed by the user. While takeover is on, capture is suspended and agent input is blocked, so the model never sees the password being typed. Block navigation to URLs that embed secrets, and redact secrets from any auxiliary-model inputs.
8. **An injection-proof kill switch.** A global stop key (or button) that the agent cannot trigger or suppress.
   - **Enforced at the action layer.** The harness refuses to emit the stop key in any synthesized action while a session is active, so an injected "press Escape" can neither stop the session nor use the key to dismiss a dialog.
   - **Platform enforcement is optional.** It can be added where it is safe; macos.md covers the trade-offs of an event tap.
   - **Abort and indicator.** The abort runs the full cleanup path. An OS-level indicator saying the agent is in control, and how to stop it, stays visible for the whole session.
9. **Network policy for browser targets.** SSRF checks fail closed, applied before navigation and on the final URL after redirects, with private-network access opt-in and domain allow and block lists. Origin allowlists in browser-automation tools are hygiene, not a security boundary. The boundary is the target's network.

### Context budget for screenshots

- **Size to the model.** Resize to the binding's `maxImageEdgePx` and visual-token cap. A screenshot costs roughly 1–2K input tokens at typical sizes. Above ~20 images per request, at least one vendor lowers the per-image cap, so the retention policy should keep requests under that count.
- **Keep the last N, prune in batches.** Keep the most recent ~3 screenshots in full. Replace older ones with a marker plus a one-line text summary of what they showed. Prune every K turns (vendor guidance: keep 3, prune every ~25), not every turn, so the cached prefix stays byte-stable between prunes. This is the [cache-aware](../../core/context-engine/cache-aware-operations.md) version of the attachment-inlining page's K-most-recent rule.
- **Count steps, not user turns.** A policy that prunes after N completed user turns never fires inside a single 200-step computer-use turn. Retention counts observations within the loop.
- **Prefer text deltas.** After the first full tree, send diffs. After an action whose effect is `confirmed` by tree evidence, a fresh screenshot is optional. Request one when verification needs pixels.
- **Zoom instead of upscaling.** Fine text is read through a full-resolution crop of a region (`zoom`), not by sending a larger full screenshot.
- **Optional vision-as-a-sub-call.** For models without vision, or to keep images out of an expensive context entirely, an auxiliary `vision-describe` call answers a specific question about a screenshot and returns text. This costs grounding precision, so pair it with ref-based actions.

### The computer-use sub-agent

For anything longer than a handful of steps, the parent delegates:

```ts
type ComputerUseTask = {
  goal: string                         // includes success criteria the sub-agent must verify
  constraints: string[]                // carried verbatim into every step's context (lost constraints are the #1 failure)
  target: string; grants: Grant[]
  steps?: number                       // expected size of the work: the first allotment. There is no time budget.
  deadline?: string                    // only a real, stated cutoff; never an estimate
  returnSchema?: JsonSchema            // structured result for the parent
}

type ComputerUseResult = {
  status: "done" | "done-unverified" | "needs-user" | "blocked"
        | "budget-exhausted" | "no-progress" | "deadline" | "failed"
  reason?: string                      // e.g. "step ceiling reached", "idle-timeout"
  result?: unknown                     // matches returnSchema
  verification: { criterion: string; met: boolean; evidence: string }[]
  handoff?: { reason: "login" | "2fa" | "captcha" | "payment" | "ambiguous" | "consequential"; prompt: string }
  budget: { stepsUsed: number; stepsGranted: number; extensions: number; lastProgressStep?: number }
  actionsLog: string                   // blob ref; the parent sees a summary, not screenshots
}
```

**The terminal statuses tell the parent what to do next.**
- `budget-exhausted` after extensions means the work was moving and ran out of room. Delegating the remainder, starting from the criteria already verified, is reasonable.
- `no-progress` means repeating the same delegation won't help. Rephrase the goal, pick another rung of the control ladder, or ask the user.
- `deadline` means the stated cutoff passed.
- An idle timeout comes back as `failed` with `reason: "idle-timeout"`. That usually points at the model binding or the driver rather than the task.

Why this is the default for long tasks:

- **Context isolation.** Screenshots and screen text live in the sub-agent's context and never in the parent's. The parent receives a structured result, which is also an injection firebreak: on-screen instructions cannot reach a context holding shell, file, or messaging tools.
- **Authority isolation.** The sub-agent's tool set is the computer-use family plus `verify`, `ask_user`, `handoff`, and a scratchpad. It has no shell, no file writes, and no outbound messaging unless the task explicitly grants them.
- **Model choice.** The `computer-use` role can bind a model tuned for GUI work, including small open models that score well on web tasks, while the parent stays on its planner. A `grounder` role can back a cheaper model that plans in text but cannot localize precisely.
- **Constraint retention.** The task's constraints and success criteria are re-injected into every step. That directly counters the dominant long-horizon failure.

Tool schemas for computer use run to several thousand tokens. Keep them deferred or searchable in the parent and loaded only in the sub-agent.

### Verification, ask-user, and handoff are actions

- `verify(criterion)` asks the loop to check a post-condition against a fresh observation and record evidence. The sub-agent cannot return `done` until every success criterion has a `verify` entry. A completion without full verification is reported as `done-unverified`, and the parent decides whether to check further or tell the user.
- `ask_user(question)` pauses the loop and routes through the conversation's surfaces. It beats guessing, and published long-horizon failures are dominated by guessing.
- `handoff(reason)` starts takeover mode for human-only steps and resumes when the user hands back control.
- **Never auto-retry a possibly-delivered action.** If a click that may have submitted a form returns `unverifiable`, the next step is `observe`, not a second click. Double-submits are the classic computer-use incident.

### Oversight surfaces

Surfaces that support it declare a `computer-use` capability and render:

- **A live view.** An authenticated stream or VNC link, view-only unless takeover is on. A sensitive-domain session requires it to be open.
- **An activity indicator.** "Agent is using <target>", with the current app, the step against the current allotment, and how many times the allotment was extended. It is visible outside the chat window on host targets.
- **Per-action approval cards** for consequential actions, showing the action, target element, a cropped image of the target region, and the intent-check verdict.
- **Takeover and stop controls.** Stop is also bound to the global kill switch on host targets.
- **A post-run replay.** Action log plus observation thumbnails, and a recording where the target supports it.

Headless runs (scheduled triggers) can use isolated targets only. A consequential action in a headless run is denied with `headlessDenied` and surfaced on the next interactive attach. That is the same rule the execution-environments page applies to exec approval.

### Recording, audit, replay

Every action is logged with its observation id, canonical form, classification, gate decision and reason, intent-check verdict, effect, evidence, and whether it made progress. Budget extensions, ceiling questions, and the terminal reason are logged as session events, with the progress facts behind each. Observation images are stored as content-addressed blobs **in the durable lane while anything references them**: the live context window, a pending approval citing the observation, or the session's replay thumbnails. The ephemeral TTL starts when the lease is released. Retention beyond that applies only to sessions the user marks for audit. Route receipts from the Model Pool link each step to the model call that proposed it. Replays are for humans. Deterministic re-execution of a recorded action list is a different feature (scripted RPA) and should not be implied by "replay."

---

## Alternatives

### Vendor reference loop on the user's desktop, pixels only

Run the vendor's sample loop (screenshot → model → xdotool-style action) directly against the user's machine.

**When this works:** demos, single-user experimentation, and throwaway VMs.

**Why not as default:** it has no routing to better channels, no grants, no observation binding, no per-action gating, and no cleanup. It is the shape every serious implementation moved away from. **The piece worth borrowing:** the action vocabulary, which is what the canonical model normalizes.

### Structured-only (DOM / accessibility refs, no vision)

Drive everything through element refs from a tree, and never send a screenshot.

**When this works:** browser automation on well-structured sites, text-only models, and cost-sensitive bulk tasks.

**Why not as default:** canvas UIs, custom-drawn controls, sparse trees in some cross-platform app frameworks, and visual verification all need pixels. Keep it as rung 3 of the ladder and let pixels be the fallback.

### Auxiliary vision model, screenshots never in the main context

The main agent works from trees. When it needs to see, it asks a separate vision model a question about a screenshot and gets text back.

**When this works:** non-vision main models, very long sessions, and strict context budgets.

**Why not as default:** the answer is ungrounded, with no coordinates, and each look adds a model call. It is a good tool (`vision-describe`) inside the hybrid default, not the whole design.

### Code execution instead of a computer tool

The model writes and runs browser-automation scripts against a managed browser.

**When this works:** structured web workflows with stable selectors, and models that are stronger at code than at GUI driving. One vendor now recommends this for its top model.

**Why not as default:** a script can do far more per step than a single click, so approval becomes per-script and much coarser. Desktop input-automation scripts are pixel-blind unless they take screenshots themselves. And it fails on UI that has no stable selectors. Treat it as rung 2 inside the same target and policy, and review whole scripts as consequential when they touch a shared target.

### External computer-use server as the implementation

Attach a third-party computer-use or desktop-automation MCP server and stop there.

**When this works:** quick integration, and platforms the harness team does not want to maintain drivers for.

**Why not as default:** grants, leases, observation binding, intent checks, and screenshot retention still have to live in the harness. An MCP server cannot see the conversation, the user's request, or the context budget. **Treat the server as a display-target driver**, with the harness's contract wrapped around it. This is a good way to support platforms you don't build natively.

### Fixed time budget set by the parent

The parent passes a wall-clock budget, and the session ends when it runs out.

**When this works:** fast, predictable models on short tasks.

**Why not as default:** it asks the parent to estimate the speed of a model it doesn't run, and one number can't both catch a stuck session quickly and leave room for a long one. Model latency dominates wall-clock time, so the same task passes on one binding and fails on another.

### Parent decides on continuation

The session ends with `budget-exhausted` and a continuation handle, and the parent decides whether to resume.

**When this works:** when the parent knows something the harness doesn't, such as a change in the user's priorities mid-task.

**Why not as default:** the parent is usually the slower, more expensive model, and it knows less about progress than the harness, which recorded every action. Keep the extension rule in the harness. The parent still decides what to do with a `budget-exhausted` result.

### Model judge for extensions

A cheap model decides whether to extend, given the goal, the criteria and which are verified, and one-line action summaries written by the harness.

**When this works:** borderline cases, such as a long stretch of new states with no criterion verified.

**Why not as default:** with only harness-written inputs it adds little over the deterministic predicate, and it costs a model call plus its own validation. If used, it follows the intent check's input rule: harness-derived facts only, never screen text.

---

## Anti-patterns

- **Clicking when an API exists.** Pixel-driving an app that has an MCP server or CLI is slower, costlier, and less reliable. The ladder is a rule, not a hint.
- **Relying on the vendor to downscale.** Oversized images are now rejected by at least one vendor, and silent server-side resizing elsewhere breaks the coordinate mapping. Resize harness-side and record the geometry.
- **Changing the coordinate mode mid-session.** The model reads one convention while the codec applies another, so every click lands wrong without an error.
- **Retrying an unverifiable click.** Observe first. A form submitted twice is worse than a form not submitted.
- **Auto-acknowledging vendor safety checks.** Those signals exist precisely for the cases where the model has been steered. Each one is a question for the user.
- **One approval per click.** Users approve everything after the tenth prompt. Approve the grant set once and confirm only consequential actions.
- **The harness's own window in the screenshot.** The model reads its transcript, its approval prompts, or the user's typing in the chat box off the screen. Exclude your UI from capture.
- **Stringifying image tool results.** A screenshot returned as base64 text gives the model no vision and blows up the context. Encode images as images end to end, including from MCP servers.
- **Per-user-turn screenshot pruning.** One long turn accumulates hundreds of screenshots. Count observations within the loop.
- **Pruning every turn.** Each prune rewrites the prefix and kills the prompt cache. Prune in batches.
- **Screen text in the permission gate's input.** The gate then reads the injected instruction it is supposed to guard against. Gates see the user's request and the proposed action, not the page.
- **Stuck input state.** A modifier or mouse button left down on the user's real machine. Release in `finally`, guard held keys, and make cleanup idempotent.
- **Host control by default for background work.** A scheduled trigger driving the owner's real desktop with nobody watching. Host targets require an interactive, present user.
- **A wall-clock budget the model guesses.** The parent can't know how fast the specialist model thinks, so the guess ends real work or lets stuck work run. The parent sizes work in steps; time limits belong to the host.
- **Counting any screen change as progress.** Animations, live feeds, and oscillation between two states all change the screen. Progress is a newly verified criterion, or a new state reached by the agent's own action.
- **Two independent clocks on one session.** A child run timeout configured apart from the lease ends runs that the lease was extending. Derive one from the other.

---

## Cross-references

- [`./macos.md`](./macos.md): macOS implementation (capture, accessibility, input, TCC, host-app pattern, VMs).
- [Execution Environments](../execution-environments/): backend registry, browser sandbox container, observer auth, trust-based target defaults.
- [Model Pool § Model classes](../../core/model-pool/model-classes.md): `computer-use` feature versions, the `computer-use`, `grounder`, `guard`, and `vision-describe` roles.
- [Providers § Decision models](../providers/decision-models.md): fast per-action intent checks.
- [Tool System § Permissions](../../core/tool-system/permissions.md): argument-level classification, approval binding, classifier-assisted gating.
- [Tool System § Result formatting](../../core/tool-system/result-formatting.md): image sanitization, degrade-to-marker.
- [Context Engine § Attachment inlining](../../core/context-engine/attachment-inlining.md) and [§ Cache-aware operations](../../core/context-engine/cache-aware-operations.md): K-most-recent images, batch pruning.
- [Sub-Agent Pool](../../core/sub-agent-pool/): delegation transport for the CU specialist.
- [Interface § Approval UX](../../surfaces/interface/approval-ux.md): approval cards and decision vocabulary.
- [Triggers § Input provenance](../../surfaces/triggers/input-provenance.md): untrusted-content envelope for screen text.
