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
8. **Use a computer-use specialist sub-agent by default for long tasks.** It gets its own model, its own bounded screenshot context, and narrower tool authority. It returns a structured result, so screenshots and raw screen text never sit in the parent's context with the parent's permissions. The result's free-text fields were still written by a model that read untrusted screens, so the parent treats them as untrusted content.
9. **Verification, ask-user, and handoff are first-class tools, not afterthoughts.** The computer-use tool family includes `verify`, `ask_user`, and `handoff` alongside the display actions, and the harness enforces checkpoints before irreversible steps.

Platform implementation for macOS (capture, accessibility, input, TCC permissions, VMs) is in [`./macos.md`](./macos.md).

---

## How this fits the architecture

Computer use is not one layer's concern. It is a backend family plus a tool family, with obligations on five other layers:

| Concern | Owner | Why |
|---|---|---|
| Screen capture, accessibility/DOM snapshots, input injection, target lifecycle | **Display-target backend** (this page) | Platform-specific drivers behind one contract, as with sandbox backends |
| Where targets run (VM, container, host), registry, observer-access auth | [Execution Environments](../execution-environments/) | Display targets share three things with sandbox backends: the backend id namespace, the persistent-runtime lifecycle hooks (`describeRuntime`, `removeRuntime`, pruning) for targets that outlive a lease, and the observer-token issuer. Their factory and observe/act contract are defined here, as a sibling of `SandboxBackendHandle`, not an extension of it. See [§ Display targets](#display-targets-as-an-execution-environment-family). |
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
  "isolation": "host",                    // "host" | "process" | "container" | "vm" | "remote-browser" | "remote-device"
  "perception": ["pixels", "accessibility", "ocr"],   // plus "dom" for browser targets
  "delivery": ["background", "foreground"],          // background = element actions / pid-routed events
  "semanticActions": ["press", "set-value", "focus", "menu-path", "launch-app", "open-url", "run-shortcut"],
  "multiDisplay": true,
  "observerAccess": "none",               // "vnc" | "stream" | "none"
  "requires": ["screen-capture", "accessibility", "post-events"],  // platform permissions, see macos.md
  "humanPresence": "shared"               // "shared" | "exclusive"; see below
}
```

`humanPresence` and `isolation` are policy inputs. Grants, delivery defaults, and confirmation requirements derive from them, so a VM target and the user's own desktop do not share a permission profile by accident.

- **`isolation`** says what separates the target from the user's data and machine:
  - `host`: the user's own session.
  - `process`: a separate local process with a throwaway profile and no user data, sharing the host's OS and network. A locally launched managed browser is this.
  - `container` and `vm`: an OS-level boundary with its own filesystem and network namespace.
  - `remote-browser` and `remote-device`: another machine.

  For policy, `process` counts as isolated for **data** (no user files, sign-ins, or history) but not for **network**. It shares the host's network, so the network rules in [§ Safety](#safety-is-layered-not-a-single-gate) must be enforced inside the browser rather than at a namespace boundary.
- **`humanPresence`** says who else may be using the screen:
  - `shared`: a person may be using this screen right now. The host desktop, the user's real browser, and a phone someone carries are all `shared`. A `shared` target follows the host-target rules (opt-in, present user) whatever its `isolation`.
  - `exclusive`: only the agent drives it. People may watch through a live view or act during takeover.

### Runtime contract

```ts
interface DisplayTarget {
  readonly manifest: DisplayTargetManifest

  // Lifecycle
  lease(req: LeaseRequest): Promise<Lease>                      // single controller; fails if held
  release(lease: Lease, reason: ReleaseReason): Promise<void>   // always restores UI state (unhide, cursor, focus)
  permissions(): Promise<PermissionSnapshot>                    // polled before each action batch

  // Perception
  describe(lease: Lease): Promise<TargetLayout>                 // displays, origins, scale factors; windows/tabs of granted apps only
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
  maxImage?: { longEdgePx: number; maxPixels?: number; maxVisualTokens?: number }
                                     // the tightest of the model's caps and the result pipeline's cap
  diffAgainst?: string               // prior observation id → structured diff (see § Context budget)
}

type Observation = {
  id: string                         // receipt id; actions cite it
  at: string
  target: { pid?: number; processStart?: string; windowId?: string; tabId?: string; bounds: Rect }
  image?: { blobRef: string; geometry: ScreenshotGeometry }
  tree?: { text: string; elements: Record<string, ElementRef> }   // compact text for the model, refs for the harness
  fingerprint: string                // coarse state digest; see § What counts as progress
  pageBounds?: Rect                  // browser targets: the web content area, in the same global points
  untrusted: true                    // always; screen content is external content
}

type ReleaseReason =
  | "completed" | "cancelled" | "budget-exhausted" | "no-progress" | "deadline"
  | "expired"                        // time ceiling or absolute grant expiry
  | "idle-timeout" | "kill-switch" | "holder-lost"   // holder-lost: the lease holder's connection died
  | "permission-revoked"             // a platform (OS) permission was revoked; the user must re-grant it
  | "policy-revoked"                 // a mode denied computer use mid-session; don't retry
// Each session terminal reason releases with the same-named value; the step and cost ceilings
// release as "budget-exhausted", and the time ceiling and grant expiry as "expired".

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

The ladder appears in the tool description and in the CU sub-agent's system prompt. The Tool System enforces it softly. In the parent, the only computer-use tool is the delegate to the specialist, and it is registered as deferred (searchable) rather than always-on, so a model that has an MCP tool for the job sees that tool first. The `computer_*` family itself is registered only in the specialist. The robust desktop drivers studied follow the same order: they escalate from element action to pixel only when needed.

**Tool names use `computer_` and snake case** (`computer_click`, `computer_open_url`). Major vendors accept only `[a-zA-Z0-9_-]{1,64}` as tool names, so a dotted family name cannot go on the wire.

**Hybrid observation is the default at rung 3 and 4.** Send a compact tree plus a downscaled screenshot. Use labeled screenshots, with element refs overlaid as short tags, so the model can bridge "the thing I see" and "the ref I act on." Tag only actionable elements whose frames intersect the captured region, at most a few dozen. Prefer the focused element and elements near the last action, and skip tags that would overlap. Pixels and tree are captured at slightly different times. The receipt records both timestamps, and the harness never presents them as one atomic state.

### Display targets as an execution-environment family

