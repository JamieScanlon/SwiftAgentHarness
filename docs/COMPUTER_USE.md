# Computer Use

How SwiftAgentHarness lets an agent see and drive a screen, what the harness enforces around each action, and how to wire it up.

Computer use is a **display target** (the user's desktop, a VM, a desktop container, a managed browser, a paired device) behind one observe/act contract. The model sees the screen as an accessibility tree plus a screenshot and acts through element refs, falling back to pixels. Everything around that loop belongs to the harness: leasing the target, approving grants, classifying and gating each action, checking intent, confirming consequential steps, budgets, the kill switch, takeover, and the action log.

**Contents**

- [Status](#status)
- [How it fits together](#how-it-fits-together)
- [Quick start](#quick-start)
- [The computer-use specialist](#the-computer-use-specialist)
- [The macOS driver](#the-macos-driver)
- [Hosting a target in another process](#hosting-a-target-in-another-process)
- [Writing a display target](#writing-a-display-target)
- [Grants and tiers](#grants-and-tiers)
- [How each action is gated](#how-each-action-is-gated)
- [The intent check](#the-intent-check)
- [Budgets, kill switch, takeover](#budgets-kill-switch-takeover)
- [Oversight surfaces](#oversight-surfaces)
- [The tool family](#the-tool-family)
- [Screenshots in tool results](#screenshots-in-tool-results)
- [Model descriptors and the screenshot budget](#model-descriptors-and-the-screenshot-budget)
- [Implementation notes and spec gaps](#implementation-notes-and-spec-gaps)

The spec is the harness-template pages `backends/computer-use/README.md` and `backends/computer-use/macos.md`. Where this implementation interprets or departs from them, see [Implementation notes and spec gaps](#implementation-notes-and-spec-gaps).

---

## Status

The core in `SwiftAgentHarness` builds and tests without screen-capture, accessibility, or input frameworks. The macOS driver is a separate product, `SwiftAgentHarnessComputerUseMac`, linked only by hosts.

| Area | State |
|---|---|
| `DisplayTarget` contract, manifests, observations, canonical actions, coordinate codecs | Done |
| Leases, tiered grants, app policy, budgets, `DisplayTargetRegistry` | Done |
| Per-action classification, intent check on `guard`, per-action confirmation, headless denial, stop key | Done |
| `computer_*` function-tool family with flat schemas | Done |
| Screenshots as image blocks in tool results (Anthropic, OpenAI, LM Studio, Ollama) | Done |
| `computer-use` feature on model descriptors, resize to the model's `maxImageEdgePx` and `maxPixels`, step-counted screenshot pruning | Done. The bundled Claude entries declare it with Anthropic's documented values. |
| Computer-use specialist sub-agent (`ComputerUseTask` / `ComputerUseResult`) and composition wiring (`installComputerUse`) | Done. Synchronous runs only. |
| macOS host-desktop driver (`SwiftAgentHarnessComputerUseMac`) | Done, in-process or served by a display host. Verified by unit tests and an opt-in smoke test, not yet on a range of real apps. VM targets are not built yet. |
| Display host protocol: `RemoteDisplayTarget`, `DisplayHostServer`, Unix-socket transport, XPC transport (macOS 26+), code-signature peer checks | Done. No host app ships; integrators build their own. |
| Oversight control plane: approval cards, questions, handoffs, and activity routed to the user's conversation; REST answer, hand-back, stop, and takeover | Done |
| Approval-card target crops, TUI indicator, question and handoff dialogs, takeover and stop shortcuts, `computer-use` surface capability | Done. The TUI shows crops as alt text. |
| "Agent active" HUD on the host desktop (`MacAgentActiveHUD`), post-run replays with observation thumbnails | Done |
| Image retention: held while the run can cite them, a TTL from lease release, audit marks for longer retention | Done |
| Deferred loading: the parent finds `delegate_computer_use` through `tool_search` | Done |
| Anthropic's native computer toolset (`computer_toolset_20260801`, and `computer_20251124` / `computer_20250124` for older models) | Done. Other vendors' toolsets and a live view: not yet. |

## How it fits together

```
HarnessRuntimeSession.installComputerUse(configuration)
        │
parent conversation ── delegate_computer_use(goal, success_criteria, constraints, apps, domains, …)
        │
        ▼  Sub-Agent Pool: ComputerUseTask
DisplayTargetRegistry.lease(…, approve:)            one grant dialog; host-target and permission rules
        │
isolated child conversation (computer-use specialist, subagent-computer-use, tools = computer_* only)
        │      ComputerUseSession ◀── ComputerUseToolProvider(session)
        ▼
ComputerUseResult (JSON) ──▶ parent's tool result
```

- **`DisplayTargetRegistry`** owns the targets and the policy that applies before any lease:
  - host targets only for an operator-initiated session with the user present;
  - required platform permissions are preflighted;
  - the grant dialog is shown once;
  - unattended sessions get a short absolute expiry (20 minutes by default).
- **The specialist** is an isolated child conversation whose only tools are the computer-use family. The parent sees a structured `ComputerUseResult`, never the child's transcript, screenshots, or screen text.
- **`ComputerUseSession`** gates and runs each action. It also owns budgets, the kill switch, takeover, verification records, and the action log.
- **`ComputerUseToolProvider`** is the model-facing tool family bound to one session.

## Quick start

```swift
session.installComputerUse(ComputerUseConfiguration(
    registry: DisplayTargetRegistry(targets: [myTarget]),
    defaults: ComputerUseSpecialistDefaults(
        target: "macos-host",
        budgets: ComputerUseBudgetPolicy(
            defaultSteps: 40,           // first allotment when the task names none
            ceilingSteps: 120,          // includes every extension
            extensionShare: 0.5,        // of the first allotment, per extension
            noProgressSteps: 8,
            maxDuration: .seconds(30 * 60),
            maxUSD: 5                   // never extended
        )
    ),
    approveGrants: { request in
        // Show request.review.grantable (with capReason / warning) and request.review.blocked in one dialog,
        // in request.conversationID's conversation, explaining request.purpose on request.target.
        // Return the subset the user approved, or nil to decline.
        await presentGrantDialog(request)
    },
    approvals: execApprovalDelivery,      // any ExecApprovalDelivering: per-action confirmation cards
    intentChecker: intentChecker,         // optional; see "The intent check"
    oversight: oversight,                 // optional ComputerUseOversight: ask_user and handoff
    specialist: ComputerUseSpecialistProfile(modelRef: "anthropic/claude-sonnet-4-6")   // the computer-use role
))
```

Every conversation now has `delegate_computer_use`. Bind your surface's stop control and global stop key to `session.stopComputerUse()`, which ends every live specialist session; no model-facing tool can call it.

A host that drives a session directly can still build one by hand: lease through `DisplayTargetRegistry.lease(_:purpose:approve:)`, create a `ComputerUseSession`, and install `ComputerUseToolProvider(session:)`.

## The computer-use specialist

The parent doesn't see `delegate_computer_use` at first. It is deferred: the parent is offered `tool_search`, and a search such as "click through a desktop app" loads the delegate for the rest of the conversation. A model with an MCP tool or command for the job sees that first, and the delegate's schema stays out of the prompt until it's needed. The specialist child sees its computer tools directly. See the Tool System README's "Deferred tool loading" section.

Once loaded, the parent calls `delegate_computer_use` with flat arguments:

| Argument | Meaning |
|---|---|
| `goal` | What to accomplish, stated fully. The specialist cannot see the parent conversation. |
| `success_criteria` | One checkable criterion per line. |
| `constraints` | Rules to keep, one per line. |
| `apps`, `domains` | Requested grants, for example `com.apple.TextEdit:full`, `docs.example.com:click`. The user approves a subset. |
| `target` | Target id. |
| `steps` | Expected size of the work in actions: the first step allotment, clamped to the policy's `ceilingSteps`. Defaults to `defaultSteps`. |
| `deadline` | Only a cutoff the user stated, as an ISO 8601 date-time with a UTC offset. It can only end the session earlier. |
| `return_schema` | Optional JSON Schema for the result. |

What happens:

1. **The task is parsed** into a `ComputerUseTask`. Malformed arguments are denied with the reason, and so are arguments the schema doesn't have. A known rename gets its replacement, such as `max_steps` → `steps` or `max_minutes` → "time limits are set by the host", so a parent copying its own stale calls is corrected on the next one.
2. **The model is chosen.** That's `specialist.modelRef` when set, otherwise the parent's model. Either way it must see images and call tools. The session takes its coordinate dialect and screenshot size from that model's `generate` profile.
3. **The target is leased.** This raises the one grant dialog and applies the host-target rules. The approver gets a `ComputerUseGrantRequest`: the reviewed grants, the lease request, the target's manifest, and the task's goal as `purpose`. Its `conversationID` is the parent conversation, so the host can show the dialog where the user asked. The run's origin decides presence: interactive runs have the user present, trigger and sub-agent runs don't. A non-owner sender is not operator-initiated.
4. **The child is spawned.** It runs on `specialist.modeProfileID` (`subagent-computer-use` by default), with a closed allow-list of the 15 computer tools, so it has no shell, files, or messaging. The mode doesn't cap the number of model turns and has no tool-level approvals: the session counts steps, enforces budgets, and confirms actions itself. Tools off the allow-list are never offered, including ones that need approval. A mode's tool allow-list caps the child's, so the built-in mode allows exactly the computer tools; a custom `modeProfileID` must allow them too, or the specialist is offered nothing. The parent's per-call tool timeout doesn't apply to `delegate_computer_use`, nor to the specialist's own computer tools: any of them can wait on the user (a question, a handoff, a ceiling question, a confirmation card), and each is bounded by the session's end time and the idle timeout instead. Their entries carry `bounds-own-run-time`. The child run has no timeout of its own: it follows the session's `childRunDeadline(grace:)`, which is the lease's end time while the session runs and `specialist.cleanupGraceSeconds` (30 s by default) after it ends. A present user's extension at the time ceiling moves both, so extensions are never cut short. If the end time passes while the model is mid-turn, the deadline check makes the same decision an action would: it asks a present user, or ends the session. The session's terminal reason, not the child's timeout, decides the result's status. A child that produces nothing for `specialist.idleTimeoutSeconds` (180 s by default) is cancelled and the result is `failed` with reason `idle-timeout`, which usually points at the model binding or the driver. Questions, handoffs, ceiling questions, confirmation cards, and takeover pause that clock. Its brief holds the goal, numbered criteria, constraints, working rules, and the return schema.
5. **Every step restates the task.** Each computer tool result ends with a reminder of the constraints and the criteria not yet verified. `computer_verify` cites a criterion by its text, its number, or as the reminder lists it (`1. The title is bold`). When the task has criteria, a citation that matches none of them is refused with the list, so a miscopied criterion can't leave the result `done-unverified` without the specialist knowing.
6. **The session always ends** and the lease is released. The full action log is stored as a session blob.
7. **The parent gets JSON.** That's `status`, `result`, `verification` (one entry per criterion), `handoff`, `budget` (`stepsUsed`, `stepsGranted`, `extensions`, `lastProgressStep`), `actionsLog`, `reason`, and `missingGrants` when refused actions needed grants the task didn't have. Each entry has the shape of a task grant, `{ "domain": "www.apple.com", "tier": "click" }` or `{ "app": "com.apple.Terminal", "tier": "full", "flags": ["system-keys"] }`.

| Status | When |
|---|---|
| `done` | Every criterion has a `computer_verify` entry that is met |
| `done-unverified` | Finished, but some criterion is unverified or not met |
| `needs-user` | A handoff nobody could take, or a consequential action denied with nobody present |
| `blocked` | Grants declined, target busy, permissions missing, model unsuitable, or stopped by the user. Also a run whose refused actions needed grants it didn't have and that met no criterion, whether it finished or ended with no progress; `reason` names the `apps` and `domains` to delegate again with |
| `budget-exhausted` | The step ceiling, the time ceiling, the unattended grant expiry, the cost cap, or the run timeout was reached. After extensions it means the work was moving and ran out of room, so delegating the remainder is reasonable |
| `no-progress` | Too many steps in a row made no progress. Repeating the same delegation won't help: rephrase the goal, try another approach, or ask the user |
| `deadline` | The task's stated cutoff passed |
| `failed` | The child failed, was cancelled, or went silent for its idle timeout (`reason: idle-timeout`) |

## The macOS driver

`MacHostDisplayTarget` drives the user's own Mac. macOS grants Screen Recording, Accessibility, and Post Event to the *responsible process*, so where the target runs decides who holds those grants:

- **Inside a signed GUI app that embeds the harness**, the app holds them. Run the target in-process.
- **Inside a command-line tool or server**, the terminal or launchd would hold them, and every program run there inherits them. That is fine for development only. For anything else, run the target in a separate signed process and connect to it; see [Hosting a target in another process](#hosting-a-target-in-another-process).

```swift
import SwiftAgentHarnessComputerUseMac

let hud = await MacAgentActiveHUD(onStop: { Task { await session.stopComputerUse() } })
var macConfiguration = MacHostDisplayTarget.Configuration(
    excludedBundleIDs: ["com.example.my-harness-ui"]   // never captured, never granted
)
macConfiguration.onForegroundDelivery = { app in await hud.noteForegroundDelivery(app: app) }
let mac = MacHostDisplayTarget(configuration: macConfiguration)
// Show mac.permissionChecklist() during onboarding.
let stopKey = MacStopKeyMonitor { Task { await session.stopComputerUse() } }
stopKey.start()                                       // needs Input Monitoring

session.installComputerUse(ComputerUseConfiguration(
    registry: DisplayTargetRegistry(targets: [mac]),
    defaults: ComputerUseSpecialistDefaults(target: MacHostDisplayTarget.defaultID, budgets: ComputerUseBudgetPolicy()),
    approveGrants: …,
    activityObserver: { activity in await hud.apply(activity) }
))
```

| Piece | Behavior |
|---|---|
| Permissions | `MacPermissionBroker` preflights Screen Recording, Accessibility, and Post Event separately on every call, and never infers them from side effects. The checklist explains each one and deep-links to its Settings pane. It also flags that Screen Recording usually needs a relaunch. |
| Capture | ScreenCaptureKit only. A display capture includes only the granted apps' windows, so non-granted apps and the harness's own UI never appear. The capture pipeline downscales to the session's limit. Zoom captures a region at full resolution. Images are PNG, and the geometry recorded is the rect the image was sized from. |
| Working app | Full-screen observations, and input that names no target (keys, typing, menus with no app, scrolls and pointer presses without a point), belong to the working app: the frontmost app when it's granted, otherwise the granted app with the frontmost normal window. The harness's own app is usually in front while an agent works, and it is never granted, so the agent works in the granted app behind it. With nothing granted on screen, that input is refused. The layout's `focusedApp` reports the working app, so the classifier gates the app the input reaches. |
| Accessibility | It reads the focused window of the working app. AX calls run on a dedicated serial queue, never the cooperative pool, with one batched attribute read per element. Traversals are bounded by a 1 s messaging timeout, a 1.5 s deadline, and depth, node, and child budgets, and return partial trees with the reason. Chromium and Electron are asked to build their trees (`AXManualAccessibility`). |
| Refs | An `eN` ref is valid only with its observation. Before acting, the element is re-read: a changed role or label, or a move beyond 8 pt, refuses with `escalation: observe`. Points are refused when the app has quit or restarted, checked by pid plus launch date, and when the point isn't over one of the app's windows or another app's floating window, such as the Dock, covers it. Other apps' normal windows don't block a point: process-posted events pass them, and foreground delivery activates the app first. |
| Delivery | It tries the accessibility action first (press, set value read back, focus, menu walk), then events posted to the target process. With `delivery: .foregroundAllowed` on the lease, it activates the app, posts global events, and restores the previous app on release, unless the user changed the frontmost app meanwhile. |
| Input hygiene | It uses a private event source. Clicks settle 50 ms after the move, and double and triple clicks set click states. Unicode typing goes in chunks of at most 20 UTF-16 units on grapheme boundaries. Held keys and buttons are released after every batch, on takeover, and on release. Paste saves, writes, verifies, pastes, and restores the clipboard. |
| HUD | `MacAgentActiveHUD` is a non-activating panel at the top of the main screen, on every Space, for the whole session. It says who is in control, the step, app, and last action, and how to stop. It has a Stop button, and it announces each escalation to foreground delivery. `sharingType = .none` keeps it out of every capture. |
| Stop key | `MacStopKeyMonitor` is a listen-only event tap (Input Monitoring) on its own run-loop thread. It can't swallow events, and it doesn't need to: the harness never synthesizes the stop key. |
| Evidence | Most pointer and key actions are `unverifiable`, because only a fresh observation can confirm them. A set-value that reads back is `confirmed`. A semantic call that timed out is `unverifiable` with `escalation: observe` and is never retried. |

**Smoke tests.** `SWIFTAGENTHARNESS_MAC_SMOKE=1 swift test --filter MacHostSmokeTests` observes the frontmost app on the real screen without sending input. Grant Screen Recording and Accessibility to the terminal first. The same variable enables `MacAgentActiveHUDPanelTests`, which needs a window server.

**Verify on hardware before relying on it.** These are the spec's open questions plus this driver's:
- capture of minimized and other-Space windows;
- whether `SCWindow.frame` matches the captured window region exactly;
- the per-event Unicode length on 26 and 27;
- process-routed clicks in apps that ignore background events;
- AX trees in Chromium and Electron apps.

## Hosting a target in another process

A *display host* is a process that owns a `DisplayTarget` and serves it to harnesses elsewhere. The library ships the parts; the host process itself is yours to build. It can be a menu-bar app, an `SMAppService` login item, a daemon, your existing app, or an agent inside a VM.

```swift
// In the host process, which holds the permissions:
let server = DisplayHostServer(target: MacHostDisplayTarget(), name: "Example Host")
let listener = try await DisplayHostSocket.listen(
    path: socketPath,
    peers: .all(of: .sameUser, try .sameTeamAsThisProcess())
)
try await server.serve(listener)

// In the harness:
let connection = try await DisplayHostSocket.connect(path: socketPath, peers: try .sameTeamAsThisProcess())
let remote = try await RemoteDisplayTarget.connect(over: connection)
let registry = DisplayTargetRegistry(targets: [remote])
Task { for await case .stopRequested in remote.events { await session.stopComputerUse() } }
```

| Piece | Behavior |
|---|---|
| `DisplayHostProtocol` | JSON messages: a request with an id, a response echoing it, or an event. The client opens with `hello`, and the host answers `welcome` with its manifest, or a version mismatch. Requests can be in flight concurrently. Leases are named by id. |
| `RemoteDisplayTarget` | A `DisplayTarget` the harness uses like a local one. Target errors arrive as themselves. A dropped connection fails calls with `driverFailure`, and `permissions()` reports nothing granted. If a lease is refused as busy and a holder in this harness has died, the client releases that lease and retries. |
| `DisplayHostServer` | Serves one target to any number of connections. Each connection can only use leases issued to it. A holder counts as alive while its connection is open, and a closed connection's leases are released as `aborted`. `requestStop(leaseID:)` sends `stopRequested` to the holder, for the host's stop key or HUD. |
| `DisplayHostSocket` | A Unix-domain socket with length-prefixed frames. The socket file is owner-only. Both ends check the other's peer (pid, uid, audit token) against a `DisplayHostPeerRequirement`. The default is the same user. |
| `DisplayHostPeerRequirement.codeSignature(_:)`, `.sameTeamAsThisProcess()` | Mac only. Checks the peer's code signature through its audit token, so a reused pid can't pass. |
| `DisplayHostXPC` | Mac only, macOS 26 or later. Serves a launchd Mach service or an anonymous listener's endpoint, with an `XPCPeerRequirement` enforced on both ends. |
| `InMemoryDisplayHostConnection` | Both ends in one process, for tests and for putting an in-process target behind the protocol. |

Any transport works if it implements `DisplayHostConnection` and keeps message boundaries. A VM transport over vsock or TCP is one example. A host that wants a HUD wraps its target in a decorator, or calls the HUD from its stop handling.

## Writing a display target

Conform to `DisplayTarget` and declare a `DisplayTargetManifest`:

```swift
DisplayTargetManifest(
    id: "macos-host", label: "This Mac", platform: "macos",
    isolation: .host,                        // host | vm | container | remote-browser | remote-device
    perception: [.pixels, .accessibility, .ocr],
    delivery: [.background, .foreground],
    semanticActions: [.press, .setValue, .menuPath, .launchApp, .openURL],
    requires: [.screenCapture, .accessibility, .postEvents],
    humanPresence: .shared                   // shared | none
)
```

The driver's obligations:

- **Single controller.** Hold leases with `DisplayTargetLeaseLock`, which returns `targetBusy` while a live holder has the target and reclaims it from a dead one.
- **`release` always restores UI state** and is idempotent.
- **Every `DisplayObservation` has its own id, timestamps, and target identity.** Image geometry is recorded in `ScreenshotGeometry`, and the process start time is pinned alongside the pid.
- **`act` re-resolves cited elements and refuses on drift.** It reports evidence (`confirmed | unverifiable | suspected-noop | partial | refused | not-executed`) and stops at the first failure.
- **Release modifiers and buttons in `defer`.**

The session sends one action per `act` call, so it can gate each action separately.

## Grants and tiers

| Tier | Allows |
|---|---|
| `view` | The app appears in observations only |
| `click` | Pointer actions (click, move, scroll, drag, press, launch) |
| `full` | Everything, including typing, keys, set-value, and menus |

The flags are `clipboard-read`, `clipboard-write` (needed for `paste` typing) and `system-keys` (needed for global shortcuts such as ⌘Tab or ⌘Space).

`ComputerUseAppPolicy.default` matches apps by bundle id and declared category, never by window title:

| Category | Default |
|---|---|
| Password managers, `public.app-category.finance` | Blocked unless `ComputerUseOperatorOverrides.allowBlockedBundleIDs` lists them |
| Terminals and IDEs, `public.app-category.developer-tools` | Capped at `click`, with a blast-radius warning |
| Browsers | Capped at `view`, so they can't be launched; pages are reached through domain grants and `open-url`, which on the Mac opens in a granted browser (the default one if it's granted) and is refused when none is |
| Finder, System Settings, Shortcuts | Grantable, with a blast-radius warning |

`ComputerUseGrantReviewer.clamp` keeps an approver from raising a tier above its cap or adding grants and flags that weren't requested. Category rules are applied again at action time, because the category is known only once the target reports it.

## How each action is gated

`ComputerUseActionClassifier` works only from data the harness derives itself: the action, the cited element (role, label, app, URL), and the grant.

| Class | Examples | Gate |
|---|---|---|
| observe | observe, zoom, wait, wait-for | allow |
| navigate | scroll, move, launch of a granted app, `open-url` on an http(s) granted domain | allow |
| interact | click, press, type, set-value, key, menu at a sufficient tier | Allowed when the intent check says consistent. With no checker bound, confirmed on `humanPresence: shared` targets and allowed otherwise. An operator can opt out of that confirmation with `ComputerUseOperatorOverrides.skipInteractConfirmationWithoutIntentCheck`. |
| consequential | Typing into secure or payment fields; targets labeled submit, send, buy, delete…; destructive shortcuts; System Settings; installers; vendor safety signals | Always confirmed |
| out of grant | Non-granted app or domain, tier violation, missing flag, non-web `open-url` scheme, an `open-url` whose URL carries a credential, the stop key | Denied, with the reason returned to the model. When a task grant would have allowed it (the page's domain in a browser, otherwise the app at the needed tier and flags), the reason adds that grants can't change during the run and names the grant to delegate again with, and the session records it in `missingGrants` |
| unresolvable | Citing an observation that is no longer retained, an unknown ref, a point outside the observation | Refused with `escalation: observe` |

On-screen labels can only raise the class. They never lower it, and they never reach the intent check.

Confirmation:

- **Per action.** Confirmation happens per action, even inside a batch. A refusal stops the batch, and the remaining actions are reported `not-executed`.
- **Routing.** Cards go through `ExecApprovalDelivering` with `allowsDurableBypass: false` and only "Allow this action" and "Deny" buttons.
- **Binding.** The approval is bound to the action's canonical form, with typed text replaced by its SHA-256.
- **Headless runs.** When no user is present, consequential actions get `headlessDenied` without anyone being asked. They are collected in `session.headlessDenials` so the next interactive attach can show them.

Possibly-delivered actions are never retried automatically:

- A driver error after sending is reported as `unverifiable` with `escalation: observe`.
- The tool result tells the model not to repeat the action.
- After three failing batches in a row, the result escalates to `ask-user`.

**Secrets.** `open-url` refuses a URL that carries a credential, even on a granted domain. That covers user-info before the host, a secret-named query or fragment parameter (`token`, `access_token`, `api_key`, `password`, `sig`, …), or a token-shaped value such as a JWT or a well-known key prefix. Text bound for helper models has secret values redacted: the user request the intent check sees, and screen text sent to the injection probe. Typed text never reaches the action log, which records only its hash.

**Injection probe.** Screen results are external content labelled `screen`, so a host that configures `DecisionConsumers.injectionProbe` gets a warning line prepended when screen text looks like instructions. The probe warns and steers; it doesn't block.

## The intent check

`ComputerUseIntentChecker` runs one `yes-no` question on the `guard` decide role (`ModelRole.guardrail`) for interact and consequential actions.

- **The state:** the user's request, a bounded text history of prior actions, and the proposed action as harness identifiers only: kind, app bundle id or domain, and element role.
- **Never in the state:** screenshots, screen text, or labels.
- **Outcomes:**
  - only an `act` verdict counts as consistent;
  - a mismatch, a failure, or a missing request goes to confirmation;
  - an unbound role falls back to the no-checker rule.

```swift
let intentChecker = ComputerUseIntentChecker(
    dispatcher: decisionDispatcher,
    configuration: ComputerUseIntentCheckConfiguration(policy: DecisionPolicy(
        question: ComputerUseIntentCheckConfiguration.questionID,
        bands: ["guard-2026-09": .ranges(confirm: DecisionRange(0, 0.95, upperOpen: true), act: DecisionRange(0.95, 1))]
    ))
)
```

The shared decider setup is in [Decision models](./DECISION_MODELS.md). The spec flags that a fast decider's robustness to adaptive attacks is unmeasured, so validate it on your own attack set. Consequential actions are confirmed whatever it says.

## Budgets, kill switch, takeover

- **Budgets.** The host sets a `ComputerUseBudgetPolicy`; the parent sizes the work in `steps` and never sets a time budget. The lease carries `ComputerUseBudgets`, the policy combined with the task. A step is an action delivered to the driver, so actions that come back `not-executed` don't count. The lease's `endsAt` is the earliest of the time ceiling (`maxDuration`), the task's `deadline`, and an unattended session's grant expiry, measured from when the lease is issued. Before every action the session checks, in order:
  - **No progress.** `noProgressSteps` consecutive steps without progress end the session with `no-progress`, whatever allotment remains. Counting steps, not seconds, behaves the same on a fast model and a slow one. Refused actions aren't steps, but they count toward the window too, and the session ends on the refusal that fills it; refusals while the user has taken over don't count.
  - **End time.** A passed `deadline` ends it with `deadline`, and a passed grant expiry with `time-budget`; neither is ever moved. At the time ceiling a present user is asked whether to continue, and a yes adds `extensionShare` of `maxDuration`, never past the deadline or the grant expiry. Otherwise the session ends with `time-budget`.
  - **Steps.** When the allotment is used up and the session made progress since the last grant, it grows by `extensionShare` of the first allotment, rounded up, up to `ceilingSteps`. Without progress it ends with `step-budget`. At the ceiling a present user is asked, and each yes grants one more extension; without a user, or with a no, it ends with `step-budget`. Extensions below the ceiling aren't approved one by one.

  Exceeding `maxUSD` (fed by `session.recordCost(usd:)`) ends it with `cost-budget`; cost is never extended. `session.budgets`, `endsAt`, and `extensions` show the current state, and `terminalDetail` says what ran out. The ceiling question goes through `ComputerUseOversight.continuePastCeiling(_:)`, which by default asks with `askUser` and reads a yes from the reply; hosts can show a dialog instead. Permissions are polled before every batch, and a revoked one ends the session with `permission-revoked`.
- **Kill switch.** `HarnessRuntimeSession.stopComputerUse()` stops every live specialist session, and `POST /api/conversations/{id}/computer-use/stop` stops one conversation's (`ComputerUseSession.stop()` for one you drive yourself). The stop key (Escape by default; set it with `ComputerUseActionClassifier(stopKey:)`) is never synthesized, in any spelling, while a session is active.
- **Takeover.** `session.handoff(reason:prompt:)` turns takeover on, waits for `ComputerUseOversight.handoff` to return, then turns it off, however the handoff ended, including when its caller was cancelled. Turning takeover off and releasing the lease at the end run in a task of their own, because a remote target drops requests made from a cancelled task. The user can also take over at any time with `POST …/computer-use/takeover`. While takeover is on, observe and act are refused. Ask-user and handoff are unavailable when no user is present.
- **Progress.** `session.progress` records what the harness counts as progress, decided only from facts it recorded, never from the model's claims or screen text. A criterion verified as met for the first time is progress. So is a state not seen before, when it is first observed after an acting step whose effect wasn't `refused`, `suspected-noop`, or `not-executed`. Observing, zooming, and waiting never earn progress, so a page that changes on its own doesn't count, and nothing the user does during takeover is credited to the agent. A state is a `ComputerUseStateDigest`: a SHA-256 of the app, window, URL without its fragment, the focused element's role, and the tree's shape (each element's role and depth). Text and values are left out. On screenshot-only observations the digest covers app, window, and URL. Returning to a state already seen never counts, which catches oscillation. Each action-log record says whether that step made progress (`madeProgress`).
- **Verification.** `session.verify(...)` accepts only an observation taken after the last action.

## Oversight surfaces

A specialist runs in a child conversation the user never opens, so everything that needs the user goes to the parent conversation, the one that called `delegate_computer_use`:

- **Approval cards.** Consequential actions are confirmed through the parent conversation's approval delivery, the same `ExecApprovalDelivering` cards exec approvals use. Set `ComputerUseConfiguration.approvals` to replace it. Each card lists the action, the target element, why it needs confirming, and the intent-check verdict. When the cited observation has pixels, an `image` block carries a crop of the target region (the element's padded frame, or a box around a point, at most 480 px). Surfaces that can't show images get its alt text.
- **Questions and handoffs.** `computer_ask_user` and `computer_handoff` publish a `computerUseRequest` surface intent on `conversation/{id}/events` and block the specialist until a client answers. When the request is resolved, times out, or the run is cancelled, a `computerUseRequestCleared` intent follows. Set `ComputerUseConfiguration.oversight` to answer in-process instead.
- **Activity.** Every action batch, takeover change, and session end publishes a `computerUseActivity` intent with the target, step, current allotment (`maxSteps`), `extensions`, app, action, and terminal reason. The macOS HUD shows it as "Step 34 of 45, extended twice". This feeds the "agent is using <target>" indicator.

All three use the `surfaceIntent` semantic kind. The payload is the `computerUse` object in [`client-surface-intent-wire.schema.json`](../openapi/schemas/ws/client-surface-intent-wire.schema.json).

Clients answer and steer through REST. Each route checks conversation tenancy:

| Route | Does |
|---|---|
| `GET /api/conversations/{id}/computer-use` | Lists pending requests and live sessions (`lifecycleID`, target, step, `maxSteps`, `takenOver`) |
| `POST /api/conversations/{id}/computer-use/requests/{requestID}` | `{"action": "answer", "answer": "…"}`, `{"action": "hand-back", "note": "…"}` or `{"action": "decline"}`. A question takes answer or decline; a handoff takes hand-back or decline (otherwise 409). |
| `POST /api/conversations/{id}/computer-use/stop` | Stops the conversation's sessions, declines their pending requests, and returns `lifecycleIDs` |
| `POST /api/conversations/{id}/computer-use/takeover` | `{"on": true}`, optionally with `lifecycleID`. Returns `lifecycleIDs`, or 404 when nothing is running. |

The terminal surface renders all of this: an indicator line with the target, step, app, and last action; a dialog with a text field for a question; *Hand back control* and *Decline* for a handoff; **Ctrl-T** to take over or hand back and **Ctrl-X** to stop. Pass `HarnessRuntimeSession.computerUseControl` to `RuntimeTUIHost(computerUse:)`. Surfaces that render it declare `SurfaceCapabilities.computerUse`.

### Replays

When a specialist run ends, the harness stores a replay as session blobs: the full action log, the session events (each extension with the progress that justified it, each ceiling question and its answer, and how the session ended), and a thumbnail of each observation that had pixels. A thumbnail is at most 320 px on its long edge, a session keeps up to 120 (the first and the newest), and typed text appears only as its hash. The delegate result's `actionsLog` ends with the replay document's ref. Surfaces read replays through REST:

| Route | Returns |
|---|---|
| `GET /api/conversations/{id}/computer-use/replays` | The conversation's recent replays, newest first |
| `GET …/computer-use/replays/{lifecycleID}` | One replay: records and thumbnail rows |
| `GET …/computer-use/replays/{lifecycleID}/thumbnails/{observationID}` | The thumbnail image, only for an observation that replay lists |

A replay is a record for review. Re-executing its actions is a different feature and isn't offered.

### Image retention

A run's images are its screenshots (offloaded from the specialist's tool results), its replay thumbnails, and its replay document. While the run can still cite them they are held in the ephemeral lane, until the lease's hard expiry plus the release TTL at the latest, so a crashed run can't keep them forever. When the lease is released, the TTL starts: every image the run held then expires `ComputerUseRetention.afterRelease` later (24 hours by default), and expired blobs are swept. A run the user marks for audit gets `ComputerUseRetention.audit` from release instead. The default, `nil`, holds its images until the mark is removed:

| Route | Does |
|---|---|
| `POST /api/conversations/{id}/computer-use/runs/{lifecycleID}/audit` | `{"marked": true}` or `false`. A live run takes the mark at release. A released run's images move to the new expiry right away. |

Replay listings show `auditMarked` and `expiresAt`, and an expired replay drops out of them.

An unanswered question times out after 10 minutes and reports the user as unavailable. An unanswered handoff times out after 30 minutes and reports it as declined.

## The tool family

The tools are `computer_observe`, `computer_click`, `computer_type`, `computer_key`, `computer_scroll`, `computer_press`, `computer_set_value`, `computer_menu`, `computer_launch`, `computer_open_url`, `computer_zoom`, `computer_wait_for`, `computer_verify`, `computer_ask_user` and `computer_handoff`.

- Each tool has one flat schema with primitive parameters only.
- Pointer tools take a `ref`, or `x`/`y` in the session's coordinate mode, plus the `observation` the action cites.
- Refs are stable for the session. Drivers number elements per traversal, so the session matches each tree to the previous one by role, subrole, label, and nearest frame. A matched element keeps its ref, a new element gets a ref no element has had before, and actions are translated back to the driver's refs. A ref is still cited with an observation, and the target still checks it against that observation.
- `computer_observe` with `diff_against` returns the tree as a diff: added (`+`), changed (`~`), and removed (`-`) elements, with unchanged ones only counted. Unchanged elements keep their refs and can be cited with the new observation. If the base observation is no longer retained, the full tree comes back with a note.
- The codec maps coordinates through that observation's recorded geometry, so the model never sees a scale factor.
- Results from the screen-bearing tools are wrapped in the untrusted-content envelope with the `screen` source label. `computer_verify`, `computer_ask_user` and `computer_handoff` return harness or user text and are exempt.

### Anthropic's native toolset

A specialist bound to a Claude model reached over Anthropic's own API uses Anthropic's computer tools instead of the `computer_*` family. Claude is trained on them. The catalog's `computer-use` feature `version` picks the dialect:

| Version | Wire | Models (October 2026) |
|---|---|---|
| `computer_toolset_20260801` | Seventeen member tools (`screenshot`, `left_click`, `type`, `key`, `scroll`, `zoom`, …), no beta header | Opus 4.8 and the Claude 5 family |
| `computer_20251124` | One `computer` tool with an `action` field, beta `computer-use-2025-11-24` | Opus 4.6 and 4.7, Sonnet 4.6 |
| `computer_20250124` | The same without zoom, beta `computer-use-2025-01-24` | Haiku 4.5 |

- **Same gates.** Each member call becomes a canonical action and runs through the session like any other: grants, classification, the intent check, confirmation, budgets, and replay. Coordinates are pixels of the latest screenshot and map through its recorded geometry.
- **Kept alongside.** The session still offers `computer_verify`, `computer_ask_user`, `computer_handoff`, `computer_launch`, and `computer_open_url`. Verification and the user stay first-class, and launching or opening a URL is cheaper than clicking.
- **The codec.** `AnthropicLLM` replaces the member tool definitions with Anthropic's declaration, sends the beta header for the older versions, echoes `toolset_name: "computer"` on member calls and results, and marks halted results `is_error`. The older versions declare the screen size a display screenshot comes out as.
- **Batches.** Claude can send several actions in one turn. They run in order, and after the first failure the rest are answered with Anthropic's halt text without running. Tools tagged `halts-batch-on-failure` are never dispatched in parallel.
- **Elsewhere.** Every other model, and Claude through an OpenAI-compatible route such as OpenRouter, keeps the `computer_*` tools.

## Screenshots in tool results

`computer_observe` and `computer_zoom` return the screenshot as an image part (SwiftAgentKit `ToolResultImage`) next to the text, at exactly the size recorded in its `ScreenshotGeometry`. Drivers fill `ObservationImage.data` with the encoded image as sized for the model.

- **Never resized after capture.** Screen tools carry the `geometry-bound-images` policy tag. The tool-result formatting stack keeps their images untouched. If one exceeds the bound model's edge cap (or `maxInlineImagePixelDimension` when the model declares none) or `maxInlineImageBytes`, it is replaced by a marker telling the model to observe again, because a resized screenshot would misplace every click. Configure the session from the bound model (below) so screenshots are captured at the right size.
- **Vision gating.** As with inline data URLs, a conversation whose model lacks vision gets a text marker instead of the image, and compaction always replaces images with the compaction marker.
- **On the wire.** Anthropic gets image blocks inside the `tool_result`. OpenAI and LM Studio tool messages carry text only, so the images from a run of tool messages travel in one user message placed right after the run. Ollama already attaches images to tool messages.
- **Persistence.** Tool images are stored as durable session blobs when the message is appended. The transcript keeps a `blob://` ref with the media type, and reloads hydrate the bytes.

## Model descriptors and the screenshot budget

**The `computer-use` feature.** A model's `generate` profile declares computer use as a versioned feature, read by `ComputerUseModelSupport`:

```jsonc
"computer-use": {
  "supported": true,
  "version": "toolset-2026-08",      // the vendor toolset
  "params": {
    "coordinates": "pixels",         // or "normalized-1000"
    "maxEdgePx": 2576,               // screenshot long-edge cap
    "maxPixels": 3750000,            // screenshot area cap, for vendors that reject larger images
    "keepRecentScreenshots": 3,      // optional retention overrides
    "pruneEvery": 15
  }
}
```

A bundled catalog row declares it under `features`, with vision caps under `vision` (`maxImageEdgePx`, `maxImageTokens`). The row's synthesized `generate` profile then carries both. Hosts can also set `ModelRegistryEntry.contracts` directly.

**Sizing to the model.** Build the session configuration from the bound model:

```swift
let profile = registryEntry.profile(for: .generate)
let configuration = ComputerUseSessionConfiguration(task: task, model: profile)
```

That fixes the coordinate dialect from the feature, and sets the image limit to the tighter of the feature's `maxEdgePx` and the contract's `maxImageEdgePx`, plus its visual-token cap. With nothing declared, it falls back to a 1200 px long edge. The tool-result pipeline applies the same model cap: screenshots must fit it, and other images are rescaled to the tighter of the model's cap and `maxInlineImagePixelDimension`.

**Retention.** `ContextScreenshotRetention` runs at projection time; the transcript keeps every screenshot.

- **What counts.** Screenshots are counted across the loop, not by user turns, so pruning fires inside one long run.
- **What's kept.** The newest `keepRecent` (3) stay in full.
- **What's pruned.** Older ones are pruned in whole batches of `pruneBatch` (15), each replaced by a marker plus the observation's one-line summary. The tree text stays.
- **Why batches.** Between batches the projected prefix is byte-identical, so the prompt cache holds, and it changes once per batch.
- **Request size.** The defaults keep at most 17 screenshots in any request.
- **Configuration.** A model's feature can override both values. `ContextEngineProjectionPolicyInput.screenshotRetentionPolicy = nil` turns pruning off.

## Implementation notes and spec gaps

These are behavior calls made where the spec was silent or ambiguous, plus gaps worth revisiting.

**Contract**

| Topic | Behavior |
|---|---|
| Tool names | The spec writes the family as `computer.*`. Anthropic and OpenAI only accept tool names matching `^[a-zA-Z0-9_-]{1,64}$`, so the tools are `computer_*`. |
| Type name | The spec's `Observation` is `DisplayObservation`, because `Observation` collides with Swift's Observation module, which SwiftData's `@Model` expands into. |
| `LeaseRequest` fields | The spec's request has no initiator or presence fields, but its rules depend on both: non-operator work never gets a host target, host targets need a present user, and unattended sessions get a short expiry. `operatorInitiated` and `userPresent` were added. |
| Budget field names | The spec's `ResolvedBudgets` is `ComputerUseBudgets`, matching the module's other computer-use types. It also keeps `maxDuration`, `deadline`, and `grantExpiry` beside the spec's `endsAt`, because a present user's extension at the time ceiling must move the ceiling without moving the deadline or the grant expiry. |
| When `endsAt` is fixed | The spec computes `endsAt` from the session's start. Here it is fixed when the lease is issued, after the grant dialog closes, so time the user spends deciding isn't charged to the session. |
| Progress from verification | The spec says a step made progress when a `verify` call newly verified a criterion. Verification isn't an action delivered to the driver, so it isn't a step here. It counts as progress at the current step count, which is what the extension check and no-progress window read. A criterion matches a task criterion by its text, its number, or both as the reminder lists them; a verification that matches none is refused. |
| State digest details | The spec lists the frontmost app among the digest's inputs. The digest uses the observation's app: on the host desktop that is the app the agent works in, since the harness's own app is usually frontmost and never observed. URLs drop only the fragment, so a different query is a different page. Elements now carry `depth` and `isFocused` so drivers can supply the tree's shape; a driver that doesn't set `depth` still contributes roles. |
| Time extension size | The spec says the time ceiling "works the same way" as the step ceiling: a present user's yes grants one more extension. It doesn't size a time extension. Here it is `extensionShare` of `maxDuration`, counted from when the user answers. |
| Ceiling question | The spec asks "through `ask_user`", which returns free text. `ComputerUseOversight.continuePastCeiling(_:)` defaults to that and treats a reply starting with yes, ok, sure, or continue as a yes; anything else, or no user, stops. Hosts can override it with a yes/no dialog. |
| Release reasons | A `no-progress` ending releases the lease as `aborted` and a `deadline` ending as `expired`, since `ReleaseReason` has no closer match. |
| Idle timeout events | The spec resets the idle clock on any `DelegateEvent`. In-process delegates have no `DelegateEvent` stream, so the child-run port reports each streamed delta and orchestration state change instead, and a pending approval for the child's run counts as `awaiting-approval`. The cancelled run's `run_cancelled` marker records `idle-timeout` as its `reason` and its terminal detail. Other cancellations still record the harness's own reason strings there, such as `task_cancelled_iter_N`, rather than the spec's `user-cancel`, `parent-cancel`, `deadline`, or `budget`. Remote delegates take `limits.idleTimeoutSeconds` from `subAgentHostingPolicy`, since their agent entries come from host-registered tools rather than config. An A2A task in `input-required` or `auth-required` is waiting on input the harness can't route to anyone yet, so it counts as idle rather than paused. |
| `humanPresence` values | The manifest example shows only `shared`. `none` was added for VMs, containers, and managed browsers. |
| Registry | The spec says display targets register in the same backend registry as sandboxes and reuse its lifecycle, pruning, and observer-token machinery. `SandboxBackendRegistry` is a static, `SandboxBackendHandle`-typed table, so display targets have their own injected `DisplayTargetRegistry` instance. There is nothing to reuse yet. Pruning (`SandboxPruneService`) applies to persistent runtimes, and the host desktop isn't one. The noVNC observer tokens the spec describes aren't implemented for the browser sandbox either. Both belong with isolated (VM or container) targets. |

**Grants and classification**

| Topic | Behavior |
|---|---|
| Tier for navigate actions | The spec puts scroll and move in Navigate ("allow within grant") but defines `view` as "observations only". Scroll, move, and launch therefore need `click`. |
| Menus | `menu` needs `full`, because menu items reach the same commands as shortcuts, which `click` excludes. |
| Category rules | At grant time only bundle ids are known, so category rules (finance) are also applied at action time from the app identity the target reports. |
| Labels in classification | The spec lists the element label among classification inputs and excludes labels from the intent check. Labels here can only raise an action to consequential. |
| Keyboard-submitted forms | Typing and then pressing Return can submit a form without any consequential label being seen. Harness-derived classification can't detect this, and the spec doesn't address it. The intent check is the only defense. |
| Stop key | The spec's example implies Escape. Reserving it also stops the agent from dismissing dialogs with Escape, which the spec appears to intend. It is configurable. |
| Browser launch | Browsers are capped at `view` and launch needs `click`, so a browser can't be launched; the refusal points the model to `open-url`. The spec says `open-url` opens "in a granted browser target". On the Mac host that means a granted browser app, so `open-url` is refused when the run grants no browser, even with the domain granted, because pages in an ungranted browser can't be observed. |
| Working app on a shared desktop | The spec doesn't say which app input with no target reaches when the frontmost app isn't granted. On the host desktop that is the usual case, since the user just typed the request into the harness's own app. Such input goes to the working app (the frontmost granted app, else the granted app with the frontmost window), the layout reports that app as `focusedApp`, and the classifier gates it. Point clicks must land on a window of the app the observation is pinned to. |

**Session**

| Topic | Behavior |
|---|---|
| "Same subgoal" failures | The harness can't identify subgoals, so it counts consecutive failing batches (default 3) before escalating to `ask-user`. |
| Refusals and the no-progress window | The spec counts the window in steps, and a refused action isn't a step, so a session refused at every turn never filled it. The spec calls the failure escalation "the faster signal for a loop of refused actions" but doesn't say what ends the session when refusals continue after the user answers. Here each refused action also counts toward `noProgressSteps`, and the detail says how many were refused. |
| Missing grants | The spec's `ComputerUseResult` has no field for grants a refused action needed, and its grants are fixed once the dialog closes. The result carries `missingGrants`, in the spec's `Grant` shape, so the parent can delegate again with them. A run that needed one and met no criterion comes back `blocked`, not `done-unverified` or `no-progress`, since delegating again with the grant is the fix. The specialist's brief and each refusal say grants can't change mid-run, so it reports instead of asking the user for a grant. A refusal no task grant can fix, such as a blocked category, a tier above an app's cap, or a browser launch, records nothing. |
| Unknown delegate arguments | The spec doesn't say what happens to arguments outside the schema. They are refused, because a parent that copies its own earlier calls kept sending removed parameters such as `max_minutes`, and ignoring them never corrected it. |
| Per-call timeout | The spec bounds a session by its end time and the idle timeout, and says nothing about the turn loop's per-call tool timeout (`toolCallTimeoutSeconds`, 300 s by default). That timeout cut off handoffs and questions that were waiting on the user, so the computer-use family is exempt from it. |
| Fresh observation for `verify` | Fresh means captured at or after the most recent executed action. |
| Mixed tool results | Results that combine harness guidance with screen text are wrapped as one envelope, so the guidance lines sit inside it. The spec doesn't say how to split them. |
| Approval surface | Confirmations reuse `ExecApprovalDelivering`, which is named for exec but is the harness's general approval delivery. |
| Image retention lane | The spec keeps images "in the durable lane while anything references them". Here they sit in the ephemeral lane with an expiry past the lease's hard limit, and release moves the expiry. The effect is the same, and two things are better. A crash can't leave them durable forever. And content addressing can't make retention shorten a durable copy someone else holds: the blob store never changes a durable blob's expiry, and a durable write of the same bytes takes it out of the ephemeral rules. |
| Tool images as attachments | Saving a message normally promotes its `blob://` images to durable conversation attachments. Ephemeral images on tool messages are left alone, because the tool that stored them owns their lifecycle. Before this, every tool image was durable, so other tools are unaffected. |
| References the spec lists | The spec holds images while the live context window, a pending approval, or replay thumbnails reference them. The context window and pending approvals both end with the lease, because the specialist's context isn't reused and approval cards carry their crop inline. Thumbnails are covered by the replay's own retention. |
| Retention defaults | The spec gives vendor guidance "keep 3, prune every ~25" and also says requests should stay under ~20 images. Those conflict: batches of 25 allow up to 27 screenshots. The defaults are keep 3, prune 15 (at most 17); a model's feature can override them. |
| Pruned screenshot summary | The spec asks for a one-line text summary of each pruned screenshot. The marker reuses the observation's harness-written header line (id, app, window) rather than describing pixels, which would need a model call. |
| Catalog values | Checked against Anthropic's computer-use docs (October 2026). Claude Opus 4.6 and Sonnet 4.6 take `computer_20251124` (beta `computer-use-2025-11-24`), and Haiku 4.5 takes `computer_20250124` (`computer-use-2025-01-24`). All three take screenshot-pixel coordinates and images of at most 1,568 px and about 1.15 MP. The bundled entries, including OpenRouter's Sonnet 4.6, declare these. `version` picks the native dialect for Claude on Anthropic's API, and `betaHeader` documents the header the codec sends. Opus 4.7 and later allow 2,576 px and 4,784 visual tokens, about 3.75 MP; Opus 4.7 still takes `computer_20251124`, and Opus 4.8 and the Claude 5 family take `computer_toolset_20260801`. Host catalogs that list them should declare those values. OpenAI's and Gemini's computer use run through dedicated models, so their bundled entries don't declare the feature. |
| Pixel-area cap | The spec sizes screenshots by long edge and visual-token cap. Anthropic also rejects images over about 1.15 MP on earlier models, and a 16:10 capture at 1,568 px is 1.54 MP. So the feature carries `maxPixels`, and capture fits both caps, rounding down when the area binds. |
| Pipeline cap | Screenshots are never resized after capture. So the session also clamps them to the tool-result pipeline's `maxInlineImagePixelDimension` (1,200 px by default), or a model-sized screenshot would reach the model as a marker. Raise that setting to use a model's full limit. |
| `computer-use` role | The spec binds the role to a model with the `computer-use` feature and falls back to `main` only if `main` has it. That would rule out the harness function-tool path, which the spec's dialect table allows for any model. Here the role is `specialist.modelRef`, falling back to the parent's model when it can see images and call tools. The feature, when present, sets the coordinate dialect and screenshot size. |
| Constraint re-injection | The spec carries constraints into every step's context. Here every computer tool result ends with a reminder of the constraints and the unverified criteria, so they survive context pruning and compaction of earlier turns. |
| Return schema | The final report is parsed as JSON when a schema is given. It is not validated against the schema. |
| Specialist delivery | Runs are synchronous: the parent's tool call waits for the result. Background runs with push delivery, available to other local agents, are not offered for computer use yet. |
| Specialist result trust | The result is written by a model that saw untrusted screen content. The structured shape keeps screenshots and screen text out of the parent, but `result` and `evidence` are still model text and are not wrapped in the untrusted-content envelope. |
| OpenAI-style tool images | The spec says images must travel as images, never base64 text. Chat-completions tool messages can't hold images, so a user message right after the tool run carries them, and it names the tool calls it belongs to. |
| macOS `wait-for` | The canonical `wait-for(condition)` carries a natural-language condition the driver can't evaluate. The macOS driver waits up to 2 s and reports `unverifiable` with `escalation: observe`. |
| macOS window exclusion | The spec hides non-granted windows during the agent's turn and restores them after. The macOS driver instead captures only granted apps' windows, which never touches the user's windows. Process-routed input still can't reach non-granted apps, because the classifier refuses them. |
| macOS foreground delivery | Foreground delivery is used for every pointer and key action whenever the lease allows it. Background delivery can fail silently, so it can't escalate on failure. Each activation is reported through `onForegroundDelivery`, which `MacAgentActiveHUD` announces. |
| macOS keyboard layout | Key combos map through the US ANSI layout. Text goes through Unicode typing, which is layout-independent. |
| Oversight routing | The spec puts oversight on surfaces but doesn't say which conversation a delegated specialist's cards and questions belong to. They go to the parent, because the user never sees the child. |
| Question and handoff timeouts | The spec gives none. A question waits 10 minutes and a handoff 30, so a run nobody watches doesn't hold its lease until the run timeout. |
| Stop and pending requests | The spec's abort "runs the full cleanup path". Stop also declines the session's pending questions and handoffs, so a blocked specialist unblocks and reports instead of waiting out its timeout. |
| Surface capability | Surfaces declare `SurfaceCapabilities.computerUse` (the terminal does; channels don't). Intents are published whether or not such a surface is attached, as exec-approval intents are. |
| Replay index | The spec doesn't say how replays are found later. The index keeps 50 per conversation in memory. After a restart it rebuilds a conversation's replays the first time they're asked for: each delegate result's `actionsLog` names the stored replay document, which names every blob the run's retention covers. No separate store is needed, and the transcript stays the source of truth. |
| Replay thumbnails | They are captured as observations arrive, because the session keeps only the last few observations for citing. They follow the run's image retention. Recordings aren't supported by any target yet. |
| Audit retention | The spec says longer retention "applies only to sessions the user marks for audit" without a length. The default holds marked runs until unmarked. Set `ComputerUseRetention.audit` to bound it. Unmarking returns a run to the release TTL counted from its release, so a run unmarked after that window expires at the next sweep. |
| Audit marks after a restart | The mark is read back from the blob store: a released run whose document doesn't expire at the normal release TTL is audit-marked. Marks placed on a live run that the server lost before release are lost too; that run's images keep the normal TTL. |
| HUD placement | The spec puts the HUD in the signed host app. With an in-process target it runs in the harness process, which the capture excludes anyway. `activityObserver` and `onForegroundDelivery` feed it, so a host app can drive its own. |
| Image block | The spec wants a cropped image of the target region on approval cards, but its portable presentation vocabulary (text, context, divider, buttons, select) has no image block. `image` was added to `ApprovalBlock`, `MessageBlock`, and `approval-presentation.schema.json`, with base64 data and alt text. `SurfacePresentationCapabilities.images` gates it, and core degrades it to the alt text. |
| Terminal crops | The TUI composites dialogs into base rows, so a graphics escape can't be placed inside one. The approval card shows the crop's alt text and size instead. |
| Terminal controls | The spec asks for takeover and stop controls without naming keys. Esc is the host stop key, so the terminal uses Ctrl-T and Ctrl-X, and they work while a dialog is open. |
| Tree diffs | The spec puts AX-text diffs with the Context Engine and gives `diffAgainst` a "structured diff" without a format. The session computes them, so they work for every target, and drivers always return full trees. A diff is only usable if refs survive between observations, which the spec doesn't address, so the session makes refs stable. |
| Secret detection | The spec says to "block navigation to URLs that embed secrets, and redact secrets from any auxiliary-model inputs" without defining a secret. Detection is pattern-based (credential parameter names, user-info, JWTs, common key prefixes, and labelled values like `password: …`), so it catches common shapes rather than every secret. It covers `open-url`. A URL typed into an address bar is plain text typing, which stays under the intent check and consequential-field rules. |
| Native toolset scope | The spec's dialect table puts the vendor toolset first when one exists. It's implemented for Anthropic, the vendor whose models the bundled catalog lists. Anthropic's docs describe no safety-signal fields to acknowledge; their injection classifiers steer the model, and they leave confirming consequential actions to the client, which the session already does per action. Other vendors' safety checks wait for their toolsets. |
| Native screenshots | Native `screenshot` results carry the image and a header line (observation id, app, size), not the accessibility tree. Refs aren't usable through the native members, which take pixels only. |
| Native details | `cursor_position` reports where the session's last pointer action left the pointer, since targets don't report the cursor. Holding a modifier alone (`hold_key` with `shift`) is refused, because the macOS driver can't press a modifier as a key; members take modifiers in their `text` field instead. X11 key names map to the harness's: `Delete` is forward delete, `BackSpace` is delete, and underscores become hyphens. |
| Deferred loading mechanism | The spec defers `computer.*` tools with `defer_loading` and names `searchHint` and `shouldDefer`/`alwaysLoad` registry fields, but no search tool. Here a harness `tool_search` does the search, so it works with every provider. Vendor-side tool search isn't used. Deferral is a `defer-loading` policy tag and the hint a `search-hint:` tag, because SwiftAgentKit descriptors carry no other extensible fields. Tools without the tag load as before, which is the `alwaysLoad` default. |
| What is deferred | The spec says to keep computer-use schemas "deferred or searchable in the parent and loaded only in the sub-agent". The parent already never sees the `computer_*` tools, only the delegate, so the delegate is the deferred tool. The child loads the computer tools directly. |
| Tool-level approval | `computer_*` tools carry no `requiresApproval` tag, so the Tool System doesn't add a second prompt per click. A mode whose `approvalPolicy` is `.all` would double-gate them. |

**Display host**

| Topic | Behavior |
|---|---|
| No bundled host app | The spec ships `ComputerUseHost.app` as part of the kit. Here the library ships the host protocol, `RemoteDisplayTarget`, `DisplayHostServer`, and transports, and no app. An app would fix packaging, signing, onboarding, and UI that a library's integrators need to choose. A GUI app that embeds the harness is already the responsible process, so an in-process target is right there, not only a dev escape hatch. |
| Transport | The spec says XPC "or a peer-signature-checked socket". Both are provided. The socket transport works everywhere the core builds, and it is the one to carry over vsock or TCP to a VM. XPC needs macOS 26 for `XPCPeerRequirement`. Without peer requirements, a host would accept any local process. |
| `CUHostProtocol` shape | The spec names `CUHostProtocol` "Codable request/response + capability negotiation" without a format. Messages are JSON, so a host need not be written in Swift. The manifest in `welcome` is the capability declaration, and the protocol version is checked exactly. |
| Holder liveness across a host | `LeaseRequest.isHolderAlive` is a closure and can't cross a connection. The host treats an open connection as a live holder. The client covers holders in its own process that die without releasing: it releases their leases when a new lease is refused as busy. |
| Stop from the host | The spec's stop key and HUD Stop button live in the host. They reach the harness as a `stopRequested` event on `RemoteDisplayTarget.events`, and the integrator calls `stopComputerUse()` from it. |
| Live view and observer tokens | They aren't carried. `liveView` passes through as the target returns it, and no target serves one yet. |

**Not built yet**

Spec features with no implementation so far. Each needs something the harness doesn't have yet, or is optional in the spec.

| Feature | State |
|---|---|
| Isolated targets | Only the host desktop exists. The managed browser, desktop container, local VM, user's real browser, and paired device targets aren't built, and neither is the browser network policy (SSRF checks, private-network opt-in) that goes with browser targets. |
| Specialist scratchpad | The spec gives the specialist a scratchpad beside the computer tools. Its allow-list holds only the 15 computer tools. |
| `grounder` and `vision-describe` roles | Neither role is bound. The specialist's model localizes its own actions, and a model without vision is refused rather than given text descriptions of screenshots. |
| Labeled screenshots | Refs aren't drawn onto screenshots as tags. The model gets the tree and the screenshot side by side. |
| Code execution as a peer path | Scripts run against the leased target, gated as a whole, aren't offered. |
