# Computer Use

How SwiftAgentHarness lets an agent see and drive a screen, what the harness enforces around each action, and how to wire it up.

Computer use is a **display target** (the user's desktop, a VM, a desktop container, a managed browser, a paired device) behind one observe/act contract. The model sees the screen as an accessibility tree plus a screenshot and acts through element refs, falling back to pixels. Everything around that loop belongs to the harness: leasing the target, approving grants, classifying and gating each action, checking intent, confirming consequential steps, budgets, the kill switch, takeover, and the action log.

The core in `SwiftAgentHarness` builds without screen-capture, accessibility, or input frameworks. The macOS driver is a separate product, `SwiftAgentHarnessComputerUseMac`, which only the process that drives the Mac links.

**Contents**

- [How it fits together](#how-it-fits-together)
- [Quick start](#quick-start)
- [The computer-use specialist](#the-computer-use-specialist)
- [The macOS driver](#the-macos-driver)
- [The managed browser](#the-managed-browser)
- [Linux desktops: the desktop container](#linux-desktops-the-desktop-container)
- [Local VMs](#local-vms)
- [Paired devices](#paired-devices)
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

---

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
  - shared targets (the host desktop, the user's browser, a paired phone) only for an operator-initiated session with the user present;
  - required platform permissions are preflighted;
  - the grant dialog is shown once;
  - unattended sessions get a short absolute expiry (20 minutes by default).
- **The specialist** is an isolated child conversation whose only tools are the computer-use family. The parent sees a structured `ComputerUseResult`, never the child's transcript, screenshots, or screen text, and the result's model-written text arrives inside the untrusted-content envelope.
- **`ComputerUseSession`** gates and runs each action. It also owns budgets, the kill switch, takeover, verification records, and the action log.
- **`ComputerUseToolProvider`** is the model-facing tool family bound to one session.

## Quick start

```swift
session.installComputerUse(ComputerUseConfiguration(
    registry: try DisplayTargetRegistry(targets: [myTarget]),   // ids can't repeat a sandbox backend's
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
        // in request.conversationID's conversation, explaining request.purpose on request.target,
        // with request.liveViewNotice when it has one.
        // Return the subset the user approved, or nil to decline.
        await presentGrantDialog(request)
    },
    approvals: execApprovalDelivery,      // any ExecApprovalDelivering: per-action confirmation cards
    intentChecker: intentChecker,         // optional; see "The intent check"
    oversight: oversight,                 // optional ComputerUseOversight: ask_user and handoff
    specialist: ComputerUseSpecialistProfile(modelRef: "anthropic/claude-sonnet-4-6"),  // the computer-use role
    requiresZeroRetention: false          // true refuses models whose vendor stores the conversation
))
```

Every conversation now has `delegate_computer_use`. Bind your surface's stop control to `session.stopComputerUse()`, which ends every live specialist session; no model-facing tool can call it. A target's own stop key (the macOS host's, a display host's) reaches its session as a target event, with nothing to wire.

A host that drives a session directly can still build one by hand: lease through `DisplayTargetRegistry.lease(_:purpose:approve:)`, create a `ComputerUseSession`, and install `ComputerUseToolProvider(session:)`.

## The computer-use specialist

The parent doesn't see `delegate_computer_use` at first. It is deferred: the parent is offered `tool_search`, and a search such as "click through a desktop app" loads the delegate for the rest of the conversation. A model with an MCP tool or command for the job sees that first, and the delegate's schema stays out of the prompt until it's needed. The specialist child sees its computer tools directly. Deferral is the delegate's `defer-loading` policy tag, and its search hint a `search-hint:` tag; the search is the harness's own `tool_search`, so it works with every provider. See the Tool System README's "Deferred tool loading" section.

Runs are synchronous: the parent's tool call waits for the result.

Once loaded, the parent calls `delegate_computer_use` with flat arguments:

| Argument | Meaning |
|---|---|
| `goal` | What to accomplish, stated fully. The specialist cannot see the parent conversation. |
| `success_criteria` | One checkable criterion per line. |
| `constraints` | Rules to keep, one per line. |
| `apps`, `domains` | Requested grants, for example `com.apple.TextEdit:full`, `docs.example.com:click`. The user approves a subset. |
| `target` | Target id. Defaults to `defaults.target`, or to `defaults.webTarget` for a task with domains and no apps. |
| `steps` | Expected size of the work in actions: the first step allotment, clamped to the policy's `ceilingSteps`. Defaults to `defaultSteps`. |
| `deadline` | Only a cutoff the user stated, as an ISO 8601 date-time with a UTC offset. It can only end the session earlier. |
| `return_schema` | Optional JSON Schema for the result. |

What happens:

1. **The task is parsed** into a `ComputerUseTask`. Malformed arguments are denied with the reason, and so are arguments the schema doesn't have. A known rename gets its replacement, such as `max_steps` → `steps` or `max_minutes` → "time limits are set by the host", so a parent copying its own stale calls is corrected on the next one.
2. **The models are chosen.** The specialist's is `specialist.modelRef` when set, otherwise the parent's model. It must call tools. The session takes its coordinate dialect and screenshot size from that model's `generate` profile.
   - **A model without vision** works from the tree. Screenshots are still taken, for `computer_describe` and approval cards, but its results carry none, and `computer_zoom` isn't offered. The `vision-describe` role answers its `computer_describe` questions: `specialist.visionDescribeModelRef`, or else the first registered model that can see images. With neither, the run is blocked before leasing.
   - **The `grounder` role** is `specialist.grounderModelRef`, offered to any specialist as `computer_locate`. Its coordinate dialect comes from its own `computer-use` feature, pixels by default. Unset, the role is off.
   - A role the profile names must resolve to a model that can see images, or the run is blocked before leasing.
   - Both roles are bound only through these model refs and called through the Pool's LLM factory. They don't follow mode-profile or conversation role patches, and they emit no route receipts.
3. **The target is leased.** This raises the one grant dialog and applies the shared-target rules. The approver gets a `ComputerUseGrantRequest`: the reviewed grants, the lease request, the target's manifest, and the task's goal as `purpose`. Its `conversationID` is the user's conversation, the root of the delegation tree, so the host can show the dialog where the user asked. The run's origin decides presence: interactive runs have the user present, trigger and sub-agent runs don't. A non-owner sender is not operator-initiated.
4. **The child is spawned.** It runs on `specialist.modeProfileID` (`subagent-computer-use` by default), with a closed allow-list of the 18 computer tools, so it has no shell, files, or messaging. The mode doesn't cap the number of model turns and has no tool-level approvals. It runs under the `terminal-tool` policy: it ends only by calling `computer_finish`, and a turn that stops without it is a stall, retried under forced tool choice. The computer tools carry no `requiresApproval` tag, so a mode's per-tool approval policy never gates a click twice; it applies to the parent's `delegate_computer_use` call. The session counts steps, enforces budgets, and confirms actions itself. Tools off the allow-list are never offered, including ones that need approval. A mode's tool allow-list caps the child's, so the built-in mode allows exactly the computer tools; a custom `modeProfileID` must allow them too, or the specialist is offered nothing. The parent's per-call tool timeout doesn't apply to `delegate_computer_use`, nor to the specialist's own computer tools: any of them can wait on the user (a question, a handoff, a ceiling question, a confirmation card), and each is bounded by the session's end time and the idle timeout instead. Their entries carry `bounds-own-run-time`. The child run has no timeout of its own: it follows the session's `childRunDeadline(grace:)`, which is the lease's end time while the session runs and `specialist.cleanupGraceSeconds` (30 s by default) after it ends. A present user's extension at the time ceiling moves both, so extensions are never cut short. If the end time passes while the model is mid-turn, the deadline check makes the same decision an action would: it asks a present user, or ends the session. The session's terminal reason, not the child's timeout, decides the result's status. A child that produces nothing for `specialist.idleTimeoutSeconds` (180 s by default) is cancelled and the result is `failed` with reason `idle-timeout`, which usually points at the model binding or the driver. The child's `run_cancelled` marker records the same reason. Questions, handoffs, ceiling questions, confirmation cards, and takeover pause that clock. Its brief holds the goal, numbered criteria, constraints, working rules, the return schema, and how to end: with `computer_finish`, naming downloads to keep in `keep_files`.
5. **Every step restates the task.** Each computer tool result ends with a reminder of the constraints, the criteria not yet verified, and the specialist's own notes from `computer_scratchpad`. `computer_verify` cites a criterion by its text, its number, or as the reminder lists it (`1. The title is bold`). When the task has criteria, a citation that matches none of them is refused with the list, so a miscopied criterion can't leave the result `done-unverified` without the specialist knowing.
6. **The session always ends** and the lease is released. The full action log is stored as a session blob.
7. **The parent gets JSON.** The harness's fields are plain JSON: `status`, `verification` (one entry per criterion, met or not), `handoff`, `budget` (`stepsUsed`, `stepsGranted`, `extensions`, `lastProgressStep`), `actionsLog`, `reason`, `missingGrants` when refused actions needed grants the task didn't have, `grantNotes` when requested grants do less than they ask (a browser above `click`, a browser with no domains, or an app above its cap), and `downloads`. The specialist's own text (its result, each criterion's evidence, and a handoff's prompt) is model text written after reading untrusted screens, so it sits in `report`, inside the untrusted-content envelope labeled as a computer-use specialist report. The result is what the specialist submitted with `computer_finish`, never its final message; a run that ends without one has no result, and `reason` says so. With a `return_schema`, the result is validated against it (`type`, `enum`, `const`, `properties`, `required`, `additionalProperties: false`, `items`, and bounds) when `computer_finish` is called. A first call with a mismatch or a bad `keep_files` path is rejected, and the specialist is run once more, while its session is still live, to call it again. That last call commits what is valid: a mismatched result is left out, and `reason` says why. Grant entries have the shape of a task grant, `{ "domain": "www.apple.com", "tier": "click" }` or `{ "app": "com.apple.Terminal", "tier": "full", "flags": ["system-keys"] }`. `downloads` lists every file the run downloaded, `{ "name", "bytes", "kept", "attachment" }`. A managed browser's files are kept only when the specialist names them in `keep_files`; those move to the delegating conversation's attachments, and the rest are deleted at release. The user's browser's files all stay where they are, and only named ones are also copied to the attachments. `attachment` is the copy's blob id. Copies are tagged `unknown-party`, and a file over the blob size cap (`SAH_SESSION_BLOB_MAX_BYTES`, 5 MB by default) isn't copied; a managed browser's then stays in its folder. A session that a mode's denial ended comes back `blocked` with reason `policy-revoked`, and one whose remote lease was lost `failed` with `holder-lost`.

| Status | When |
|---|---|
| `done` | Every criterion has a `computer_verify` entry that is met |
| `done-unverified` | Finished, but some criterion is unverified or not met |
| `needs-user` | A handoff nobody could take, a question or handoff nobody answered in time, a stop while one was open, or a consequential action denied with nobody present |
| `blocked` | Grants declined, target busy, permissions missing, model unsuitable (including a vendor-stored model when the host requires zero retention), or stopped by the user. Also a run whose refused actions needed grants it didn't have and that met no criterion, whether it finished or ended with no progress; `reason` names the `apps` and `domains` to delegate again with |
| `budget-exhausted` | The step ceiling, the time ceiling, the unattended grant expiry, the cost cap, or the run timeout was reached. After extensions it means the work was moving and ran out of room, so delegating the remainder is reasonable |
| `no-progress` | Too many steps in a row made no progress. Repeating the same delegation won't help: rephrase the goal, try another approach, or ask the user |
| `deadline` | The task's stated cutoff passed |
| `failed` | The child failed, was cancelled, or went silent for its idle timeout (`reason: idle-timeout`) |

## The macOS driver

`MacHostDisplayTarget` drives the user's own Mac. macOS grants Screen Recording, Accessibility, and Post Event to the *responsible process*, so where the target runs decides who holds those grants:

- **Inside a signed GUI app that embeds the harness**, the app holds them. Run the target in-process and set `embeddedInSignedApp`, so its label is "This Mac".
- **Inside a command-line tool or server**, the terminal or launchd would hold them, and every program run there inherits them. That is the development escape hatch, and the target's label says "This Mac (in-process development mode)". For anything else, run the target in a separate signed process and connect to it; see [Hosting a target in another process](#hosting-a-target-in-another-process).

```swift
import SwiftAgentHarnessComputerUseMac

let hud = await MacAgentActiveHUD(onStop: { Task { await session.stopComputerUse() } })
var macConfiguration = MacHostDisplayTarget.Configuration(
    excludedBundleIDs: ["com.example.my-harness-ui"]   // never captured, never granted
)
macConfiguration.onForegroundDelivery = { app in await hud.noteForegroundDelivery(app: app) }
macConfiguration.embeddedInSignedApp = true           // a notarized GUI app that owns its grants
let mac = MacHostDisplayTarget(configuration: macConfiguration)
// Show mac.permissionChecklist() during onboarding. The stop key (⌃⌥⌘. by default, `stopKey`) is watched
// during each lease and needs Input Monitoring.

session.installComputerUse(ComputerUseConfiguration(
    registry: try DisplayTargetRegistry(targets: [mac]),
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
| Accessibility | It reads the focused window of the working app. AX calls run on a dedicated serial queue, never the cooperative pool, with one batched attribute read per element. Traversals are bounded by a 1 s messaging timeout, a 1.5 s deadline, and depth, node, and child budgets, and return partial trees with the reason. Chromium and Electron are asked to build their trees (`AXManualAccessibility`). The page a window shows is its outermost `AXWebArea`: its `AXURL` is the observation's `url`, and its frame clipped to its scroll area is `pageBounds`. Elements inside a web area carry that area's URL (a nested frame's own); the browser's controls carry none. Screenshot-only observations find the page with a short search that stops at the web area. |
| Refs | An `eN` ref is valid only with its observation. Before acting, the element is re-read: a changed role or label, or a move beyond 8 pt, refuses with `escalation: observe`. Points are refused when the app has quit or restarted, checked by pid plus launch date, and when the point isn't over one of the app's windows or another app's floating window, such as the Dock, covers it. Other apps' normal windows don't block a process-posted event, which passes them. A foreground pointer event lands on whatever is on top, so it is refused when the window on top at the point belongs to an app that isn't granted. |
| Delivery | Background first. It tries the accessibility action (press, set value read back, focus, menu walk), then events posted to the target process. With `delivery: .foregroundAllowed` on the lease, foreground delivery is used only on a trigger: canvas and game apps (by app category) and right-clicks into Chromium browsers get it from their first action, and a process-posted action that changes neither the app's focused-window tree nor its window's pixels comes back `suspected-noop` with `escalation: foreground`, after which that app's actions go to the foreground. The no-op action is never re-sent. Canvas apps are recognized by the graphics-and-design category and games by any games category; Chromium browsers by bundle id. The no-op probe compares the focused window's tree text and the front window's pixels 150 ms after delivery, and runs only when the lease allows the foreground. Foreground delivery activates the app, posts global events, and restores the previous app on release, unless the user changed the frontmost app meanwhile. |
| Input hygiene | It uses a private event source. Clicks settle 50 ms after the move, and double and triple clicks set click states. Key combos map through the US ANSI layout. Text goes through Unicode typing, which doesn't depend on the layout, in chunks of at most 20 UTF-16 units on grapheme boundaries. Held keys and buttons are released after every batch, on takeover, and on release. Paste saves, writes, verifies, pastes, and restores the clipboard. |
| HUD | `MacAgentActiveHUD` is a non-activating panel at the top of the main screen, on every Space, for the whole session. It says who is in control, the step, app, and last action, and how to stop. It has a Stop button, and it announces each escalation to foreground delivery. `sharingType = .none` keeps it out of every capture. |
| Stop key | ⌃⌥⌘. by default (`Configuration.stopKey`; `nil` watches nothing), not Escape, which the agent needs for dialogs. During each lease a `MacStopKeyMonitor`, a listen-only event tap (Input Monitoring) on its own run-loop thread, sends the session `stopRequested`. Any other key the user presses is reported as `userTyping`, and the agent's input waits two seconds after the last one; keys this process posted aren't the user's. The tap can't swallow events, and it doesn't need to: the harness never synthesizes the stop key. |
| Evidence | Most pointer and key actions are `unverifiable`, because only a fresh observation can confirm them. A set-value that reads back is `confirmed`. A semantic call that timed out is `unverifiable` with `escalation: observe` and is never retried. |

**A live view of the user's own Mac.** Set `liveFrames: .grantedApps` to let the user watch the agent, and complete handoffs, from somewhere other than the Mac, such as their phone. The target then declares `observerAccess: stream`. The display host process serves it, and the harness serves the view by connecting with `RemoteDisplayTarget.connect(using:…, liveView:)` (see [Live view through a host](#hosting-a-target-in-another-process)).

- **What it shows.** The granted apps' windows, as the agent's own captures do, never the harness's own UI, with the pointer. Frames keep coming during takeover, when the user needs them. Where another window covers a granted one, that part is blanked, so the viewer can see where input won't land.
- **Where input goes.** Only during the user's takeover, and only to granted apps, at any tier, since takeover is the user acting:
  - a pointer event where a granted app's window is on top; the harness's own windows and the HUD count as ungranted, since a viewer's click doesn't bring the app forward first;
  - a drag, checked at every move; its release outside granted windows lands where it last was, so no button stays held;
  - keys and text while a granted app is frontmost;
  - global shortcuts (`systemShortcuts`, the classifier's list by default) only when the frontmost app's grant has `system-keys`;
  - never the stop key.

  The menu bar, the Dock, and apps outside the grant, such as a password manager, can't be used from the view.
- **Disclosure.** The grant dialog's `ComputerUseGrantRequest.liveViewNotice` says that granted apps' windows can be watched from a live view, and controlled from it during a takeover. Observers are off for this view unless `maxObserversPerSharedFeed` allows them.

`liveFrames: .wholeDisplay` shows the whole main display and takes input anywhere. It is for a macOS VM guest only; see [Local VMs](#local-vms).

**Check with the apps you target.** Behavior that varies by app and OS release:
- capture of minimized and other-Space windows;
- whether `SCWindow.frame` matches the captured window region exactly;
- the per-event Unicode length on macOS 26 and 27;
- which apps the tree-and-pixels probe misjudges, either way, as having ignored a process-routed event;
- AX trees in Chromium and Electron apps.

## The managed browser

`ManagedBrowserDisplayTarget` drives a Chromium-family browser over the DevTools protocol. It has none of the user's data or sign-ins, so it is the target for web work: set it as `webTarget`, and a task that grants domains and no apps runs there unless it names a target.

```swift
let browser = ManagedBrowserDisplayTarget.localChromium(
    configuration: ManagedBrowserConfiguration(
        network: BrowserNetworkPolicy(blockedDomains: ["ads.example"])   // private network access is off by default
    ),
    chromium: ManagedChromiumConfiguration(headless: true),
    liveView: DisplayLiveViewServer()                                    // the user watches, and takes over, in a live view
)
session.installComputerUse(ComputerUseConfiguration(
    registry: try DisplayTargetRegistry(targets: [mac, browser]),
    defaults: ComputerUseSpecialistDefaults(target: MacHostDisplayTarget.defaultID, webTarget: browser.manifest.id),
    approveGrants: …
))
```

`ManagedBrowserDisplayTarget.hosted(endpoint:)` drives a browser reached by its DevTools WebSocket URL instead, such as a hosted one.

### The user's own browser

`ManagedBrowserDisplayTarget.userBrowser(endpoint:)` attaches to the user's running Chrome, for web tasks that need their sign-ins. It is the same driver in the `user` profile mode:

```swift
let yours = ManagedBrowserDisplayTarget.userBrowser()   // .chrome: Chrome's DevToolsActivePort file
```

- **Reaching it.** Chrome writes a `DevToolsActivePort` file into its user data directory while it accepts a debugger: when the user allows remote debugging at `chrome://inspect/#remote-debugging` (Chrome then asks them to allow each connection), or started it with `--remote-debugging-port`. `UserBrowserEndpoint.chrome` reads Chrome's default directory; `.devToolsActivePort(directory:)` reads another, and `.webSocket(_:)` takes a URL. A lease fails with those instructions when the file isn't there.
- **A host target.** The manifest is `user-browser`, isolation `host`, `humanPresence: shared`. Like every shared target it needs an operator-initiated session with the user present, and it is never a default: a task names it. Interact actions are confirmed unless an intent check passes them, and every script is confirmed.
- **Its own tabs.** Each lease opens a background tab in the user's profile and works only in it and the tabs it opens; `describe` and observations show those alone, never the user's other tabs. Release closes every tab the lease opened and disconnects; the browser keeps running.
- **Popups and downloads.** A popup from the agent's tab becomes a tab of the lease; the user's own new tabs are left alone. Chrome's download setting is browser-wide, so for the length of the lease the browser saves every download into a folder of the lease's own, and the user's own downloads that land there are moved to `~/Downloads`. The agent's downloads all stay on disk and are listed in the result; those the specialist names in `keep_files` are also copied to the delegating conversation's attachments. At release the browser's download behavior goes back to its default.
- **Network.** The browser's network is the user's. The policy is applied to navigations and final URLs, as for a hosted browser.

| Piece | Behavior |
|---|---|
| Isolation | A launched browser declares `process` (a separate process on the host's OS and network) and a hosted one `remote-browser`; both are `humanPresence: exclusive`, so runs nobody started at the keyboard may use them. For policy, `process` counts as isolated for data but not for network, which is why the browser enforces the network policy itself. Each lease launches a fresh Chromium with a throwaway profile in a temporary directory (connecting, for a hosted browser), creates a new browser context whose downloads go to the lease's folder, and disposes of it on release. The launched browser inherits no descriptors but its pipe, and `--use-mock-keychain` keeps it out of the user's keychain. The pipe's ends are close-on-exec in the harness, so no other child holds it open: Chromium exits by itself when the harness dies without releasing. Profiles go under `ManagedChromiumConfiguration.profileRoot` (`SwiftAgentHarness-browser-profiles` in the temporary directory by default), and each launch deletes profiles there whose browser is gone: one locked by a dead process on this host, or an unlocked one untouched for 10 minutes. A killed harness's profile, cookies included, lasts until the next launch. |
| Network | A launched browser's only route out is a loopback SOCKS5 proxy (`BrowserNetworkProxy`) that applies the `BrowserNetworkPolicy` to every connection: each redirect hop, subresource, and WebSocket. Loopback goes through the proxy too, local name resolution is disabled so names reach the proxy unresolved, and QUIC and non-proxied WebRTC UDP are off. The proxy checks the name, resolves it, checks every address, and connects to the address it checked. It fails closed: a name that doesn't resolve, or resolves to any non-public address while private network access is off, is refused. |
| Policy | Only `http`, `https`, `ws`, and `wss` load. Non-public addresses are the IANA special-purpose ranges, including cloud metadata (169.254.169.254), shared space (100.64/10), and IPv6 forms that embed an IPv4 address (mapped, NAT64, 6to4), which are judged by the address they embed. Single-label names and `.localhost`, `.local`, `.internal`, `.intranet`, `.lan`, `.home.arpa`, and `.corp` names are refused before resolution. `allowsPrivateNetwork` opts into all of them. `allowedDomains` and `blockedDomains` match like domain grants, and the block list wins. |
| Navigation | `open-url` is checked against the policy before `Page.navigate`, and after every action the page's final URL is checked again: a page that ended on a blocked URL is cleared to `about:blank` and the outcome is `partial`. Connections the proxy refused during an action are listed in its evidence. |
| Perception | The DOM and pixels. A page on a domain the lease doesn't grant is reported by its URL only, with no tree or screenshot, and `open-url` to one is refused. The tree is built by a script in an isolated JavaScript world: page scripts share the DOM but can't reach the script, its state, or the built-ins it calls, so they can't forge what it reports. It lists interactive elements, headings, images with alt text, and text blocks, through open shadow roots and same-origin frames, up to 600 elements; offscreen elements are marked. Password values are reported as a length only. Screenshots are rendered at the model's size through the clip's scale, so they need no resizing, and a zoom renders at twice the CSS resolution. |
| Coordinates | The target's space is the page viewport in CSS pixels (1280×800 by default) at device scale 1. The browser's own UI isn't part of it. |
| Refs | An element keeps its ref for the life of its document. Before acting, the ref is looked up live in the document it was observed in, and refused if it is gone or its role or label changed. A click on a ref scrolls it into view and lands on its live center with trusted mouse events, and is refused when another element covers that point. A point is refused when the page navigated or scrolled since its observation, since the content under it moved. |
| Delivery | Always background: CDP input reaches the page, never the browser's UI or the host. `press` is a DOM `click()`, which works on covered elements. `set-value` writes through the field's native setter, fires input and change events, and is `confirmed` when it reads back. Typing inserts text and presses line breaks and tabs as keys. Copy and paste commands aren't sent, so the host clipboard is never read or written; the paste typing mode inserts the text. |
| Page events | A JavaScript dialog (`alert`, `confirm`, `prompt`, `beforeunload`) pauses the page and the agent: the next observation is the dialog, its message and its buttons as refs `d1` (OK) and `d2` (Cancel), plus a `d3` text field for a prompt, and any other action is refused until one is pressed. It is never answered automatically. An action that opens a dialog returns as soon as the dialog shows, with an observe escalation, instead of waiting on the blocked page. A popup opens as a new, active tab under the same grants and policy; observations list the lease's tabs, and `computer_observe` with `tab` switches to one. Downloads land in a folder of the lease's own (`downloadsDirectory`, a temporary folder by default) and are reported in the next observation. When the session ends, the files the specialist named in `computer_finish`'s `keep_files` move to the delegating conversation's attachments, and the rest are deleted with the folder. All of them are listed in the result's `downloads`. |
| Evidence | A navigation the action caused is `confirmed`. Otherwise pointer and key actions are `unverifiable`, with the evidence saying whether the DOM changed. |
| Takeover | Pauses capture and agent input. The user completes a handoff in the live view, or in the window of a headed browser. A headless browser with no live view has nothing to take over in. When takeover ends, the page's URL is checked against the policy, and a blocked page is cleared and reported in the next observation. What the user typed through the live view is kept from helper models (see Secrets below). |
| Scripts | The manifest declares `scripting: [javascript]`. `computer_run_script` sends the script as one `script` action. It runs as the body of an async function in a fresh isolated world of its own: it shares the page's DOM, but neither the page's JavaScript nor the world the tree builder keeps its refs in, so it can't forge what observations report. It runs with a user gesture, and is stopped at `timeout_ms` (10 s by default, 60 s at most), including a busy loop. What it returns comes back as JSON, cut at 2,000 characters, in the screen's untrusted envelope. A throw, a timeout, or a stop is `partial` with an observe escalation, since the script may have run in part. Everything it loads goes through the browser's network policy, and the page's final URL is checked after it as after any action. The approval card shows the whole script; the command and the action log keep only its hash. |
| Live view | With a `DisplayLiveViewServer`, the manifest declares `observerAccess: stream` and each lease opens a feed. The page is streamed (Chromium's screencast, JPEG) only while someone watches. A viewer's input during takeover reaches the page only, never the browser's UI or the host, and the network policy applies wherever the user goes. See [Live view](#live-view). |

### Live view

`DisplayLiveViewServer` serves a viewer page and a WebSocket stream for any number of targets, one feed per lease. One server can be shared by every target in the registry; it starts listening on the first link.

- **Links.** `target.liveView(lease)`, `ComputerUseControlService.liveView(conversationID:lifecycleID:)`, or `POST /api/conversations/{id}/computer-use/runs/{lifecycleID}/live-view` mints a link like `http://127.0.0.1:52144/view#<token>`, with an `id`. Each call makes a new 256-bit token from the observer-token issuer the sandbox backends' noVNC links also use. It sits in the URL fragment, which browsers never send, so it appears in no request line, log, or referrer. The page clears it from the address bar and presents it as the stream's first message. Tokens govern connecting, not staying connected: a link connects once, before `linkLifetime` (10 minutes by default) passes, and the viewer then watches until its connection is revoked or the lease ends. A reload needs a new link. Releasing the lease ends its viewers and revokes its unused links.
- **Revoking one connection.** `target.liveConnections(lease)`, `ComputerUseControlService.liveConnections(conversationID:lifecycleID:)`, or `GET …/runs/{lifecycleID}/live-view/connections` lists the connected viewers by their link's id, role, and connection time. `revokeLiveView(…, id:)` or `DELETE …/live-view/connections/{linkID}` ends that one connection (its page says the view was revoked), or revokes the link if it hasn't connected.
- **Control.** A viewer is view-only. A user link's input reaches the page only while the session is taken over, through `POST …/takeover` or a handoff, and never an observer link's. The viewer shows which state it's in. Mouse, wheel, and key events are sent as CDP input in the viewport's CSS pixels, clamped to the viewport, and pasted text is inserted as typed, so the user can paste from a password manager. The server drops input outside takeover, and the target checks again.
- **Observers.** A link is for the user unless it is minted with `role: .observer` (`target.liveView(lease, role:)`, `ComputerUseControlService.liveView(conversationID:lifecycleID:role:)`, or `{"role": "observer"}` in the `POST …/live-view` body). An observer link is for someone else to watch: it never carries input, and while the user has control the observer is sent no frames, its page clears the picture and says the view is paused, and it catches up with the current frame at hand-back. When observers are ended, their page says the user stopped sharing, not that the session ended (the `ended` message's `reason` is `sharingStopped` rather than `sessionEnded`). The user may be signing in or paying during a takeover, which even the agent doesn't see. Observers have their own limit, `maxObserversPerFeed` (4 by default; `0` turns observer links off), so they can't take the user's places. A shared target's feed, someone's own screen such as the user's browser or Mac, takes none unless `maxObserversPerSharedFeed` (0 by default) allows them; minting an observer link for one is refused. `endObservers` (`DELETE …/runs/{lifecycleID}/live-view/observers` over REST) ends every observer's stream and revokes the observer links, and leaves the user's.
- **Page hardening.** The page and stream refuse to be framed (`X-Frame-Options: DENY`, `frame-ancestors 'none'`), are sent `no-store` and `no-referrer`, and load no scripts but their own. A stream opened from another site's page is refused by its `Origin` even with a token, and one that doesn't present a token within `authenticationTimeout` is closed. At most `maxViewersPerFeed` of the user's viewers and `maxObserversPerFeed` observers (`maxObserversPerSharedFeed` on a shared target) watch one feed.
- **In the terminal.** The TUI shows a run's link as a clickable URL under its indicator line. **Ctrl-O** mints a new one for each run whose target serves a live view, and taking over (with **Ctrl-T** or through a handoff) mints one on its own, since a headless browser can't be used any other way. While a link is shown, a handoff dialog says to use the target through it, or, on someone's own screen such as their Mac, at the machine or through it. A link drops off once it can no longer admit a viewer, and one that isn't a plain http or https URL is never shown. **Ctrl-G** shares: it mints an observer link for each such run and shows it on its own line, marked view only, to pass on. Pressing it again stops sharing (`endObservers`) for every shared run. A run stays shared after its link stops admitting viewers, since anyone already watching keeps their view, and the line says new viewers can't join; to let more people in, stop sharing and share again, which disconnects those watching.
- **Reaching it from elsewhere.** The server listens on loopback. For a viewer on another machine, put it behind a tunnel or TLS reverse proxy and set `publicBaseURL`; the proxy must pass `/view`, `/viewer.js`, and `/stream` (a WebSocket upgrade) through.

```swift
let liveView = DisplayLiveViewServer(configuration: DisplayLiveViewConfiguration(publicBaseURL: URL(string: "https://agent.example.com/live/")))
let browser = ManagedBrowserDisplayTarget.localChromium(liveView: liveView)
```

## Linux desktops: the desktop container

`X11DisplayTarget` drives a Linux desktop on an X display from inside it, by running `xdotool`, ImageMagick's `import`, and `xprop` there through a `DisplayCommandRunner`. `X11DisplayTarget.desktopContainer()` gives it a throwaway Docker container per lease:

```swift
let desktop = X11DisplayTarget.desktopContainer(
    configuration: DesktopContainerConfiguration(network: "none"),   // the default: the desktop reaches nothing
    // network: "bridge", allowsUnfilteredNetwork: true            // another network has no egress filter
    liveView: liveView
)
```

Build the image first: `docker build -t swiftagentharness/desktop:latest docker/desktop`. It is Debian with Xvfb on `:99`, Fluxbox, the driver's tools, `xterm`, Mousepad, and `xdg-utils`. Any image with those tools and an X server on `display` works.

| Piece | Behavior |
|---|---|
| Isolation | `container`, `humanPresence: exclusive`: no user data, so runs nobody started at the keyboard may use it. Each lease runs a fresh container (`docker run --rm`, labeled with this process as owner) on `network` (`none` by default), with memory and process limits, waits for its display, and removes it on release. The harness puts no egress filter on any other network, so a lease on one fails unless `allowsUnfilteredNetwork` acknowledges that. Each start removes containers whose harness on this host has died. |
| Perception | Pixels only: no accessibility tree is read, so the specialist works from screenshots and points. Screenshots are scaled to the model's limit inside the container, and a zoom crops there. The observation names the focused window, its `WM_CLASS` as the app, its pid, and the process's start time from `/proc`. Window titles aren't read. |
| Grants | Apps are named by `WM_CLASS`, such as `XTerm` or `Mousepad`. |
| Actions | Pointer actions take points and refuse refs. A point is refused, with an observe escalation, when the focused window changed since its screenshot. Clicks, drags, and scrolls go through `xdotool`, with modifiers released however the action ends. Typing passes the text on standard input, never on a command line. `launch` takes a command name and `open-url` uses `xdg-open`, each passed as an argument, never as shell text. Press, set-value, menus, and scripts are refused. |
| Live view | With a `DisplayLiveViewServer`, the screen is captured as JPEG every `liveViewFrameInterval` (500 ms) while someone watches, and a user viewer's input reaches the desktop through `xdotool` during takeover, with the same tokens, observers, revocation, and controls as the managed browser. |

Only the default `none` network is closed. The harness filters no other network a container joins, so give a container network access only when the work needs it and the network itself limits where it can reach.

`X11DisplayTarget(configuration:liveView:provisioner:)` drives any other X display: give it a provisioner that returns an `X11DesktopSession` with a runner for where the display is. `SSHDisplayCommandRunner` runs the tools on another machine, quoting every argument for the remote shell.

## Local VMs

`VirtualMachineDisplayTarget` starts a VM from a clean image for each lease and drives it through a driver inside the guest, so delivery lands on the guest's own display. Release releases the guest's lease and stops and deletes the VM.

```swift
let vms = TartVirtualMachineController(configuration: TartVirtualMachineConfiguration(baseImage: "ubuntu-desktop"))
let linux = VirtualMachineDisplayTarget.linux(
    controller: vms,
    configuration: LinuxGuestConfiguration(user: "admin", identityFile: "~/.ssh/vm"),
    liveView: liveView,
    host: LocalDisplayCommandRunner()
)
let mac = VirtualMachineDisplayTarget.macOS(
    controller: TartVirtualMachineController(configuration: TartVirtualMachineConfiguration(baseImage: "macos-agent")),
    configuration: MacGuestConfiguration(port: 7420, secret: guestSecret),
    liveView: liveView
)

// In the guest's image, the display host the macOS target connects to:
let driver = MacHostDisplayTarget(configuration: .init(liveFrames: .wholeDisplay))
let listener = try await DisplayHostTCP.listen(host: "0.0.0.0", port: 7420, secret: guestSecret)
try await DisplayHostServer(target: driver, name: "macos-vm").serve(listener)
```

| Piece | Behavior |
|---|---|
| `TartVirtualMachineController` | Runs VMs with Tart. Each start clones `baseImage` to `sah-vm-<pid>-…`, runs it with `--no-graphics`, and waits for its address (`tart ip --wait`). Stop stops and deletes the clone. Each start deletes clones whose harness has died. Any other `VirtualMachineController` works. |
| Linux guests | `linux(controller:configuration:liveView:host:)` drives the guest with `X11DisplayTarget`, its tools run over SSH (`SSHDisplayCommandRunner`, key authentication, every argument quoted for the remote shell). The guest needs `xdotool`, ImageMagick, `xprop`, and an X session for `user` on `display`. It behaves like the desktop container: pixels only, with the same live view. |
| macOS guests | `macOS(controller:configuration:)` connects to a display host in the guest: a `DisplayHostServer` serving the macOS driver and listening with `DisplayHostTCP` on `port`, which the guest's image starts and has the screen-capture and accessibility permissions for. It retries while the guest boots, up to `connectTimeout`, and reconnects (reattaching the lease) if the connection drops. The guest's events, such as its stop key, reach the session. The manifest is `vm` and `humanPresence: exclusive` whatever the guest's driver declares, since nobody uses the guest. The guest's platform permissions are set up in its image: the VM target declares none, and a missing one fails the guest's actions. |
| macOS guest live view | With a `DisplayLiveViewServer`, the harness serves the guest's live view itself, with the same tokens, observers, and controls as the managed browser: while someone watches, it asks the guest's display host for a frame (`liveFrame`) every `liveViewFrameInterval` (500 ms), and during takeover it passes a viewer's input on (`liveInput`). The guest's driver gives frames out with `liveFrames: .wholeDisplay`: the whole main display as JPEG, every app but the excluded ones, with the pointer, since in a VM nothing on screen is anyone else's. Frames keep coming during takeover, unlike observations, so the user can see what they're doing. Input is posted to the foreground through the driver's event source. The user's own Mac uses `.grantedApps` instead. |
| `DisplayHostTCP` | The display host protocol over TCP. Both ends prove they hold a `DisplayHostSecret` (256 bits or more) with HMAC-SHA256 over fresh nonces before any message passes; a peer that can't is closed, and one that doesn't answer within 10 seconds is dropped. Traffic isn't encrypted: use it on a network only the two ends share, such as Tart's host-only network, or in a tunnel. Images travel inline, since the two ends don't share a filesystem. |

A VM has whatever network its controller gives it. The harness puts no egress filter on it, so limit the VM's network in the controller or on the host.

## Paired devices

`AndroidDisplayTarget` drives an Android phone or emulator over `adb`. There is no iPhone target: iOS has no comparable host-side automation channel without a developer tool chain on the device. A second machine is paired differently: run a display host on it and reach it with `RemoteDisplayTarget` over `DisplayHostTCP` (see [Hosting a target in another process](#hosting-a-target-in-another-process)).

```swift
let phone = AndroidDisplayTarget(configuration: AndroidDeviceConfiguration(serial: "R5CT1234ABC"))
```

| Piece | Behavior |
|---|---|
| Manifest | `remote-device`, `humanPresence: shared` by default (a paired phone is someone's), so it needs an operator-initiated session with the user present, and interact actions are confirmed unless an intent check passes them. Delivery is `background`: the phone is its own display and never touches this machine's. |
| Perception | Screenshots with `screencap`, cropped and scaled to the model's limit in the harness (ImageIO), and the accessibility tree with `uiautomator`. The tree lists clickable, focusable, and labeled nodes, with their class, label, resource id, and frame; password fields are marked secure. The observation names the focused package as the app and its activity as the window. |
| Actions | Taps, long presses (a right click), two-point swipes, scrolls as swipes, typing with `input text`, and key events. A ref is tapped at its center in a fresh tree, and refused if the same element (class, resource id, label) isn't within 24 pixels of where it was. A point is refused once another activity is in front. `launch` takes a package name and `open-url` sends a view intent. Every argument is quoted for the device's shell. |
| Limits | `adb` types only printable ASCII, so other text is refused and left to the user. Modifier keys, pointer moves, holds, multi-point drags, set-value, menus, and scripts are refused. Takeover pauses the agent while the user uses the phone; there is no live view. |

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

// In the harness; the connector runs again to reconnect and reattach after a drop:
let remote = try await RemoteDisplayTarget.connect(using: {
    try await DisplayHostSocket.connect(path: socketPath, peers: try .sameTeamAsThisProcess())
})
let registry = try DisplayTargetRegistry(targets: [remote])
// The host's stop key, permission changes, and takeover reach each session as target events.
```

| Piece | Behavior |
|---|---|
| `DisplayHostProtocol` | Version 7.0. JSON messages: a request with an id, a response echoing it, or an event. The client opens with `hello`, giving its version (`major.minor`) and capabilities (`live-view`, `downloads`, `events`, `reattach`, `image-files`); the host answers `welcome` with its own, its manifest, and the capabilities both have. A different major version is refused with a typed `versionMismatch`; a different minor one proceeds, and a request outside the shared capabilities is refused as `unsupported`. Unknown capability names decode, so a newer peer doesn't fail the handshake. Requests can be in flight concurrently. Leases are named by id. |
| Images | On a transport that shares a filesystem (Unix socket, XPC, in-process), observation images and live frames travel as files the host writes into its image folder, named at the handshake; the client reads each file only from that folder and deletes it. Over TCP they travel inline. A sandboxed host app needs a folder the harness can read too: set `DisplayHostServerConfiguration.imageDirectory`. |
| Events | The host pushes each lease's target events to the connection holding it: the stop key, a takeover started or ended at the target, the user typing, values typed during takeover. It polls the target's permissions while it has leases (every 2 s by default) and pushes a change. `requestStop(leaseID:)` sends `stopRequested`, for a HUD's Stop button. |
| Liveness | A lease is bound to its connection. When the connection drops, a lease whose connection agreed on `reattach` is kept for `reattachGrace` (5 s by default), then released as `holder-lost`; without `reattach` it is released at once. The holder counts as alive during the grace period, so nobody else can take the target. Each lease comes with a reattach token of 256 random bits. A new connection presenting it takes the lease back, with a new token and a snapshot of the lease's state (its permissions and whether takeover is on) instead of the events it missed. Tokens are compared in constant time, and a wrong or spent token is refused just as an unknown lease is. While detached, the host still watches the lease's events: a stop press releases the lease as `kill-switch` on the spot. The host then keeps only the ending's reason, for the grace period plus `endedRecordMargin` (2 s by default), and a reattach with the lease's token gets it as `leaseEnded` exactly once. The client posts it as a `leaseEnded` event, so the session ends as stopped by the user. A refused reattach, or none within `reattachWindow`, ends the session as `holder-lost`. |
| `RemoteDisplayTarget` | A `DisplayTarget` the harness uses like a local one. Target errors arrive as themselves. Made with `connect(using:)`, it reconnects through its connector when the connection drops, for up to `reattachWindow`, and reattaches its leases; calls in flight at the drop fail with `driverFailure`, and later calls wait for the reconnection. Made with `connect(over:)`, a drop is final: calls fail and `permissions()` reports nothing granted. Given a `liveView` server, it serves the live view itself; see below. `close()` releases the leases still held as `holder-lost`. If a lease is refused as busy and a holder in this harness has died, the client releases that lease and retries. |
| `DisplayHostServer` | Serves one target to any number of connections. Each connection can only use leases issued to it or that it reattached. `DisplayHostServerConfiguration` sets the reattach grace, the permission poll interval, and the image folder. |
| `DisplayHostSocket` | A Unix-domain socket with length-prefixed frames. The socket file is owner-only. Both ends check the other's peer (pid, uid, audit token) against a `DisplayHostPeerRequirement`. The default is the same user, so any process the user runs could connect: require a code signature as well for a host that drives the user's desktop. It works everywhere the core builds. |
| `DisplayHostPeerRequirement.codeSignature(_:)`, `.sameTeamAsThisProcess()` | Mac only. Checks the peer's code signature through its audit token, so a reused pid can't pass. |
| `DisplayHostXPC` | Mac only, macOS 26 or later. Serves a launchd Mach service or an anonymous listener's endpoint, with an `XPCPeerRequirement` enforced on both ends. |
| `DisplayHostTCP` | TCP, for a host on another machine or in a VM. Both ends prove they hold a `DisplayHostSecret` before any message passes. Unencrypted: for a network only the two ends share, or a tunnel. |
| `InMemoryDisplayHostConnection` | Both ends in one process, for tests and for putting an in-process target behind the protocol. |

Any transport works if it implements `DisplayHostConnection` and keeps message boundaries; it says whether both ends share a filesystem with `sharesFilesystem`. A VM transport over vsock or TCP is one example. A host that wants a HUD wraps its target in a decorator, or calls the HUD from its stop handling.

**Live view through a host.** Pass a `DisplayLiveViewServer` as `liveView` to `RemoteDisplayTarget.connect(using:…)` or `connect(over:…)`, and the harness serves the view from the host's frames, through the same links, REST routes, and terminal controls as any other target:

```swift
let remote = try await RemoteDisplayTarget.connect(using: connector, liveView: liveView)
```

- **Which hosts.** The host's target must declare `observerAccess: stream` and give out frames from `liveFrame`, as `MacHostDisplayTarget` does with `liveFrames` set. For any other host, live-view calls go to the host as before.
- **Frames and input.** Each lease gets its own feed. Frames are pulled every `liveViewFrameInterval` (500 ms by default) only while someone watches. A viewer's input reaches the host only during takeover, and what the user types through the view is reported as `typedDuringTakeover`, so it is redacted from helper models.
- **Reconnects.** A viewer stays connected while the client takes its lease back. A lost lease, a release, or a final drop closes the view.
- **Observers.** A host whose manifest says `humanPresence: shared` gets no observers unless `maxObserversPerSharedFeed` allows them.

Without a `liveView` server, a hosted target's `liveView` link passes through as the target returns it, so the host process serves its own live view (a `DisplayLiveViewServer` there, say), and making it reachable from the harness's users is up to you.

## Writing a display target

Conform to `DisplayTarget` and declare a `DisplayTargetManifest`:

```swift
DisplayTargetManifest(
    id: "macos-host", label: "This Mac", platform: "macos",
    isolation: .host,                        // host | process | container | vm | remote-browser | remote-device
    perception: [.pixels, .accessibility, .ocr],
    delivery: [.background, .foreground],
    semanticActions: [.press, .setValue, .menuPath, .launchApp, .openURL],
    requires: [.screenCapture, .accessibility, .postEvents],
    humanPresence: .shared                   // shared | exclusive
)
```

The driver's obligations:

- **Single controller.** Hold leases with `DisplayTargetLeaseLock`, which returns `targetBusy` while a live holder has the target and reclaims it from a dead one.
- **An id of its own.** `DisplayTargetRegistry` refuses an id a sandbox backend or another target already has: display targets and sandbox backends share one id namespace.
- **A live view from frames.** A target whose screen is reached only through it, such as a guest or a host, can serve a live view with `DisplayLiveViewRelay`: open a feed per lease with a `Source` (frames, input, typed values), call `setControl` on takeover, and `close` at release. Mark the feed `isShared` for someone's own screen.
- **Events.** A target that learns something the session should hear (its stop key, a permission change, a takeover the user started at the target, the user typing on a shared desktop) returns it from `events(_:)`, for example through a `DisplayTargetEventHub`. The stream ends at release.
- **`release` always restores UI state** and is idempotent.
- **Every `DisplayObservation` has its own id, timestamps, and target identity.** Image geometry is recorded in `ScreenshotGeometry`, and the process start time is pinned alongside the pid.
- **`act` re-resolves cited elements and refuses on drift.** It reports evidence (`confirmed | unverifiable | suspected-noop | partial | refused | not-executed`) and stops at the first failure.
- **Release modifiers and buttons in `defer`.**
- **Mark page content.** A browser's page elements set `ElementRef.isWebContent` and carry the page's `url`, and the observation reports the page's `url` and its viewport as `pageBounds`. Page content is gated by its domain grant, and page content with no URL is refused as unresolvable, since there is no domain to check. Leaving the flag off would gate the page by the browser's app grant instead.
- **Window lists.** `describe()` returns a `TargetLayout` whose `windows` lists granted apps' windows, or is `nil` when the target can't list windows, which isn't the same as listing none. The session evaluates `wait-for` conditions itself from fresh observations and window lists, so a driver needn't implement them; one sent `wait-for` directly waits briefly and reports `unverifiable`.

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
| Browsers | Capped at `click`. The browser's own controls (launching it, opening URLs, switching tabs) follow the app grant up to `click`; typing, keys, and menus in them stay refused, pointing to a page element or `open-url`, and so is typing with no cited element. Actions on a page follow the page's domain grant, and a page whose address the browser doesn't report is refused as unresolvable. On a desktop target `open-url` needs a browser granted at `click` or above to open the page in (the default one if it's granted). The grant dialog warns that a browser's observations show whatever page its windows display, on any domain: domain grants limit where it can act, not what it can see |
| Finder, System Settings, Shortcuts | Grantable, with a blast-radius warning |

`ComputerUseGrantReviewer.clamp` keeps an approver from raising a tier above its cap or adding grants and flags that weren't requested. Category rules are applied again at action time, because the category is known only once the target reports it.

## How each action is gated

`ComputerUseActionClassifier` works only from data the harness derives itself: the action, the cited element (role, label, app, URL), and the grant.

| Class | Examples | Gate |
|---|---|---|
| observe | observe, zoom, wait, wait-for | allow |
| navigate | scroll, move, launch of a granted app, `open-url` on an http(s) granted domain | allow |
| interact | click, press, type, set-value, key, menu at a sufficient tier; a script at full tier | Allowed when the intent check says consistent. With no checker bound, confirmed on `humanPresence: shared` targets and allowed otherwise. An operator can opt out of that confirmation with `ComputerUseOperatorOverrides.skipInteractConfirmationWithoutIntentCheck`. A mode that requires it confirms every interact action whatever the check says; see [Stricter modes](#stricter-modes). |
| consequential | Typing into secure or payment fields; targets labeled submit, send, buy, delete…; a Return that triggers such a control; destructive shortcuts; System Settings; installers; vendor safety signals; a script on a `humanPresence: shared` target | Always confirmed |
| out of grant | Non-granted app or domain, tier violation, missing flag, non-web `open-url` scheme, an `open-url` whose URL carries a credential, the stop key | Denied, with the reason returned to the model. When a task grant would have allowed it (the page's domain in a browser, otherwise the app at the needed tier and flags), the reason adds that grants can't change during the run and names the grant to delegate again with, and the session records it in `missingGrants` |
| unresolvable | Citing an observation that is no longer retained, an unknown ref, a point outside the observation | Refused with `escalation: observe` |

On-screen labels can only raise the class. They never lower it, and they never reach the intent check.

**Return is classified as the control it triggers.** A Return key, or typed text ending in a newline, while focus is in a single-line field is checked against the tree's `returnTarget`: the focused field's form submit element in a managed browser, or the window's default button on macOS. That control's role and label decide whether the Return is consequential. With no such control it stays interact.

**Untargeted input goes to the working app**: the app of the most recently cited observation, which must be granted at `full`, never the frontmost app just because it is frontmost.

Confirmation:

- **Per action.** Confirmation happens per action, even inside a batch. A refusal stops the batch, and the remaining actions are reported `not-executed`.
- **Routing.** Cards go through `ExecApprovalDelivering` with `allowsDurableBypass: false` and only "Allow this action" and "Deny" buttons.
- **Binding.** The approval is bound to the action's canonical form, with typed text replaced by its SHA-256.
- **Stricter modes.** <a id="stricter-modes"></a>A mode profile can require confirming every interact action with `"subAgents": { "computerUse": { "confirmInteract": true } }`. Neither a consistent intent check, an unshared target, nor the operator's opt-out skips it, and the card gives the mode as the reason. Every mode over the session applies: the delegating conversation's and each conversation's above it, up to the user's root, and any one requiring it is enough. A profile that extends one requiring it can't turn it off. Modes can't loosen computer use: consequential actions are always confirmed. To deny computer use a mode lists `delegate_computer_use` in its tool `deny`, and that denial too reaches every delegate below it, which is refused before any lease. The modes are read again before each action: a change that tightens them applies from the next action and stays for the rest of the session, and a new denial ends the session as `policy-revoked`: an action already running finishes, and the rest of its batch comes back `not-executed`. The result is `blocked` with that reason, and the same denial refuses the parent's next delegate call, so it can't become a retry loop. A change that loosens them waits for the next session.
- **Headless runs.** When no user is present, consequential actions get `headlessDenied` without anyone being asked. They are collected in `session.headlessDenials` so the next interactive attach can show them.

Possibly-delivered actions are never retried automatically:

- A driver error after sending is reported as `unverifiable` with `escalation: observe`.
- The tool result tells the model not to repeat the action.
- After three failing batches in a row, the result escalates to `ask-user`.

**Secrets.** `open-url` refuses a URL that carries a credential, even on a granted domain. That covers user-info before the host, a secret-named query or fragment parameter (`token`, `access_token`, `api_key`, `password`, `sig`, …), or a token-shaped value such as a JWT or a well-known key prefix. Text bound for helper models has secrets redacted: the user request the intent check sees, the `vision-describe` question, the `grounder`'s description, and screen text sent to the injection probe. Besides the patterns, the session knows these values and replaces each one (four characters or longer) wherever it appears:
- values that password and one-time-code fields hold, as observations report them;
- text the agent types or sets into such fields;
- each value the user typed through the live view during a takeover, split at Return, Tab, and the end of the takeover. On the host desktop the user types on the real keyboard, which the harness doesn't read, so those values aren't known.

Typed text never reaches the action log, which records only its hash.

**Vendor safety signals.** A codec passes a vendor's checks to `session.perform(_:safetySignals:)` as `ComputerUseSafetySignal` values, keyed by the action's index in the batch. `ComputerUseSafetySignal(openAISafetyCheckCode:)` reads OpenAI's `pending_safety_checks` codes (`malicious_instructions`, `irrelevant_domain`, `sensitive_domain`, and any other code as `other`), and `ComputerUseSafetySignal(geminiSafetyDecision:)` reads Gemini's `require_confirmation`. Every signal makes its action consequential, so the user is asked, with the signal named on the card; none is acknowledged on the user's behalf.

**Watch mode.** A `sensitive-domain` signal puts the session in watch mode for the rest of its life (a `watch-mode` session event). Before each action from then on, the session checks that a live-view connection is open (`DisplayTarget.liveViewers(_:)`, which counts every viewer, observers included). If none is, it reports `waiting-for-live-view` activity and waits up to `watchModeWait` (2 minutes) for one. The TUI shows the link without being asked. If nobody opens it, or no user is present, the session ends with `live-view-required`, and the specialist returns `needs-user`. On a target without a live view, a present user confirms once on a card instead. So they do on someone's own screen with a live view, such as the user's Mac, when nobody is watching it, since the user may be at the machine: an open view or the user's confirmation both keep the session going there.

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

The shared decider setup is in [Decision models](./DECISION_MODELS.md). A fast decider's robustness to adaptive attacks is unmeasured, so validate it on your own attack set. Consequential actions are confirmed whatever it says.

## Budgets, kill switch, takeover

- **Budgets.** The host sets a `ComputerUseBudgetPolicy`; the parent sizes the work in `steps` and never sets a time budget. The lease carries `ComputerUseBudgets`, the policy combined with the task. A step is an action delivered to the driver, so actions that come back `not-executed` don't count. The lease's `endsAt` is the earliest of the time ceiling (`maxDuration`), the task's `deadline`, and an unattended session's grant expiry, measured from when the lease is issued. Before every action the session checks, in order:
  - **No progress.** `noProgressSteps` consecutive steps without progress end the session with `no-progress`, whatever allotment remains. Counting steps, not seconds, behaves the same on a fast model and a slow one. Refused actions aren't steps, but they count toward the window too, and the session ends on the refusal that fills it; refusals while the user has taken over don't count.
  - **End time.** A passed `deadline` ends it with `deadline`, and a passed grant expiry with `time-budget`; neither is ever moved. At the time ceiling a present user decides on a continue-or-stop card, and a yes moves the ceiling out from its current value by `extensionShare` of `maxDuration`, never past the deadline or the grant expiry. A card that times out stops, and so does a missing user: the session ends with `time-budget`.
  - **Steps.** When the allotment is used up and the session made progress since the last grant, it grows by `extensionShare` of the first allotment, rounded up, up to `ceilingSteps`. Without progress it ends with `step-budget`. At the ceiling a present user decides on a card, and each yes grants one more extension; without a user, with a no, or with no answer, it ends with `step-budget`. Extensions below the ceiling aren't approved one by one.

  Exceeding `maxUSD` (fed by `session.recordCost(usd:)`) ends it with `cost-budget`; cost is never extended. `session.budgets`, `endsAt`, and `extensions` show the current state, and `terminalDetail` says what ran out. The ceiling card goes through `ComputerUseOversight.continuePastCeiling(_:)`. Permissions are checked before every batch, and a revoked one ends the session with `permission-revoked`; so does a target's `permissionsChanged` event.
- **Repeated failure.** After three failing batches in a row the result escalates to `ask-user`, once. The user's answer resets the count; failing again before any progress ends the session with `no-progress`.
- **Kill switch.** `HarnessRuntimeSession.stopComputerUse()` stops every live specialist session, and `POST /api/conversations/{id}/computer-use/stop` stops one conversation's (`ComputerUseSession.stop()` for one you drive yourself). Stopping withdraws the approval cards the session waits on and declines its open questions and handoffs. A target's own stop key arrives as a `stopRequested` event and does the same. The stop key (⌃⌥⌘. by default; set it with `ComputerUseActionClassifier(stopKey:)`) is never synthesized, in any spelling, while a session is active.
- **Takeover.** `session.handoff(reason:prompt:)` turns takeover on, waits for `ComputerUseOversight.handoff` to return, then turns it off, however the handoff ended, including when its caller was cancelled. Turning takeover off and releasing the lease at the end run in a task of their own, because a remote target drops requests made from a cancelled task. The user can also take over at any time with `POST …/computer-use/takeover`, or at a target that reports `takeoverChanged`. While takeover is on, observe and act are refused. Ask-user and handoff are unavailable when no user is present.
- **The user typing.** On a shared desktop the target reports the user's keystrokes (`userTyping`), and the agent's next input waits until two seconds pass without one (`not-executed`, no step, with an observe escalation). Observing still works.
- **Progress.** `session.progress` records what the harness counts as progress, decided only from facts it recorded, never from the model's claims or screen text. A criterion verified as met for the first time is progress. So is a state not seen before, when it is first observed after an acting step whose effect wasn't `refused`, `suspected-noop`, or `not-executed`. Observing, zooming, and waiting never earn progress, so a page that changes on its own doesn't count, and nothing the user does during takeover is credited to the agent. A state is a `ComputerUseStateDigest`: a SHA-256 of the observation's app (on the host desktop, the working app rather than the frontmost), window, URL without its fragment, the focused element's role, and the tree's shape (each element's role and depth). Text and values are left out. On screenshot-only observations the digest covers app, window, and URL. Returning to a state already seen never counts, which catches oscillation. Each action-log record says whether that step made progress (`madeProgress`).
- **Verification.** `session.verify(...)` accepts only an observation taken after the last action.

## Oversight surfaces

A specialist runs in a child conversation the user never opens, so everything that needs the user goes to the parent conversation, the one that called `delegate_computer_use`:

- **Where they go.** Cards, questions, handoffs, and activity go to the root of the delegation tree: the user's conversation. A nested specialist's requests carry its path, as `delegatePath` on surface intents and "Asked by" on cards.
- **Approval cards.** Consequential actions are confirmed through the user's conversation's approval delivery, the same `ExecApprovalDelivering` cards exec approvals use; despite its name it is the harness's general approval delivery. Set `ComputerUseConfiguration.approvals` to replace it. Each card lists the action, the target element, why it needs confirming, the intent-check verdict, and a vendor's stated intent, labeled as the model's unverified claim. When the cited observation has pixels, an `image` block shows a crop of the target region (the element's padded frame, or a box around a point, at most 480 px). The block is `{ "type": "image", "ref", "alt", "mime" }`: a specialist's card stores the crop as a blob and cites it by blob id, which surfaces fetch from `GET /api/conversations/{id}/blobs/{blobID}`; without a blob store, as for a session a host drives by hand, the ref is a `data:` URL. Its `alt` restates the action in words (`Click "Pay now" in com.apple.Safari, checkout.example.com`). Surfaces that can't show images get the alt text; the terminal shows it with the image's size.
- **Questions and handoffs.** `computer_ask_user` and `computer_handoff` publish a `computerUseRequest` surface intent on `conversation/{id}/events` and block the specialist until a client answers. When the request is resolved, times out, or the run is cancelled, a `computerUseRequestCleared` intent follows. A question that times out (10 minutes) or a handoff (15 minutes) ends the session with `needs-user`, carrying it for the parent. Set `ComputerUseConfiguration.oversight` to answer in-process instead.
- **Activity.** Every action batch, takeover change, and session end publishes a `computerUseActivity` intent with the target, step, current allotment (`maxSteps`), `extensions`, app, action, terminal reason, `liveView` (whether the target serves a live view), and `sharedScreen` (whether the target is someone's own screen, such as their Mac, so a handoff can be done at the machine as well as through the view). The macOS HUD shows it as "Step 34 of 45, extended twice". This feeds the "agent is using <target>" indicator.

All three use the `surfaceIntent` semantic kind. The payload is the `computerUse` object in [`client-surface-intent-wire.schema.json`](../openapi/schemas/ws/client-surface-intent-wire.schema.json).

Clients answer and steer through REST. Each route checks conversation tenancy:

| Route | Does |
|---|---|
| `GET /api/conversations/{id}/computer-use` | Lists pending requests and live sessions (`lifecycleID`, target, step, `maxSteps`, `takenOver`, `liveView`: whether the target serves one, and `sharedScreen`) |
| `POST /api/conversations/{id}/computer-use/runs/{lifecycleID}/live-view` | Mints a live-view link (`url`, `viewOnly`, `expiresAt`, `role`), sent `no-store`. An optional body `{"role": "observer"}` mints an observer link; the default is the user's. 404 when no live run matches or its target serves no live view. |
| `DELETE /api/conversations/{id}/computer-use/runs/{lifecycleID}/live-view/observers` | Ends the run's observers and revokes its observer links (204). 404 when no live run matches. |
| `GET /api/conversations/{id}/computer-use/runs/{lifecycleID}/live-view/connections` | The connected viewers: each link's `id`, `role`, and `connectedAt` |
| `DELETE /api/conversations/{id}/computer-use/runs/{lifecycleID}/live-view/connections/{linkID}` | Ends that one connection, or revokes the link if unused (204). 404 when there is no such link. |
| `GET /api/conversations/{id}/blobs/{blobID}` | Any blob the conversation references: an attachment, a message image, or an image a live run's approval card cites. Any other blob is a 404, even when it exists. The `ETag` is the blob id, and responses are private and immutable. |
| `POST /api/conversations/{id}/computer-use/requests/{requestID}` | `{"action": "answer", "answer": "…"}`, `{"action": "hand-back", "note": "…"}` or `{"action": "decline"}`. A question takes answer or decline; a handoff takes hand-back or decline (otherwise 409). |
| `POST /api/conversations/{id}/computer-use/stop` | Stops the conversation's sessions, declines their pending requests, and returns `lifecycleIDs` |
| `POST /api/conversations/{id}/computer-use/takeover` | `{"on": true}`, optionally with `lifecycleID`. Returns `lifecycleIDs`, or 404 when nothing is running. |

The terminal surface renders all of this: an indicator line with the target, step, app, and last action; a dialog with a text field for a question; *Hand back control* and *Decline* for a handoff; **Ctrl-T** to take over or hand back, **Ctrl-X** to stop, **Ctrl-O** for a live-view link (shown under the indicator, and minted on its own at takeover), and **Ctrl-G** to share a view-only link with someone else or stop sharing. Pass `HarnessRuntimeSession.computerUseControl` to `RuntimeTUIHost(computerUse:)`. Surfaces that render it declare `SurfaceCapabilities.computerUse` (the terminal does; channels don't). Intents are published whether or not such a surface is attached.

### Replays

When a specialist run ends, the harness stores a replay as session blobs: the full action log, the session events (each extension with the progress that justified it, each ceiling question and its answer, and how the session ended), and a thumbnail of each observation that had pixels. A thumbnail is at most 320 px on its long edge, a session keeps up to 120 (the first and the newest), and typed text appears only as its hash. The delegate result's `actionsLog` ends with the replay document's ref. Surfaces read replays through REST:

| Route | Returns |
|---|---|
| `GET /api/conversations/{id}/computer-use/replays` | The conversation's recent replays, newest first |
| `GET …/computer-use/replays/{lifecycleID}` | One replay: records and thumbnail rows |
| `GET …/computer-use/replays/{lifecycleID}/thumbnails/{observationID}` | The thumbnail image, only for an observation that replay lists |

The index keeps 50 replays per conversation in memory. After a restart it rebuilds a conversation's list the first time it's asked for, from the replay documents its delegate results name.

A replay is a record for review. Re-executing its actions is a different feature and isn't offered.

### Image retention

A run's images are its screenshots (offloaded from the specialist's tool results), its approval-card crops, its replay thumbnails, and its replay document. They live in the ephemeral lane. Each holder has its own reference with its own expiry, and a blob's expiry in the store is the latest of its references, so a change to one holder never shortens another's:
- **The session.** While the lease is active, its reference expires `afterRelease` past the lease's hard limit (its current end time plus the cleanup grace), and it moves whenever a present user moves the time ceiling. So a crash before release still leaves images that expire.
- **The replay.** At release the session's reference is reset, and the replay's added, to release time plus `ComputerUseRetention.afterRelease` (24 hours by default).
- **An audit mark** adds its own reference for `ComputerUseRetention.audit` from release (30 days by default, a fixed length). Removing the mark drops that reference and leaves the others.

Expired blobs are swept at release.

| Route | Does |
|---|---|
| `POST /api/conversations/{id}/computer-use/runs/{lifecycleID}/audit` | `{"marked": true}` or `false`. A live run takes the mark at release. On a released run the audit reference is added or dropped right away. |

Replay listings show `auditMarked` and `expiresAt`, and an expired replay drops out of them.

**After a restart.** References live in memory, so a run's blobs keep the expiry last written to the store. A released run's audit mark is read back from its replay document's expiry. A mark placed on a live run that the server lost before release is lost too, and that run's images keep the normal expiry.

## The tool family

The tools are `computer_observe`, `computer_click`, `computer_type`, `computer_key`, `computer_scroll`, `computer_press`, `computer_set_value`, `computer_menu`, `computer_launch`, `computer_open_url`, `computer_run_script` (on targets whose manifest declares `scripting`, which today means browser targets), `computer_zoom`, `computer_wait_for`, `computer_verify`, `computer_ask_user`, `computer_handoff`, `computer_scratchpad` and `computer_finish`, plus `computer_describe` for a specialist that can't see images and `computer_locate` when the `grounder` role is bound.

- Each tool has one flat schema with primitive parameters only.
- Pointer tools take a `ref`, or `x`/`y` in the session's coordinate mode, plus the `observation` the action cites. Arguments outside a tool's schema are refused.
- `computer_observe` takes `tab` on browser targets: a tab id from the observation's tab list, which becomes the active tab.
- `computer_wait_for` takes a structured condition, never natural language: `kind` is `element-appears`, `element-disappears` (by `role`, `name`, or `ref`), `url-matches` (`pattern`, where `*` matches anything and a pattern without one matches as a substring), `window-appears`, `window-disappears` (`app`, a bundle id, and optionally `window_id`), `value-equals`, `value-contains` (`ref`, `text`), or `screen-settles` (`quiet_ms`). The session evaluates it on fresh observations of any target, keeps only the last, and comes back `partial` on a timeout. Window conditions are checked against the target's window list from `describe()` rather than observations, by app and window id only, since titles are screen content an attacker controls, and an app outside the grant is refused. The macOS host lists granted apps' windows; other targets list none. A condition the target can't show, such as a window on a target that lists none or a page URL outside a browser, is a bounded wait followed by an observation, and the evidence says so.
- Refs are stable for the session. Drivers number elements per traversal, so the session matches each tree to the previous one by role, subrole, label, and nearest frame. A matched element keeps its ref, a new element gets a ref no element has had before, and actions are translated back to the driver's refs. A ref is still cited with an observation, and the target still checks it against that observation.
- `computer_observe` with `diff_against` returns the tree as a diff: added (`+`), changed (`~`), and removed (`-`) elements, with unchanged ones only counted. Unchanged elements keep their refs and can be cited with the new observation. The full tree comes back, with a note, when the base observation is no longer retained, when more than half the lines changed, or when the window or page changed.
- The codec maps coordinates through that observation's recorded geometry, so the model never sees a scale factor.
- **Labeled screenshots.** When an observation has both a tree and a screenshot, the screenshot the model gets has actionable elements' refs drawn as red tags at their top-left corners, with a thin outline around each element, and the result says so. Containers (elements over a quarter of the screen), elements too small to see, and elements off the screenshot get no tag. The focused element is tagged first, then those nearest the last action, and a tag that would cover one already drawn is left out; at most 40 are drawn. The labeled copy keeps the screenshot's size and format, so coordinates map back the same way, and only the model sees it: the observation, replays, and approval-card crops keep the raw pixels. `ComputerUseSessionConfiguration.labelsScreenshots` turns it off. Screenshot-only observations, including the native toolsets', go unlabeled, and so does every screenshot on platforms without ImageIO and CoreText.
- `computer_finish(result, keep_files)` is how the specialist ends, and its one commit. It carries the `halts-loop` policy tag, so the tool, not the runtime, declares that it ends the loop. `keep_files` is an array of paths relative to the download folder; an absolute path, one that leaves the folder, or one naming no download is a problem, and so is a result that misses the return schema. A first call with problems is rejected with them. Its result echoes only the specialist's own paths and result, since download names come from the page.
- `computer_scratchpad` replaces the specialist's notes, up to 2,000 characters, and blank notes clear them. The notes come back in every task reminder, so values read off an early screen outlive pruned screenshots and compaction. Taking notes isn't an action: it takes no step and earns no progress.
- `computer_describe` takes a fresh screenshot and asks the `vision-describe` model a question about it. The answer is text with no coordinates, citing that observation, so the specialist can verify against it and act through refs.
- `computer_locate` takes a fresh observation and asks the `grounder` model where a described element is. It returns the point in the specialist's own coordinates, citing that observation, and names the smallest tree element under it. Only numbers are read from the grounder's answer, and the click it leads to is gated like any other.
- Both send the helper model the screenshot and the specialist's words with secrets redacted, and each counts as an observation step.
- Results from the screen-bearing tools keep harness lines (the outcome, guidance, the task reminder, the observation header) outside the untrusted-content envelope and put screen-derived text (the tree or diff, a driver's evidence, a described answer) inside it, with the `screen` source label. The tools envelope their own text, so the result middleware doesn't wrap them again; the injection probe still reads them. `computer_verify`, `computer_ask_user`, `computer_handoff`, `computer_scratchpad` and `computer_finish` return harness or user text and are exempt.

### Anthropic's native toolset

A specialist bound to a Claude model reached over Anthropic's own API uses Anthropic's computer tools instead of the `computer_*` family. Claude is trained on them. The catalog's `computer-use` feature `version` picks the dialect:

| Version | Wire | Models |
|---|---|---|
| `computer_toolset_20260801` | Seventeen member tools (`screenshot`, `left_click`, `type`, `key`, `scroll`, `zoom`, …), no beta header | Opus 4.8 and the Claude 5 family |
| `computer_20251124` | One `computer` tool with an `action` field, beta `computer-use-2025-11-24` | Opus 4.6 and 4.7, Sonnet 4.6 |
| `computer_20250124` | The same without zoom, beta `computer-use-2025-01-24` | Haiku 4.5 |

- **Same gates.** Each member call becomes a canonical action and runs through the session like any other: grants, classification, the intent check, confirmation, budgets, and replay. Coordinates are pixels of the latest screenshot and map through its recorded geometry.
- **Pixels only.** A native `screenshot` result carries the image and a header line (observation id, app, size), not the accessibility tree, and the members take no refs. `cursor_position` reports where the session's last pointer action left the pointer. Modifiers go in a member's `text` field; holding one alone (`hold_key` with `shift`) is refused. X11 key names map to the harness's: `Delete` is forward delete and `BackSpace` is delete.
- **Kept alongside.** The session still offers `computer_verify`, `computer_ask_user`, `computer_handoff`, `computer_scratchpad`, `computer_finish`, `computer_launch`, `computer_open_url`, and `computer_run_script` where the target runs scripts, and `computer_describe` and `computer_locate` when their roles are bound. Verification and the user stay first-class, and launching or opening a URL is cheaper than clicking.
- **The codec.** `AnthropicLLM` replaces the member tool definitions with Anthropic's declaration, sends the beta header for the older versions, echoes `toolset_name: "computer"` on member calls and results, and marks halted results `is_error`. The older versions declare the screen size a display screenshot comes out as.
- **Batches.** Claude can send several actions in one turn. They run in order, and after the first failure the rest are answered with Anthropic's halt text without running. Tools tagged `halts-batch-on-failure` are never dispatched in parallel.
- **Elsewhere.** Every other model, and Claude through an OpenAI-compatible route such as OpenRouter, keeps the `computer_*` tools.

### OpenAI's and Gemini's native tools

The same mechanism serves the other two vendors with computer-use toolsets. The catalog `version` picks the dialect, only on that vendor's own API, and the feature's `api` names the vendor API the toolset needs, which the provider codec sends the session's requests to:

| Version | Vendor and API | Wire | Coordinates |
|---|---|---|---|
| `computer` | OpenAI, Responses API (`OpenAILLM`) | One `computer` tool. A `computer_call` carries a batch of `actions[]` and its `pending_safety_checks`; its result is a `computer_call_output` with the screenshot after the batch | Screenshot pixels |
| `computer_use` | Gemini, Interactions API (`GeminiLLM`) | Predefined functions (`click`, `type`, `scroll`, `navigate`, …), one action per call; each result is the page URL as JSON plus the screenshot after it | The 0–999 grid |

- **Same gates.** Each action becomes a canonical action the session gates like any other. A batch from OpenAI runs in order and stops at the first refusal; Gemini's parallel calls halt the same way as Anthropic's.
- **Safety signals.** OpenAI's pending checks and Gemini's `require_confirmation` decisions become `ComputerUseSafetySignal` values on the call's first action, so the user is asked before anything runs, with the signal named on the card. The codec acknowledges them (`acknowledged_safety_checks`, `safety_acknowledgement: true`) only when that action ran, which happens only after the user said yes. A declined call still returns its screenshot, without the acknowledgement. A call that carries a signal but no action is still asked: an empty wait carries the question.
- **Environment.** Gemini's `environment` follows the target: `browser` for a browser target, `mobile` for a phone, `desktop` otherwise. Functions with no canonical action (`key_down`, `key_up`, `go_back`, `go_forward`, `long_press`, `list_apps`) and those the environment's targets can't carry out are listed in `excluded_predefined_functions`.
- **Requests.** `OpenAILLM` sends a session whose feature names the `responses` API to `/responses`, and `GeminiLLM` speaks only the Interactions API. Neither streams: the whole response arrives as one completion.
- **Turns.** Both APIs continue a turn from the stored response (`previous_response_id`, `previous_interaction_id`), because their calls depend on reasoning state the client never sees. The response id rides on each tool-call id as `<call id>@<response id>` (`ChainedProviderCall`), so a turn continues after a restart. Only what came after the latest assistant turn is sent, with the system prompt and tools each time. A request with nothing to continue from sends the conversation as plain content.
- **Retention.** The vendor then keeps every screenshot it was sent: harness-side pruning bounds what is resent, not what the vendor stores. The feature records this as `dataRetention: "vendor-stored"` (the default on these two APIs), and a host that sets `requiresZeroRetention` refuses such a binding before leasing, with the reason. There is no stateless mode for these APIs, so a host that needs zero retention binds a model whose calls aren't stored.
- **Function outputs.** On the Responses API a function tool's images go in its own `function_call_output`, as `input_image` parts next to its text.
- **Coordinates.** Gemini sessions use the 0–999 grid whatever the catalog says, frozen with the session like any coordinate mode.
- **Kept alongside.** The session offers the same companion tools as with Anthropic's toolset, as function tools next to the vendor's.
- **Elsewhere.** Every other route, including OpenAI's models on chat completions without a computer-use session, is unchanged.

## Screenshots in tool results

`computer_observe` and `computer_zoom` return the screenshot as an image part (SwiftAgentKit `ToolResultImage`) next to the text, at exactly the size recorded in its `ScreenshotGeometry`. Drivers fill `ObservationImage.data` with the encoded image as sized for the model.

- **Never resized after capture.** Screen tools carry the `geometry-bound-images` policy tag. The tool-result formatting stack keeps their images untouched. If one exceeds the bound model's edge cap (or `maxInlineImagePixelDimension` when the model declares none) or `maxInlineImageBytes`, it is replaced by a marker telling the model to observe again, because a resized screenshot would misplace every click. Configure the session from the bound model (below) so screenshots are captured at the right size.
- **Vision gating.** As with inline data URLs, a conversation whose model lacks vision gets a text marker instead of the image, and compaction always replaces images with the compaction marker.
- **On the wire.** Anthropic gets image blocks inside the `tool_result`, Gemini inside the `function_result`, and OpenAI's Responses API inside the `function_call_output`. OpenAI chat-completions and LM Studio tool messages carry text only, so each such result says its image follows (`[an image from this result follows in the next message]`), and the images from a run of tool messages travel in one user message right after the run, naming the tool calls they belong to. Ollama already attaches images to tool messages.
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
    "pruneEvery": 15,
    "api": "responses",              // the vendor API the toolset runs on; defaults per vendor
    "dataRetention": "vendor-stored" // or "none"; vendor-stored by default on the stored-response APIs
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

The pipeline's own cap, `maxInlineImagePixelDimension`, is 1,200 px by default, and capture is sized to the tighter of it and the model's caps. Raise it to use a model's full limit.

**Values for Claude models.** The bundled Claude entries declare Anthropic's documented values. A host catalog that lists other Claude models should declare:

| Models | `version` | Image limits |
|---|---|---|
| Haiku 4.5 | `computer_20250124` | 1,568 px, about 1.15 MP |
| Opus 4.6, Sonnet 4.6 | `computer_20251124` | 1,568 px, about 1.15 MP |
| Opus 4.7 | `computer_20251124` | 2,576 px, 4,784 visual tokens, about 3.75 MP |
| Opus 4.8 and the Claude 5 family | `computer_toolset_20260801` | 2,576 px, 4,784 visual tokens, about 3.75 MP |

All of them take screenshot-pixel coordinates.

**Retention.** `ContextScreenshotRetention` runs at projection time; the transcript keeps every screenshot.

- **What counts.** Screenshots are counted across the loop, not by user turns, so pruning fires inside one long run.
- **What's kept.** The newest `keepRecent` (3) stay in full.
- **What's pruned.** Older ones are pruned in whole batches of `pruneBatch` (15), each replaced by a marker the harness writes from the receipt, with no model call: `[screenshot o_7 pruned: com.apple.TextEdit "w1", step 12]`. The tree text stays.
- **Why batches.** Between batches the projected prefix is byte-identical, so the prompt cache holds, and it changes once per batch.
- **Request size.** The defaults keep at most 17 screenshots in any request, under the ~20-image cap where at least one vendor lowers its per-image limit: the image cap wins over older "prune every ~25" guidance.
- **Configuration.** A model's feature can override both values. `ContextEngineProjectionPolicyInput.screenshotRetentionPolicy = nil` turns pruning off.