| Target | Isolation | Perception | Delivery | Typical use |
|---|---|---|---|---|
| **Managed browser** (local or hosted Chromium over CDP) | process (local) / container / remote-browser | dom, pixels | background | Web tasks. The default for anything that happens in a browser. |
| **Desktop container** (Linux + virtual framebuffer + window manager, VNC observer) | container | pixels, accessibility (where available) | background (own display) | General GUI tasks with no user data |
| **Local VM** (macOS or Linux guest with an in-guest driver) | vm | pixels, accessibility | background (own display) | Desktop apps that need a real OS, with clean snapshots |
| **Host desktop** (the user's own machine) | host | pixels, accessibility, ocr | background-first, foreground by consent | Tasks that need the user's apps, files, and sign-ins |
| **User's real browser** (attached via extension or remote-debugging) | host | dom, pixels | background | Logged-in web tasks, with the user present |
| **Paired device** (phone, second machine) | remote-device | pixels, accessibility | device-specific | Mobile flows. Phones need a host-side automation channel: Android through its debug bridge and UI automation service, iOS only on a developer-provisioned device through the platform's UI-testing agent. A consumer iPhone without that tool chain is not a target. |

Rules:

- **The default target is the most isolated one that can do the job**, chosen by an explicit rule rather than a judgment the harness can't compute:
  1. A task that names a target gets it, subject to the opt-in rules below.
  2. A task that grants domains and no apps gets the managed browser.
  3. Otherwise the task gets the host's configured default desktop target, which must be isolated unless the operator opted this agent into host targets.
  The host desktop and the user's real browser are **opt-in per agent and per session**. This is the same posture as the execution-environments page's `allowHostControl` flag for browsers, extended to desktops. Non-operator-initiated work (triggers, channel arrivals from non-owners) never gets a host target. That follows the same trust-degradation rule as sandbox `mode: non-main`.
- **Drive a VM from inside it.** An in-guest driver gives accessibility trees, background delivery, and real screenshots. Driving from outside over VNC gives pixels only. Run a small driver in the guest image and talk to it over a forwarded port or vsock.
- **What display targets share with sandbox backends.** They register under the same backend id namespace and use the same observer-token issuer. Whether a target uses the persistent-runtime lifecycle depends on how it is deployed, not on its kind:
  - **Kept between leases** (a VM or hosted browser kept warm for the next task): `describeRuntime`, `removeRuntime`, and pruning by idle time and age.
  - **Started per lease** (a VM or container created for one lease, a locally launched browser): created at lease and removed at release, so they never enter pruning. Each harness start also sweeps per-lease runtimes that a crashed harness left behind, identified by a label the harness put on them at creation.
  - **The host desktop** has no runtime to manage; release is its whole lifecycle. The factory is display-target-specific, because sandbox factories return a `SandboxBackendHandle` and display targets return a `DisplayTarget`.
- **The observer channel must enforce view-only itself.** Observer links are authenticated, carry expiring tokens, and are **view-only**. An authenticated stream (WebRTC, MJPEG, or similar) is the preferred observer channel because it carries no input path. A standard VNC server cannot be held to view-only outside takeover, so VNC is acceptable only behind a proxy that drops input events, or with the server's view-only credential for observers and a separate credential issued only for takeover.
  - **Tokens govern connecting, not staying connected.** A token is short-lived and single-use for establishing the connection. An established stream lasts until it is revoked or the lease is released.
  - **Revocation.** Releasing the lease revokes every observer connection. The user can revoke one from the oversight surface.
  - **Two kinds of link.** A *user link* is issued to a user authorized on the conversation, through that user's authenticated surface. An *observer link* is view-only and may be shared with someone who is only watching. Takeover is bound to the **user's identity**, not to a live-view connection, so it can start from the oversight surface as well as from the live view.
  - **During takeover,** input is accepted on user links of that conversation and never on observer links. Each link connects once, and the user can revoke any single connection. The model's capture is suspended. Observer links see a paused frame, because the user may be typing a credential.

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
  | { kind: "press"; at: Target }                                      // semantic element action (AX press / DOM activation)
  | { kind: "set-value"; at: Target; value: string }                   // semantic; read back to confirm
  | { kind: "menu"; path: string[]; app?: string }                     // semantic menu walk
  | { kind: "launch"; app: string; background?: boolean } | { kind: "open-url"; url: string }
  | { kind: "wait"; ms: number } | { kind: "wait-for"; condition: WaitCondition; timeoutMs: number }
  | { kind: "observe"; request: ObserveRequest }                       // screenshot / zoom / tree
  | { kind: "zoom"; region: Rect; observation: string }                // full-res crop, coords stay in parent space

type WaitCondition =                 // evaluated by the driver against fresh snapshots; never natural language
  | { element: "appears" | "disappears"; role?: string; name?: string; ref?: string }
  | { url: "matches"; pattern: string }                 // browser targets
  | { window: "appears" | "disappears"; app: string; windowId?: string }   // against describe()'s window list
  | { value: "equals" | "contains"; ref: string; text: string }
  | { screen: "settles"; quietMs: number }              // no visual or tree change for quietMs

type ActionOutcome = {
  action: number                     // index in the batch
  effect: "confirmed" | "unverifiable" | "suspected-noop" | "partial" | "refused" | "not-executed"
  evidence?: string                  // e.g. "value read back", "focused element changed", "no visual change"
  escalation?: "observe" | "foreground" | "pixels" | "ask-user"   // what should happen next
  observation?: string               // fresh observation id when the action produced one
}
```

Notes:

- **Semantic actions are first-class.** `press`, `set-value`, and `menu` survive window moves, scaling, and occlusion, and they work without stealing focus. Pixel `click` is the fallback.
- **`click` and `press` are interchangeable on desktop targets only.** A desktop driver may implement `click` on a ref as an accessibility press and report which it used. In a browser they differ: a script-dispatched DOM click is an untrusted event that some pages ignore. On DOM targets, `click` on a ref is a trusted pointer event (dispatched through the browser's input domain) at the element's live center after scrolling it into view. `press` is DOM activation, used only when the model asks for it.
- **Every pointer action cites an observation.** Acting on a ref or point from observation `o` re-resolves the element first. If it drifted, the action is `refused` with `escalation: "observe"`, not guessed. What "drifted" means depends on the tree:
  - **Accessibility trees:** same role and label, frame within tolerance, same process generation. Process ids are recycled, so the receipt pins process start time as well as pid.
  - **DOM:** the same node identity (the browser's backend node id) with the same role and accessible name. Position is not compared, since DOM elements move whenever the page scrolls; the click point is recomputed from the live frame.
- **`wait-for` takes a structured condition.** A natural-language condition can't be evaluated by any driver. Element, URL, and value conditions are checked against fresh observations. Window conditions are checked against the window list from `describe()` (`TargetLayout`), by app and window id only. That list follows the same exclusion as observations: windows of granted apps only, never the harness's own. Display geometry is always listed. A window condition naming an app outside the grant is refused as out of grant; otherwise `describe()` would be a way around the observation filter. Window titles are attacker-controlled screen content, so no condition matches on them. A driver that can't evaluate a condition kind treats it as a bounded wait followed by an `observe`, and says so in the evidence.
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

- **The harness resizes before sending, at capture.** It never relies on server-side downscaling. At least one vendor now rejects tool-result images above its long-edge, pixel-area, or visual-token cap rather than resizing them. Read the caps from the model's `features["computer-use"].params` and `limits.maxImageEdgePx` in [model-classes](../../core/model-pool/model-classes.md#the-descriptor-contracts-facets-offering). Bound the pixel area too (`maxPixels`): a long-edge cap alone lets a near-square image exceed an area limit.
- **Nothing downstream may resize a geometry-bound image.** The capture is sized to the tightest of the model's caps and the result pipeline's own image cap, so the [result sanitizer](../../core/tool-system/result-formatting.md#image-sanitization-at-the-dispatch-boundary) never needs to change its dimensions. The sanitizer may still canonicalize and recompress such an image. If it can't fit the image without resizing, it replaces the image with its marker. A resized screenshot would silently move every click.
- **Every image sent carries its `ScreenshotGeometry`**, and the codec maps model coordinates back through it: `x_pt = captured.minX + x_img · captured.w / image.w`. Multi-display layouts can have negative origins. HiDPI displays need the backing scale factor.
- **The coordinate mode is frozen at session start.** If configuration could switch pixels ↔ normalized mid-session, the tool description the model read and the scaling the codec applies could disagree. That is a silent misclick on every action.
- **Silent rescaling beats telling the model the scale.** A note like "multiply coordinates by 1.37" asks the model to do arithmetic it does poorly. The codec rescales and the model never sees the factor.

### Model dialects: native toolsets vs. harness tools

The Tool System registers **one computer-use tool family** per session, bound to a display-target lease. How it is presented to the model depends on the model's `computer-use` feature:

- **Native toolset available** (a versioned vendor toolset on the `generate` contract). The provider codec emits the vendor's declaration, decodes its action calls into canonical `Action`s, and encodes results back:
  - batched tool-use blocks with stop-at-first-failure, where unexecuted blocks still get a "not executed" result;
  - an ordered `actions[]` array per call;
  - per-action `intent` fields. These are the model's own claim. They are logged and may be shown on approval cards, labeled as the model's stated intent, but they are **not** input to classification or to the intent check.
  - Vendor safety signals map onto the harness's confirmation machinery: pending safety checks that must be echoed as acknowledged, and `require_confirmation` decisions that need an acknowledgement in the result. **They are never auto-acknowledged** (see [§ Safety](#safety-is-layered-not-a-single-gate)).
  - **A signal attached to a whole call** rather than one action applies to every interact or consequential action in it. The user confirms the call once, on a card listing its actions, before the first one runs. A signal can raise an action's class, never lower it, so a signal on an observe-class action still means confirm.
  - **A native toolset may live on a different API than the provider's default.** For example, one vendor serves its computer tool only through its stateful responses API. The feature descriptor records which API the toolset needs, and the provider codec selects it for the computer-use binding.
  - **Some vendor APIs keep the conversation server-side.** Their computer-use calls continue from a stored response that holds reasoning state the client never sees. The vendor then retains every screenshot it was sent: harness-side pruning bounds what is resent, not what the vendor stores, and retention is the vendor's policy. Record this on the binding (for example `dataRetention: "vendor-stored"`). Offer a stateless mode where the vendor has one. Exclude such bindings from the `computer-use` role for users or operators who require zero retention, and say so in onboarding.
- **No native toolset.** The harness exposes function tools with element-ref-first schemas: `computer_observe`, `computer_click(ref | point)`, `computer_type`, `computer_key`, `computer_scroll`, `computer_press`, `computer_set_value`, `computer_menu`, `computer_launch`, `computer_open_url`, `computer_zoom`, `computer_wait_for`, `computer_verify`, `computer_finish`, `ask_user`. Use one flat object schema per tool, because some providers reject nested `anyOf` unions in tool parameters. Arguments outside a tool's schema are rejected, not ignored.
- **Code execution as a peer path.** At least one vendor now recommends its top model write automation scripts in a sandbox instead of driving the computer tool. Treat that as rung 2 of the ladder (scripting) inside the leased target. Do not bypass the target. A script is gated as a whole rather than per action (see [§ Alternatives](#code-execution-instead-of-a-computer-tool)), and what it may reach depends on the target:
  - **Browser targets:** browser-automation scripts run against the leased browser under its domain grants and network policy, which the browser itself can enforce.
  - **Isolated desktop targets** (`container`, `vm`): desktop scripts are allowed when the grant covers the whole target, since nothing outside it holds user data.
  - **Host desktop:** per-app grants cannot hold a script. AppleScript, shell-driven input, or an input-automation library can reach any app. Desktop scripts are allowed only through mechanisms whose target app is a parameter the harness validates against the grants before running (an Apple Event addressed to a granted app, a named shortcut whose actions are known). Free-form desktop scripts need a grant covering every app, which is not offered by default.
- **Tool results must carry images as images.** The provider codec must encode a screenshot in a tool result as an image block in the vendor's format, never as base64 text inside a string. A harness that stringifies image content from tool results gives the model no vision and blows up the context. This includes images arriving from MCP servers. Where a vendor's tool results can hold only text, the codec puts the image in the next user-role message, labeled with the tool call id it belongs to, and leaves a marker in the tool result. If the vendor has another API whose tool results can hold images, prefer that API for the computer-use binding.
- **One tool result can mix harness text and screen text.** Harness-written lines (outcome, evidence, budget, constraint reminder) stay outside the untrusted envelope. Screen-derived text (tree, OCR, page text, titles) goes inside it. Never wrap the harness's own guidance as untrusted, and never let screen text sit outside the envelope.

### Sessions, leases, grants, and tiers

```ts
type LeaseRequest = {
  target: string                       // display-target id
  conversation: string; agent: string
  initiator: TrustClass                // trust of whoever started the work (operator, non-owner, trigger)
  userPresent: boolean                 // an interactive user is attached and can answer approvals now
  grants: Grant[]                      // requested; user approves a subset
  budgets: ResolvedBudgets             // host policy combined with the task's request; see § Budgets
  delivery: "background-only" | "foreground-allowed"
}

type Grant =
  | { app: string; tier: "view" | "click" | "full"; flags?: ("clipboard-read" | "clipboard-write" | "system-keys")[] }
  | { domain: string; tier: "view" | "click" | "full" }
```

- **`initiator` and `userPresent` drive three rules:** host targets require an operator initiator and a present user, non-operator work never gets a host target, and leases without a present user get the short absolute expiry below.
- **One controller per target.** Acquire with an atomic, exclusive lock whose holder can be identified and checked for liveness, so a crashed holder doesn't block the target forever. When the target is driven through a separate host process, liveness is the connection: a holder whose connection drops keeps the lease for a short grace period to reconnect, then the host releases it with `holder-lost`. A second session gets a typed `target-busy`, not a fight over the cursor.
- **Grants are per session and per app or domain, with tiers.**
  - *View*: the app appears in observations. The agent cannot act on it at all, including scrolling or launching it.
  - *Click*: pointer and navigation actions (`click`, `press`, `scroll`, `move`, `drag`, `launch`, `open-url` in a browser), but no typing, keys, or menus. This is the right default for terminals and IDEs, since typing there is shell access.
  - *Full*: everything, including typing, keys, and menu walks. A menu reaches the same commands as shortcuts, so it needs the same tier.

  At grant time the dialog states the real blast radius of apps whose access is effectively broader than the app: shells and IDEs, file managers, and system settings. This template additionally recommends **blocking by default** the categories vendors have flagged as high-harm: investment, trading and crypto platforms and other financial services. Password managers belong on the same list. These categories need an explicit operator override. **Categories are decided at grant time** from facts the harness can look up for the requested grant: an app's bundle id and its declared app category, a domain against a category list. They are re-checked when an action lands in an app or domain that wasn't in the original request. Window titles and page text are never used.
- **What a browser grant covers.** A desktop browser has two parts. The **browser chrome** (address bar, tabs, menus, settings) is the browser app and needs an app grant. The **page** is the web content area, and a domain grant covers pages on that domain.
  - **Which part an action hits.** An element is on the page when it belongs to the web content subtree: a descendant of the web area in an accessibility tree, or any DOM node on DOM targets. An element that carries a document URL is a usable proxy where the web area isn't exposed. A point is on the page when it lies inside the observation's `pageBounds`. Everything else is chrome.
  - **Page content with no known address is refused, never treated as chrome.** A web area that doesn't expose its URL leaves no domain to check, and falling back to the browser's app grant would let it authorize actions on a domain that was never granted. Such an action is `refused` with `escalation: "observe"`. To reach a page, the model uses `open-url`, which has an address to check. Drivers for browser targets must report `pageBounds`. Without it, every pixel action counts as chrome and needs the app grant.
  - On a managed browser, the driver scopes observations and actions to granted domains. A tab on a non-granted domain is reported by URL only.
  - On a desktop browser granted as an app, domain scoping can't be enforced from outside the browser: an app grant shows whatever pages are open in it. The grant dialog says so ("granting Safari shows any page open in Safari"). Prefer a managed browser or the user's real browser through its extension, which can scope by tab.
- **Sharing the user's real browser.** The agent sees and acts only on tabs it opened, or tabs the user explicitly shared (a tab group or a "share this tab" control), never every open tab. Downloads go to a lease-scoped folder and are never opened automatically. They are kept in place at release, and those the specialist names in `keepFiles` are also copied to the conversation's attachments, so the parent reaches every kept file the same way. Every download is listed in the result's `downloads`.
- **Managed-browser events.** JavaScript dialogs (`alert`, `confirm`, `prompt`, `beforeunload`) pause the page and appear as an observation the model must answer with an explicit action. They are never auto-accepted. Popups open as new tabs under the same domain grants and policy. Downloads go to a lease-scoped folder. At release, every file is deleted except those the specialist named in `keepFiles` on its [`computer_finish`](#verification-ask-user-and-handoff-are-actions) call. The result's `downloads` lists every file with whether it was kept. Kept files move to the conversation's attachments. Nothing is kept by matching names in the result's text.
- **Kept downloads are attachments of unknown origin.** From either browser, a kept file's attachment copy is subject to the attachment size cap and is tagged `unknown-party`: it is downloaded content, not something the user handed over.
- **Where untargeted input goes.** A `type` or `key` without `into` is delivered to the **working app**: the app of the most recently cited observation, which must be granted at `full`. On background-delivery targets it goes to that app's focused element by process-routed delivery. It never goes to the frontmost app just because it is frontmost. On a shared desktop the frontmost app is usually the user's, or the harness itself.
- **Approval is one dialog at session start, not one per click.** The user approves the grant set. Per-action confirmation is reserved for consequential actions (below). Grants expire with the session. Sessions spawned without a present user (delegated or background) get a short absolute expiry, measured in tens of minutes. Budget extensions never move it.
- **Non-granted apps are excluded from observation and protected from input.**
  - **Observation:** filter capture, trees, and OCR to granted apps. Filtering meets the rule, so hiding the user's windows is not required, which matters on a shared desktop where hiding is disruptive. Exclude the harness's own UI (terminal, chat window, overlays) from every capture. The model must never read its own transcript or approval prompts off the screen.
  - **Input:** a foreground pointer action at a point is hit-tested first. If the window under the point belongs to a non-granted app, the action is `refused` with `escalation: "observe"`. Hiding non-granted windows remains an option for targets that can't hit-test. If used, restore them at turn end, on abort, and on crash, with a timeout so cleanup can't wedge.
- **Budgets grow on progress and stop at a ceiling.** Every way a session can run out produces a typed terminal reason. See [§ Budgets, progress, and extensions](#budgets-progress-and-extensions).

### Budgets, progress, and extensions

One fixed wall-clock budget cannot do two jobs. Set short, it ends real work: with model turns of 20–55 seconds, a 3-minute budget buys four to seven turns. Set long, a stuck session burns all of it before anything notices. So the budget is split by job, and each limit is set by whoever has the information to set it.

| Limit | Set by | Job | Extended? |
|---|---|---|---|
| Step allotment | the task (parent), else the host default; clamped to the ceiling | expected size of the work | yes, on progress |
| Step ceiling | host | cap on long work | only by a present user |
| No-progress window (in attempted actions) | host | catch a session that is busy but going nowhere | no |
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
  noProgressSteps: number       // consecutive attempted actions (steps + refusals) without progress; e.g. 8
  maxDuration: Duration         // wall-clock ceiling for the session
  maxUsd?: number               // never extended automatically
}

// What a lease carries: the policy combined with the task's request.
// The three time limits stay separate because they follow different extension rules.
type ResolvedBudgets = {
  steps: number                 // current allotment; starts at min(task.steps ?? defaultSteps, ceilingSteps)
  ceilingSteps: number          // a present user can raise it at the ceiling
  extensionShare: number
  noProgressSteps: number
  timeCeilingAt: string         // lease grant + maxDuration; a present user can extend it at the ceiling
  deadline?: string             // from the task; never extended
  grantExpiresAt?: string       // absolute expiry for leases without a present user; never extended
  maxUsd?: number
}
// Derived, never stored: endsAt = earliest(timeCeilingAt, deadline, grantExpiresAt)
```

The time limits start when the lease is granted, after the user closes the grant dialog. Time spent waiting for that approval isn't charged to the task.

- **The parent sizes the work in steps, never in minutes.** A step is one action delivered to the driver. Actions that come back `not-executed` or `refused` don't consume the allotment (but refusals do count toward the no-progress window, below), and neither do harness-side tools such as `verify`, `ask_user`, and `handoff`. A parent can estimate that "open the app and fill in the form" is about fifteen actions. It can't estimate how long a different model will think, so the delegate tool exposes no time budget. Time limits belong to the host and are generous. They bound the session; they don't measure the work.
- **A deadline is a cutoff, not an estimate.** The task carries `deadline` only when the user or the task states a real one ("before my call at 3"). It can only make `endsAt` earlier, and progress never extends it. When it passes, the session ends with `deadline`.

#### What counts as progress

Progress is decided only from facts the harness recorded. It is never the model's claim that it is nearly done, and never screen text. Progress is recorded against the session's step count when it happens, and the session **made progress at step *n*** when either of these holds:

1. **A success criterion was newly verified.** A `verify` call recorded `met: true` for a criterion that had not been met before. `verify` is not itself a step, so the progress is recorded at the current step count. This is the strongest signal.
2. **The agent reached a new state.** All three conditions must hold:
   - **The state is new.** Its fingerprint is not in the set of fingerprints this session has already observed. Returning to an earlier state never counts, which is what catches oscillation (open a menu, close it, open it again).
   - **An acting step caused it.** The state was first observed after an action that does something, not after `observe`, `zoom`, `wait`, or `wait-for`, and not during takeover. A page that finishes loading on its own doesn't earn progress.
   - **The action wasn't a known failure.** Its effect was `confirmed`, `partial`, or `unverifiable`, not `refused`, `suspected-noop`, or `not-executed`. Requiring `confirmed` would starve pixel-only targets, where legitimate clicks often can't be confirmed.

**The state fingerprint is coarse and structural.** It is a digest of the observed app (the app of the observation's target, never the frontmost app, which on a shared desktop is usually the user's or the harness's), the window identity, the URL or document identity, the focused element's role where the snapshot exposes focus, and the shape of the accessibility tree or DOM. The shape is the sequence of element roles in the compact tree, with indentation as nesting, not text or values. It can be computed from the same snapshot the model sees, with no extra fields on `ElementRef`. A clock ticking, a feed adding items, or a toast changing its text then mostly doesn't produce a new fingerprint. On pixel-only targets the fingerprint is limited to app, window, and URL identity, so it is coarser there. Fingerprints are only compared, never shown to a model, so screen content can at worst make states look new, and the ceiling bounds that case.

**One progress predicate serves every check.** The extension check and the no-progress window read the same predicate, so they can never disagree about whether the session is moving. An agent wandering through genuinely new but unhelpful screens still looks like it is making progress. No rule built only on harness-recorded facts can tell wandering from exploring. The ceiling covers that case, and a verified criterion remains the stronger signal.

#### Extensions

- **When.** When the step allotment runs out, the harness grants an extension if any step since the last grant (or since the start) made progress.
- **How much.** `extensionShare` of the first allotment, rounded up, never past `ceilingSteps`.
- **At the ceiling.** With a present user, the session pauses and asks whether to continue. This is an approval card with the decision vocabulary from [approval UX](../../surfaces/interface/approval-ux.md) (continue or stop), not a free-text `ask_user` question whose answer would need parsing. Continuing grants one more extension of steps, and the question comes again at the next ceiling. The time ceiling works the same way: continuing moves `timeCeilingAt` out by `extensionShare` × `maxDuration`. Without a present user, or if the card times out, the session ends with `budget-exhausted`.
- **Never extended.** Cost, the deadline, and the absolute grant expiry of unattended sessions. Extensions grow the work, never the authority.
- **Visible.** Each grant is written to the action log with the facts that justified it (criteria newly verified, new states reached since the last grant) and shown on the activity indicator ("step 34 of 45, extended twice"). Grants are not approved one by one, because asking per extension causes the same approval fatigue as asking per click.

#### Ending a session that isn't moving

- **No progress.** When `noProgressSteps` consecutive attempted actions pass without progress, the session ends with `no-progress`, whatever allotment remains. Attempted actions are steps plus `refused` actions, so a session refused at every turn still fills the window. Counting actions rather than seconds makes the check behave the same on a fast model and a slow one.
- **Repeated failure.** After 2–3 consecutive failing batches (a batch in which any action came back `refused`, `suspected-noop`, or `partial`), escalate to `ask_user` rather than looping. The harness can't see subgoals, so consecutive failing batches stand in for "the same subgoal". The counter resets on the user's answer. If it reaches the threshold again before any progress, the session ends with `no-progress` instead of asking again.
- **Idle.** A model call or driver that produces nothing at all is caught by the Sub-Agent Pool's [idle timeout](../../core/sub-agent-pool/#idle-timeout-liveness-not-progress), which applies to every delegate. Size it for the computer-use model binding: at least twice the slowest expected model turn, since some providers stream nothing while the model thinks.

#### One clock, not two

The specialist runs as a child of the Sub-Agent Pool, and that child has its own run timeout. If that timeout is configured separately, it ends the run while the lease is still being extended, and the extensions do nothing. The child's run timeout is **derived from the lease**: the derived `endsAt` plus a short cleanup grace, recomputed whenever a present user moves `timeCeilingAt`. The session's terminal reason, not the child's timeout, decides the result status.

**Waiting on the user is exempt from per-call tool timeouts.** `ask_user`, `handoff`, takeover, and approval cards wait as long as their own timeouts allow (below). A generic per-call timeout in the Tool System must not cut them off.

### Permission classification per action

Computer use plugs into the existing Tool System machinery ([permissions](../../core/tool-system/permissions.md)) with **argument-level classification**. The tool is polymorphic, so its effect class depends on the action:

| Action class | Actions | Minimum tier | Effect | Default gate |
|---|---|---|---|---|
| Observe | `observe`, `zoom`, `wait`, `wait-for`, cursor position | view | read-only | allow within grant |
| Navigate | `scroll`, `move`, `launch` (granted apps only), `open-url` (**`http(s)` only**, allowed domain, opened in a browser granted at click or above) | click | low | allow within grant |
| Interact | `click`, `press`, `drag`, `pointer` | click | mutating | allow within grant + intent check. With no intent checker bound, **confirm** on `humanPresence: shared` targets unless the operator explicitly opts out. |
| Interact | `type`, `set-value`, `key`, `hold`, `menu` | full | mutating | as above |
| Consequential | any of the above when it submits, sends, buys, deletes, or installs; typing into password or payment fields; accepting terms; system-settings changes; anything a vendor safety signal flags | the action's own tier | irreversible | **confirm** (per action, even inside a batch) |
| Out of grant | any action on a non-granted app or domain, a tier violation, global shortcuts without `system-keys`, `open-url` with a non-web scheme (`file:`, `tel:`, custom app schemes dispatch to other apps and bypass app grants) | — | — | deny, with the reason returned to the model |

- Classification is computed by the harness from the action, the target element, the app or URL, and the grant, never from the model's own claim. The vendor `intent` field plays no part in it (see [§ Model dialects](#model-dialects-native-toolsets-vs-harness-tools)).
- **Labels can raise a class, never lower it.** Role, app, bundle id, and URL are harness-derived and decide the base class. On-screen labels and titles are attacker-controllable: a label like "Delete" or "Pay" may raise an action to consequential, but a destructive control relabeled "OK" must not drop below what its role and context imply. The same rule applies to menu paths, whose item names are screen text.
- **Return is classified as the action it triggers.** Typing into a form and pressing Return submits it without a consequential control ever being touched. So a Return or Enter key (or typed text ending in a newline) while focus is in a form field is classified as a press of that form's default or submit control, found from the tree (the window's default button, or the form's submit element in the DOM). That control's role and label then decide whether it is consequential. When no such control can be determined, the action stays Interact and relies on the intent check. This is a known gap on pixel-only targets.
- **Computer-use gating replaces the mode's per-tool approval for computer actions.** A mode whose default decision is "ask for everything" would otherwise double-gate every click on top of this table. The mode's policy applies to starting the session (the delegate call and its grant dialog). Inside the session, this table decides. A mode can make computer use stricter but cannot loosen Consequential. It has two levers ([modes § `ModeProfile` shape](../../core/conversation-manager/modes.md#modeprofile-shape)): a `tools.deny` entry naming the computer-use delegate tool, and `subAgents.computerUse.confirmInteract`. Only a `deny` entry denies computer use down the chain. Leaving the delegate off an allow-list is capability, which each child is assigned afresh, so it affects only that conversation.
  - **Every ancestor's mode applies.** The modes of the conversation that delegates and of every conversation above it, up to the user's root, all apply, and the strictest wins. These are policy restrictions, not capability, so unlike a child's mode they accumulate down the delegation chain. A nested delegate in an ordinary mode can't escape a strict mode above it.
  - **Mode changes during a session.** The modes are read when the session starts. A later change on any of those conversations that makes the policy stricter applies from the session's next action. A change that loosens it applies only to sessions started afterwards.
  - **A denial that arrives mid-session ends the session.** An action already in flight finishes; the rest of its batch comes back `not-executed`. The session ends before its next action with release reason `policy-revoked`, and the result is `blocked` with `reason: "policy-revoked"`. This is distinct from `permission-revoked`, which means an OS permission was revoked and the user must re-grant it. A policy revocation means the user changed policy, so the parent must not retry. The same mode denies the parent's next delegate call, so a retry loop can't form.
- **Confirmation is per action inside a batch.** One batch can complete a multi-step flow (fill form, then submit). The approval check runs before each action, and a refusal stops the batch with "not executed" for the rest.
- **Approval binding applies.** The confirmed action's canonical form (action, target ref, observation id, typed text hash) is what was approved. A drift between approval and execution invalidates it. That is the same exact-action binding the permissions page requires for shell commands.

### Safety is layered, not a single gate

No single control is sufficient. Measured attack success rates for browser agents dropped from tens of percent to near zero only when several layers were stacked, and hardening proved **domain-specific**: the same weights that resisted browser injection were highly vulnerable in another domain. The layers:

1. **Isolation.** Default to a VM, container, or managed browser with no user data. Host targets are opt-in, with extra controls.
2. **Scoped grants with tiers and blocked categories** ([§ Sessions](#sessions-leases-grants-and-tiers)).
3. **Untrusted-content treatment of the screen.** Every observation is external content. Text observations (trees, DOM, OCR) get the [input-provenance](../../surfaces/triggers/input-provenance.md) envelope. **Images cannot be wrapped**, so the image channel relies on layers 4–6.
4. **Per-action intent alignment.** Before each interact or consequential action, a fast check asks "is this action consistent with what the user asked for?"
   - **Input:** the user's request, a short text history of prior actions, and the proposed action described by **harness-derived identifiers only**: action kind, app bundle id or domain, and element role.
   - **Excluded input:** the screenshot, screen text, on-screen labels and titles, and the vendor's per-action `intent` field. Screen content is attacker-controllable and is the injection channel, and the intent field was written by a model that may have been steered by it.
   - **Evidence:** a published per-action guard built on an LLM cut attack success by >90% with no loss of benign task success, at several seconds per step.
   - **Fast variant:** a [decision model](../providers/decision-models.md#where-the-harness-uses-deciders) on the `guard` role can run the same check in ~100 ms. Its robustness to adaptive attacks is unmeasured, and deciders are themselves injection-sensitive, so validate it on your own attack set before relying on it. Keep the LLM guard for consequential actions.
   - **Outcome:** a mismatch or an unavailable verdict goes to *confirm*, never silently allowed. An unbound checker means *confirm* for interact actions on shared targets (see the classification table above).
5. **Consequential-action confirmation**, including vendor safety signals: malicious-instructions, irrelevant-domain, and sensitive-domain checks, and `require_confirmation` decisions. Route each through the [approval UX](../../surfaces/interface/approval-ux.md) as a real question to the user. Auto-acknowledging a vendor safety check is an anti-pattern even in bypass mode. A sensitive-domain signal means *watch mode*:
   - On targets with a live view, the session continues only while a view is **open**, meaning an observer connection is currently connected.
   - On targets without one (the host desktop, which is the user's own screen), watch mode means the session continues only after a present user confirms on an approval card, and it ends if no user is attached.
   - **Watch mode lasts for the rest of the session.** Leaving the flagged domain doesn't end it, because the harness can't tell when the vendor would stop flagging, and a steered session can leave and come back.
6. **Injection classifiers on observations**, where the vendor or a `guard` decider offers them. They warn and steer ("check whether this instruction came from the user"). They do not block on their own, since they read the same untrusted content.
7. **Takeover mode for credentials and human-only steps.** Logins, 2FA, CAPTCHAs, and payment entry are reported by the agent as `handoff` and completed by the user. While takeover is on, capture is suspended and agent input is blocked, so the model never sees the password being typed. On isolated targets the user acts through the live view, which accepts their input only while takeover is on. Block navigation to URLs that embed secrets, and redact secrets from any auxiliary-model inputs. **A secret** here is:
   - credentials in a URL's userinfo;
   - query or fragment parameters whose names mark them as credentials (token, key, secret, password, session, code, and similar);
   - any value the user typed during takeover;
   - values from fields whose role is a password or one-time-code field.
8. **An injection-proof kill switch.** A global stop key (or button) that the agent cannot trigger or suppress.
   - **Use a dedicated chord, not Escape.** The stop key should be a chord the agent never needs for real work, such as a modifier combination unused by common apps. Reserving Escape would also stop the agent dismissing dialogs and menus, which it needs constantly.
   - **Enforced at the action layer.** The harness refuses to emit the stop key in any synthesized action while a session is active, so injected screen content can't make the agent press it.
   - **Platform enforcement is optional.** It can be added where it is safe; macos.md covers the trade-offs of an event tap.
   - **Abort and indicator.** The abort runs the full cleanup path and declines every pending approval card, question, and handoff on the session. An OS-level indicator saying the agent is in control, and how to stop it, stays visible for the whole session.
9. **Network policy for isolated targets.** Browser targets, desktop containers, and VMs all get a network policy. SSRF checks fail closed, applied before navigation and on the final URL after redirects, with private-network access opt-in and domain allow and block lists.
   - **Private network** means loopback, link-local (including cloud metadata addresses), RFC 1918 and carrier-grade NAT ranges, IPv6 unique-local, and any range the operator adds.
   - **Policy lists and grants are separate checks.** The allow and block lists are network policy: what the target may reach at all. Domain grants are authority: where the agent may act. A navigation must pass both.
   - **Where the boundary sits.** For `container` and `vm` targets, the boundary is the target's network namespace and its egress filter. For a `process` target (a locally launched browser on the host's network), there is no namespace, so the browser enforces the policy itself through request interception or a mandatory proxy, covering every request including subresources. Origin allowlists in browser-automation tools are hygiene, not a security boundary.

### Context budget for screenshots

- **Size to the model.** Resize at capture to the binding's `maxImageEdgePx`, pixel-area, and visual-token caps (see [§ Coordinate contract](#coordinate-contract-and-screenshot-geometry)). A screenshot costs roughly 1–2K input tokens at typical sizes. Above ~20 images per request, at least one vendor lowers the per-image cap, so the retention policy should keep requests under that count.
- **Keep the last N, prune in batches; the image cap wins.** Keep the most recent ~3 screenshots in full. Replace older ones with a marker line written by the harness from the receipt: observation id, app, window, and step (`[screenshot o_7f3c pruned: TextEdit "Untitled", step 12]`). It needs no model call. Prune in batches rather than every turn, so the cached prefix stays byte-stable between prunes. Choose the batch size K so that keep + K stays under the per-request image cap: against a ~20-image cap, keep 3 and prune every 15. Vendor guidance of "keep 3, prune every ~25" predates the cap and would allow 28. This is the [cache-aware](../../core/context-engine/cache-aware-operations.md) version of the attachment-inlining page's K-most-recent rule.
- **Count steps, not user turns.** A policy that prunes after N completed user turns never fires inside a single 200-step computer-use turn. Retention counts observations within the loop.
- **Prefer text deltas.** After the first full tree, send diffs. After an action whose effect is `confirmed` by tree evidence, a fresh screenshot is optional. Request one when verification needs pixels.
  - **Diffs need identities that outlive one observation.** Element refs stay per-observation (a ref is valid only with the observation that issued it), so a diff is keyed by a separate stable key: the platform identifier where one exists (DOM backend node id, AX identifier), else the role path from the window root plus sibling index.
  - **Diff format.** A diff lists removed, added, and changed lines of the compact tree, each line carrying its stable key and its new ref, against the cited base observation. Fall back to a full tree when more than about half the lines changed, or when the window or document changed.
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
  result?: unknown                     // validated against returnSchema; untrusted in the parent
  missingGrants?: Grant[]              // grants the task needed but didn't have (from out-of-grant denials)
  downloads?: { name: string; bytes: number; kept: boolean; attachment?: string }[]   // attachment: blob id of the copy when kept (both browsers)
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
- `blocked` with `missingGrants` means the task needs authority it wasn't given. The parent can ask the user to grant it and delegate again.

**The result is validated, and its text is untrusted.**
- **Validation.** When the task has a `returnSchema`, the harness validates `result` against it. On a mismatch the `computer_finish` call is rejected with the validation errors, and the specialist gets one chance to call it again. After that, `result` is omitted and `reason` says why.
- **Trust.** `result`, `evidence`, and `handoff.prompt` were written by a model whose context was full of untrusted screen content, so they can carry injected instructions to the parent verbatim. The parent receives them inside the [input-provenance](../../surfaces/triggers/input-provenance.md) envelope as content the specialist reported, never as instructions. Schema validation narrows the channel. Enums, numbers, and booleans carry no instructions, so prefer a `returnSchema` made of them over free-text fields.

Why this is the default for long tasks:

- **Context isolation.** Screenshots and raw screen text live in the sub-agent's context and never in the parent's. The parent receives a structured, validated result. That narrows the injection channel but doesn't close it: the result's free text is treated as untrusted (above).
- **Authority isolation.** The sub-agent's tool set is the computer-use family plus `verify`, `ask_user`, `handoff`, `computer_finish`, and a scratchpad. It has no shell, no file writes, and no outbound messaging unless the task explicitly grants them. The **scratchpad** is a harness-held notes tool: the specialist writes and reads short notes (what it has tried, values it found) that survive screenshot pruning. Notes live only in the specialist's context and are never sent to the parent.
- **Model choice.** The `computer-use` role can bind a model tuned for GUI work, including small open models that score well on web tasks, while the parent stays on its planner. A `grounder` role can back a cheaper model that plans in text but cannot localize precisely.
  - **A grounder's answer** is `{ point: { x, y }, space: "image" | "grid", gridSize?: number } | { notFound: true }`, optionally with a confidence. `image` means pixels of the image it was sent. `grid` means its declared native grid. The codec maps either back through the observation's geometry, so a grounder's point is used like any pixel `Target`.
- **Constraint retention.** The task's constraints and success criteria are re-injected into every step. They are pinned in the specialist's system prompt, which pruning never touches, and restated as a compact harness-written reminder line in each observation result, outside the untrusted envelope. That directly counters the dominant long-horizon failure.

**Where the specialist's questions go.** Its approval cards, `ask_user` questions, handoffs, and ceiling cards go to the nearest ancestor conversation with an interactive surface attached, normally the user-facing conversation that delegated. They are tagged with the specialist's path so the user can see which delegate is asking. With no interactive ancestor, they resolve as if unanswered.

Tool schemas for computer use run to several thousand tokens. Keep them deferred or searchable in the parent and loaded only in the sub-agent.

### Verification, ask-user, and handoff are actions

- `verify(criterion)` asks the loop to check a post-condition against a fresh observation and record evidence. **Fresh** means captured after the last delivered action completed (its sequence number is higher), never a cached or earlier observation. The sub-agent cannot return `done` until every success criterion has a `verify` entry. A completion without full verification is reported as `done-unverified`, and the parent decides whether to check further or tell the user.
- `ask_user(question)` pauses the loop and routes through the conversation's surfaces. It beats guessing, and published long-horizon failures are dominated by guessing.
- `handoff(reason)` starts takeover mode for human-only steps and resumes when the user hands back control.
- `computer_finish(result, keepFiles?)` is how the specialist ends. It is a halt-signal tool, and the specialist runs under the [`terminal-tool` termination policy](../../core/agent-runtime/README.md#termination-policy-and-stall-recovery), so a turn that stops without calling it is a stall, and stall recovery forces the call. It is the single moment the specialist commits:
  - `result` is validated against `returnSchema` here.
  - `keepFiles` is an array of paths relative to the lease's download folder. Paths outside it are rejected.
  - Verification status, budget, and `downloads` are filled in by the harness, never by the specialist.
- **They time out.** Defaults are on the order of 10 minutes for `ask_user` and ceiling cards, and 15 minutes for a handoff, since the user may be fetching a 2FA device. A timeout or a stop ends the session with `needs-user`, carrying the open question or handoff, so the parent can relay it.
- **Never auto-retry a possibly-delivered action.** If a click that may have submitted a form returns `unverifiable`, the next step is `observe`, not a second click. Double-submits are the classic computer-use incident.

### Oversight surfaces

Surfaces that support it declare a `computer-use` capability and render:

- **A live view.** An authenticated stream, or VNC behind a view-only control (see [§ Display targets](#display-targets-as-an-execution-environment-family)). It accepts input only from the user who started a takeover. A sensitive-domain session requires it to be open, or, on targets without one, a present user's confirmation.
- **An activity indicator.** "Agent is using <target>", with the current app, the step against the current allotment, and how many times the allotment was extended. It is visible outside the chat window on host targets. In the in-process development mode there may be no separate host app to draw it. The harness's own surface then shows it, and that mode is labeled as development-only.
- **Per-action approval cards** for consequential actions, showing the action, target element, a cropped image of the target region, the intent-check verdict, and, labeled as such, the model's stated intent if the vendor sent one. The crop uses the presentation vocabulary's `image` block, which surfaces that can't render images degrade to its alt text (see [Interface § portable presentation](../../surfaces/interface/README.md#the-portable-presentation-payload)). A remote surface fetches the crop through the conversation-scoped blob route in the [Communication Layer](../../core/communication-layer/).
- **Takeover and stop controls.** Stop is also bound to the global kill switch on host targets.
- **A post-run replay.** Action log plus observation thumbnails, and a recording where the target supports it. Replays are indexed by conversation and run id and listed on that conversation, so they can be found after the session ends.

Headless runs (scheduled triggers) can use isolated targets only. A consequential action in a headless run is denied with `headlessDenied` and surfaced on the next interactive attach. That is the same rule the execution-environments page applies to exec approval.

### Recording, audit, replay

Every action is logged with its observation id, canonical form, classification, gate decision and reason, intent-check verdict, effect, evidence, and whether it made progress. Budget extensions, ceiling questions, and the terminal reason are logged as session events, with the progress facts behind each. Observation images are stored as content-addressed blobs in the **ephemeral** lane, and **expiry lives on the reference, not the blob**:
- Each holder (the session, the replay, an audit mark) holds a reference with its own expiry. The blob is swept when its last reference expires. Approval-card crops are stored under the session's reference: an approval ends with the lease, which the session's reference already outlives.
- While the lease is active, the session's reference expires a margin past the lease's hard limit (the derived `endsAt` plus the cleanup grace), and moves when the time ceiling moves. At release it is reset to release time plus the replay TTL.
- An audit mark adds its own reference, with an expiry from the host's audit retention setting (a fixed length, 30 days by default, not indefinite).

So a crash before release leaves images that still expire. A later retention change shortens the references it governs without affecting another holder of the same bytes. Promoting screenshots to the durable lane would break both properties. Route receipts from the Model Pool link each step to the model call that proposed it. Replays are for humans. Deterministic re-execution of a recorded action list is a different feature (scripted RPA) and should not be implied by "replay."

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

**Why not as default:** a script can do far more per step than a single click, so approval becomes per-script and much coarser. Desktop input-automation scripts are pixel-blind unless they take screenshots themselves, and on a host desktop they can't be held to per-app grants. And it fails on UI that has no stable selectors. Treat it as rung 2 inside the same target and policy, with the per-target limits in [§ Model dialects](#model-dialects-native-toolsets-vs-harness-tools), and review whole scripts as consequential when they touch a shared target.

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
- **Screen text in the permission gate's input.** The gate then reads the injected instruction it is supposed to guard against. Gates see the user's request and the proposed action, not the page, and not the model's own stated intent.
- **Letting a label lower a class.** An attacker relabels a destructive button "OK" and it skips confirmation. Labels may only raise.
- **Treating the specialist's result as trusted.** Its free text was written while reading attacker-controlled screens. Envelope it in the parent and prefer typed fields.
- **Resizing a screenshot after capture.** A sanitizer that downscales a geometry-bound image moves every click silently. Size at capture; replace with a marker if it still doesn't fit.
- **Dotted tool names.** `computer.click` is rejected by major vendors' tool-name rules. Use `computer_click`.
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
