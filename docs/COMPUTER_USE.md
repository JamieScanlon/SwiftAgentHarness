# Computer Use

How SwiftAgentHarness lets an agent see and drive a screen, what the harness enforces around each action, and how to wire it up.

Computer use is a **display target** (the user's desktop, a VM, a desktop container, a managed browser, a paired device) behind one observe/act contract. The model sees the screen as an accessibility tree plus a screenshot and acts through element refs, falling back to pixels. Everything around that loop belongs to the harness: leasing the target, approving grants, classifying and gating each action, checking intent, confirming consequential steps, budgets, the kill switch, takeover, and the action log.

**Contents**

- [Status](#status)
- [How it fits together](#how-it-fits-together)
- [Quick start](#quick-start)
- [The computer-use specialist](#the-computer-use-specialist)
- [Writing a display target](#writing-a-display-target)
- [Grants and tiers](#grants-and-tiers)
- [How each action is gated](#how-each-action-is-gated)
- [The intent check](#the-intent-check)
- [Budgets, kill switch, takeover](#budgets-kill-switch-takeover)
- [The tool family](#the-tool-family)
- [Screenshots in tool results](#screenshots-in-tool-results)
- [Model descriptors and the screenshot budget](#model-descriptors-and-the-screenshot-budget)
- [Implementation notes and spec gaps](#implementation-notes-and-spec-gaps)

The spec is the harness-template pages `backends/computer-use/README.md` and `backends/computer-use/macos.md`. Where this implementation interprets or departs from them, see [Implementation notes and spec gaps](#implementation-notes-and-spec-gaps).

---

## Status

This is the platform-neutral core. Everything here builds and tests without screen-capture, accessibility, or input frameworks.

| Area | State |
|---|---|
| `DisplayTarget` contract, manifests, observations, canonical actions, coordinate codecs | Done |
| Leases, tiered grants, app policy, budgets, `DisplayTargetRegistry` | Done |
| Per-action classification, intent check on `guard`, per-action confirmation, headless denial, stop key | Done |
| `computer_*` function-tool family with flat schemas | Done |
| Screenshots as image blocks in tool results (Anthropic, OpenAI, LM Studio, Ollama) | Done |
| `computer-use` feature on model descriptors, resize to the model's `maxImageEdgePx`, step-counted screenshot pruning | Done. Bundled catalogs don't declare the feature yet. |
| Computer-use specialist sub-agent (`ComputerUseTask` / `ComputerUseResult`) and composition wiring (`installComputerUse`) | Done. Synchronous runs only. |
| macOS host-desktop and VM drivers | Not yet. They will live in a separate macOS-only target. |
| Vendor-native toolsets and their safety signals, live view, replay, deferred tool loading | Not yet |

## How it fits together

```
HarnessRuntimeSession.installComputerUse(configuration)
        │
parent conversation ── delegate_computer_use(goal, success_criteria, constraints, apps, domains, …)
        │
        ▼  Sub-Agent Pool: ComputerUseTask
DisplayTargetRegistry.lease(…, approve:)            one grant dialog; host-target and permission rules
        │
isolated child conversation (computer-use specialist, subagent-minimal, tools = computer_* only)
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
        budgets: ComputerUseBudgets(maxSteps: 100, maxDuration: .seconds(15 * 60)),
        maxBudgets: ComputerUseBudgets(maxSteps: 300, maxDuration: .seconds(45 * 60), maxUSD: 5)
    ),
    approveGrants: { review in
        // Show review.grantable (with capReason / warning) and review.blocked in one dialog.
        // Return the subset the user approved, or nil to decline.
        await presentGrantDialog(review)
    },
    approvals: execApprovalDelivery,      // any ExecApprovalDelivering: per-action confirmation cards
    intentChecker: intentChecker,         // optional; see "The intent check"
    oversight: oversight,                 // optional ComputerUseOversight: ask_user and handoff
    specialist: ComputerUseSpecialistProfile(modelRef: "anthropic/claude-sonnet-4-6")   // the computer-use role
))
```

Every conversation now has `delegate_computer_use`. Bind your surface's stop control and global stop key to `session.stopComputerUse()`, which ends every live specialist session; no model-facing tool can call it.

A host that drives a session directly can still build one by hand: lease through `DisplayTargetRegistry.lease(_:approve:)`, create a `ComputerUseSession`, and install `ComputerUseToolProvider(session:)`.

## The computer-use specialist

The parent calls `delegate_computer_use` with flat arguments:

| Argument | Meaning |
|---|---|
| `goal` | What to accomplish, stated fully. The specialist cannot see the parent conversation. |
| `success_criteria` | One checkable criterion per line. |
| `constraints` | Rules to keep, one per line. |
| `apps`, `domains` | Requested grants, for example `com.apple.TextEdit:full`, `docs.example.com:click`. The user approves a subset. |
| `target`, `max_steps`, `max_minutes` | Target id and budgets, clamped to `maxBudgets`. |
| `return_schema` | Optional JSON Schema for the result. |

What happens:

1. **The task is parsed** into a `ComputerUseTask`. Malformed arguments are denied with the reason.
2. **The model is chosen.** That's `specialist.modelRef` when set, otherwise the parent's model. Either way it must see images and call tools. The session takes its coordinate dialect and screenshot size from that model's `generate` profile.
3. **The target is leased.** This raises the one grant dialog and applies the host-target rules. The run's origin decides presence: interactive runs have the user present, trigger and sub-agent runs don't. A non-owner sender is not operator-initiated.
4. **The child is spawned.** It runs on `specialist.modeProfileID` (`subagent-minimal` by default), with a closed allow-list of the 15 computer tools, so it has no shell, files, or messaging. Its brief holds the goal, numbered criteria, constraints, working rules, and the return schema.
5. **Every step restates the task.** Each computer tool result ends with a reminder of the constraints and the criteria not yet verified.
6. **The session always ends** and the lease is released. The full action log is stored as a session blob.
7. **The parent gets JSON.** That's `status`, `result`, `verification` (one entry per criterion), `handoff`, `actionsLog`, and `reason`.

| Status | When |
|---|---|
| `done` | Every criterion has a `computer_verify` entry that is met |
| `done-unverified` | Finished, but some criterion is unverified or not met |
| `needs-user` | A handoff nobody could take, or a consequential action denied with nobody present |
| `blocked` | Grants declined, target busy, permissions missing, model unsuitable, or stopped by the user |
| `budget-exhausted` | The step, time, or cost budget, or the run timeout, ran out |
| `failed` | The child failed or was cancelled |

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
| Browsers | Capped at `view`; pages are reached through domain grants |
| Finder, System Settings, Shortcuts | Grantable, with a blast-radius warning |

`ComputerUseGrantReviewer.clamp` keeps an approver from raising a tier above its cap or adding grants and flags that weren't requested. Category rules are applied again at action time, because the category is known only once the target reports it.

## How each action is gated

`ComputerUseActionClassifier` works only from data the harness derives itself: the action, the cited element (role, label, app, URL), and the grant.

| Class | Examples | Gate |
|---|---|---|
| observe | observe, zoom, wait, wait-for | allow |
| navigate | scroll, move, launch of a granted app, `open-url` on an http(s) granted domain | allow |
| interact | click, press, type, set-value, key, menu at a sufficient tier | Allowed when the intent check says consistent. With no checker bound, confirmed on `humanPresence: shared` targets and allowed otherwise. |
| consequential | Typing into secure or payment fields; targets labeled submit, send, buy, delete…; destructive shortcuts; System Settings; installers; vendor safety signals | Always confirmed |
| out of grant | Non-granted app or domain, tier violation, missing flag, non-web `open-url` scheme, the stop key | Denied, with the reason returned to the model |
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

- **Budgets.** `maxSteps`, `maxDuration` and `maxUSD` (fed by `session.recordCost(usd:)`) each end the session with a typed `ComputerUseTerminalReason` and release the lease. Permissions are polled before every batch, and a revoked one ends the session with `permission-revoked`.
- **Kill switch.** `HarnessRuntimeSession.stopComputerUse()` stops every live specialist session (`ComputerUseSession.stop()` for one you drive yourself). The stop key (Escape by default; set it with `ComputerUseActionClassifier(stopKey:)`) is never synthesized, in any spelling, while a session is active.
- **Takeover.** `session.handoff(reason:prompt:)` turns takeover on, waits for `ComputerUseOversight.handoff` to return, then turns it off. While takeover is on, observe and act are refused. Ask-user and handoff are unavailable when no user is present.
- **Verification.** `session.verify(...)` accepts only an observation taken after the last action.

## The tool family

The tools are `computer_observe`, `computer_click`, `computer_type`, `computer_key`, `computer_scroll`, `computer_press`, `computer_set_value`, `computer_menu`, `computer_launch`, `computer_open_url`, `computer_zoom`, `computer_wait_for`, `computer_verify`, `computer_ask_user` and `computer_handoff`.

- Each tool has one flat schema with primitive parameters only.
- Pointer tools take a `ref`, or `x`/`y` in the session's coordinate mode, plus the `observation` the action cites.
- The codec maps coordinates through that observation's recorded geometry, so the model never sees a scale factor.
- Results from the screen-bearing tools are wrapped in the untrusted-content envelope with the `screen` source label. `computer_verify`, `computer_ask_user` and `computer_handoff` return harness or user text and are exempt.

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
| `humanPresence` values | The manifest example shows only `shared`. `none` was added for VMs, containers, and managed browsers. |
| Registry | The spec says display targets register in the same backend registry as sandboxes. `SandboxBackendRegistry` is a static, `SandboxBackendHandle`-typed table, so display targets have their own injected `DisplayTargetRegistry` instance. Reusing sandbox pruning and observer-token machinery is still to do. |

**Grants and classification**

| Topic | Behavior |
|---|---|
| Tier for navigate actions | The spec puts scroll and move in Navigate ("allow within grant") but defines `view` as "observations only". Scroll, move, and launch therefore need `click`. |
| Menus | `menu` needs `full`, because menu items reach the same commands as shortcuts, which `click` excludes. |
| Category rules | At grant time only bundle ids are known, so category rules (finance) are also applied at action time from the app identity the target reports. |
| Labels in classification | The spec lists the element label among classification inputs and excludes labels from the intent check. Labels here can only raise an action to consequential. |
| Keyboard-submitted forms | Typing and then pressing Return can submit a form without any consequential label being seen. Harness-derived classification can't detect this, and the spec doesn't address it. The intent check is the only defense. |
| Stop key | The spec's example implies Escape. Reserving it also stops the agent from dismissing dialogs with Escape, which the spec appears to intend. It is configurable. |

**Session**

| Topic | Behavior |
|---|---|
| "Same subgoal" failures | The harness can't identify subgoals, so it counts consecutive failing batches (default 3) before escalating to `ask-user`. |
| Fresh observation for `verify` | Fresh means captured at or after the most recent executed action. |
| Mixed tool results | Results that combine harness guidance with screen text are wrapped as one envelope, so the guidance lines sit inside it. The spec doesn't say how to split them. |
| Approval surface | Confirmations reuse `ExecApprovalDelivering`, which is named for exec but is the harness's general approval delivery. |
| Screenshot blob lifecycle | Tool images are stored as durable blobs. The spec's lifecycle (durable while referenced, ephemeral TTL from lease release) is not implemented yet. |
| Retention defaults | The spec gives vendor guidance "keep 3, prune every ~25" and also says requests should stay under ~20 images. Those conflict: batches of 25 allow up to 27 screenshots. The defaults are keep 3, prune 15 (at most 17); a model's feature can override them. |
| Pruned screenshot summary | The spec asks for a one-line text summary of each pruned screenshot. The marker reuses the observation's harness-written header line (id, app, window) rather than describing pixels, which would need a model call. |
| Catalog values | The bundled catalogs don't declare `computer-use` or vision caps yet. Vendor toolset versions and image limits should be confirmed against current vendor documentation before they are added. |
| `computer-use` role | The spec binds the role to a model with the `computer-use` feature and falls back to `main` only if `main` has it. That would rule out the harness function-tool path, which the spec's dialect table allows for any model. Here the role is `specialist.modelRef`, falling back to the parent's model when it can see images and call tools. The feature, when present, sets the coordinate dialect and screenshot size. |
| Constraint re-injection | The spec carries constraints into every step's context. Here every computer tool result ends with a reminder of the constraints and the unverified criteria, so they survive context pruning and compaction of earlier turns. |
| Return schema | The final report is parsed as JSON when a schema is given. It is not validated against the schema. |
| Specialist delivery | Runs are synchronous: the parent's tool call waits for the result. Background runs with push delivery, available to other local agents, are not offered for computer use yet. |
| Specialist result trust | The result is written by a model that saw untrusted screen content. The structured shape keeps screenshots and screen text out of the parent, but `result` and `evidence` are still model text and are not wrapped in the untrusted-content envelope. |
| OpenAI-style tool images | The spec says images must travel as images, never base64 text. Chat-completions tool messages can't hold images, so a user message right after the tool run carries them, and it names the tool calls it belongs to. |
| Tool-level approval | `computer_*` tools carry no `requiresApproval` tag, so the Tool System doesn't add a second prompt per click. A mode whose `approvalPolicy` is `.all` would double-gate them. |
