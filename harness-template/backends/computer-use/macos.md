# Computer Use on macOS — Host Desktop and VM Targets

> Sibling page of [computer-use/README.md](./README.md). The README defines the platform-neutral contract: display targets, the canonical action model, observation receipts, grants, layered safety, and screenshot budgets. This page specifies how to implement the **host-desktop** and **macOS-VM** display targets on macOS: which system APIs to use, how permissions actually work, how to avoid stealing the user's cursor, and how to structure the code. Swift sketches are illustrative and have not been compiled.

## TL;DR

On macOS, the hard part of computer use is **permissions and process identity**, not capture or input. Capture is ScreenCaptureKit. Perception is ScreenCaptureKit plus the Accessibility (AX) API, with Vision OCR as a fallback. Action prefers AX semantic actions, then events routed to a specific process, and only then global events in the foreground. All of it is gated by TCC (Transparency, Consent and Control) permissions, which macOS attributes to the **responsible process**. A command-line harness launched from a terminal silently borrows the terminal's grants. The robust desktop drivers studied therefore put a small signed app in charge of the grants and have clients talk to it. Borrowing the terminal's grants is workable only for developer tools.

The prescriptive shape:

1. **A signed, notarized host app owns every grant.** A menu-bar `LSUIElement` agent holds Screen Recording, Accessibility, and Post Event permissions, performs all capture, AX, and input work, and serves the harness over XPC or a peer-signature-checked socket. The harness library never links these frameworks. It receives the computer-use tool provider from the host.
2. **ScreenCaptureKit only.** `CGWindowListCreateImage` is obsoleted in the macOS 15 SDK and misbehaves on macOS 27. Capture per window where possible, exclude the harness's own windows, and downscale on the GPU to the model's size.
3. **AX first, bounded.** Batched attribute reads, global and per-element messaging timeouts, a traversal deadline, and node budgets, returning partial trees. Run on a dedicated thread, never the cooperative pool. Expose `Sendable` snapshots and opaque element ids.
4. **Background-first delivery.** The ladder is AX action → events posted to the target pid → foreground global events with explicit consent and restore. Every result reports evidence. Possibly-delivered actions are never retried.
5. **One coordinate space.** CoreGraphics global, top-left origin, in **points**. Convert Cocoa's bottom-left rects once at the boundary, and map model pixels through recorded screenshot geometry.
6. **A permission broker with honest onboarding.** Preflight each permission separately. Expect a restart after granting Screen Recording and the system's periodic re-confirmation prompt. On macOS 27, managed fleets can no longer silently pre-grant Accessibility.
7. **Isolation by VM when the task doesn't need the user's apps.** Virtualization.framework runs at most two macOS guests per Mac. Run the same host app *inside* the guest and keep VNC for human observers.

---

## Platform status (October 2026)

- **A macOS 15+ deployment target spans three releases:** 15 (Sequoia), 26 (Tahoe), and 27 (Golden Gate, shipped 2026-09-14, Apple silicon only). Several behaviors below differ across them. Gate on version at runtime rather than assuming the newest.
- **Changes in 27 that matter here:**
  - MDM Privacy Preferences (PPPC) profiles can no longer grant Accessibility. The capability was deprecated in 26.2 and removed in 27.0. The replacement declarative setting is consent-based, so even managed Macs show the user a prompt.
  - Apps can no longer read the TCC database directly. Use the preflight APIs; there was never a supported alternative.
  - `CGWindowListCreateImage` has been reported returning gray images.
  - Window owner names are no longer gated behind Screen Recording, so their absence was never a valid permission probe.
  - LaunchAgent plists carrying the quarantine attribute no longer load.
  - Settings pane titles have reportedly changed. Do not hard-code pane names in onboarding copy; deep-link to the panes instead.
- **There is still no public system API for third-party agents to invoke other apps' App Intents directly.** Early MCP plumbing appeared in 26.1 betas but has not shipped as a system-wide agent API. The supported route to App Intents is the Shortcuts CLI (below).

---

## Recommendation

### Process architecture: a host app owns the grants

**The responsible-process problem.** TCC attributes a request to the responsible process, which is usually the GUI app at the top of the launch chain:

- A Swift CLI run from Terminal or iTerm borrows that terminal's grants. The user approves "Terminal can record your screen," which then applies to every program run from that terminal.
- Unbundled executables have failed to appear in the Settings permission lists on some 26.x builds (acknowledged as a bug).
- Re-signing a binary with a different identity, or moving it (package-manager upgrades), orphans its grants.

**The recommended pattern** (the one the robust drivers studied converge on):

```
┌───────────────────────────────┐   XPC (SMAppService.agent Mach service)   ┌──────────────────────────────┐
│ Harness (CLI / server / app)  │ ─── or Unix socket + peer code-signature ─▶│ ComputerUseHost.app          │
│  • Tool System, policy, model │      check (team id + designated req.)     │  LSUIElement, Developer ID,  │
│  • DisplayTarget client       │ ◀── Observations / ActionOutcomes ───────── │  notarized, hardened runtime │
└───────────────────────────────┘                                            │  • owns TCC grants           │
                                                                             │  • capture, AX, input, apps  │
                                                                             │  • onboarding checklist      │
                                                                             │  • "agent active" HUD, stop  │
                                                                             └──────────────────────────────┘
```

- **Launch the host through LaunchServices** (`SMAppService`, `NSWorkspace`, or `open -g`) so it is its own responsible process. Never have the host spawn the harness, or the harness inherits responsibility and attribution gets confusing.
- **The host authenticates its clients.** Check the peer's code signature (team identifier plus designated requirement) on every connection. A local socket that accepts any process turns the host's grants into a privilege-escalation path for every program on the machine.
- **The harness library stays framework-free.** It defines the [`DisplayTarget`](./README.md#runtime-contract) protocol and receives an implementation through a host-supplied tool-provider factory. The library builds and tests on any platform. Only the host target links ScreenCaptureKit, ApplicationServices, and AppKit.
- **Keep one owner per capture stack.** Don't let several processes run ScreenCaptureKit captures for the agent at once. The host is the single owner, and clients connect to it.
- **Keep a dev escape hatch.** An in-process dev mode that runs the drivers inside the harness and borrows the terminal's grants is useful for development. Make the host the default and label the escape hatch clearly in onboarding.

### Permissions: map, broker, onboarding

| Capability | TCC service (shown in Settings as) | Preflight | Request | App Sandbox compatible |
|---|---|---|---|---|
| ScreenCaptureKit capture, shareable-content enumeration | Screen Recording ("Screen & System Audio Recording") | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` | yes (inferred from sandboxed capture apps) |
| System content picker (user chooses each time) | none | — | user picks | yes |
| AX read and act on other apps | Accessibility | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions(prompt: true)` | **no** |
| `CGEvent.post` / `postToPid` | Post Event (listed under Accessibility) | `CGPreflightPostEventAccess()` | `CGRequestPostEventAccess()` | yes |
| Listen-only event tap (stop hotkey) | Input Monitoring | `CGPreflightListenEventAccess()` | `CGRequestListenEventAccess()` | yes |
| Apple Events to app X | Automation (per target app) | `AEDeterminePermissionToAutomateTarget(…, false)` | same with `true` | likely, with scripting-target or exception entitlements (unverified) |

Rules:

- **Post Event and Accessibility are separate services** even though Settings lists both under Accessibility. Event posting alone works in a sandboxed app. AX inspection of other apps does not. The App Sandbox blocks the Accessibility APIs, so **an AX-based computer-use host cannot ship on the Mac App Store.** Distribute with Developer ID and notarization, unsandboxed, with hardened runtime. Add `com.apple.security.automation.apple-events` and `NSAppleEventsUsageDescription` only if you send Apple Events.
- **Preflight, never infer.** Blank images, nil window names, and failed calls are not permission signals. Capture from a launchd or SSH context can "succeed" while returning wallpaper. Poll the broker before each action batch, because users revoke grants mid-session.
- **Onboarding is a checklist the host owns.** Show the grant state of each service, deep-link to the right pane, explain what each enables, and **offer a relaunch after Screen Recording is granted**, since the grant usually takes effect only for a new process.
- **Set expectations about re-prompts.** Since macOS 15 the system periodically re-asks users to confirm screen access for apps that bypass the private window picker (monthly, less often for frequently used apps). The only exemption entitlement is reserved for VNC-style apps, and an agent harness should not expect it. Explain the prompt in onboarding so users don't read it as an attack.
- **Managed fleets.** PPPC can let standard users approve Screen Recording but cannot silently grant it. On 27 it cannot grant Accessibility at all. Whether Post Event pre-grants still work on 27 is unverified. Design onboarding for "a user must click Allow" everywhere.
- **Clipboard reads.** Programmatic pasteboard reads appear to be gated on 15.4+ by a privacy prompt (reported, not confirmed against Apple docs). Either way, make `clipboard-read` an explicit grant flag in the lease (see the README's grant model).

### Perception: ScreenCaptureKit

- **APIs:**
  - `SCShareableContent` enumerates displays, apps, and windows. Cache it with a short TTL and invalidate on app launch and quit notifications; it is the expensive call.
  - `SCContentFilter(desktopIndependentWindow:)` targets one window.
  - `SCContentFilter(display:excludingApplications:exceptingWindows:)` captures a display minus the host and harness apps.
  - `SCScreenshotManager.captureImage(contentFilter:configuration:)` (14+) is the per-step screenshot.
  - `captureImage(in: CGRect)` (15.2+) captures a global rect across displays.
  - `SCScreenshotConfiguration` (26+) adds options such as ignoring UI elements.
- **Screenshot vs. stream.** A turn-based loop takes one screenshot per step, so the screenshot manager is enough. For sub-100 ms "observe after action," keep a long-lived `SCStream` on the target window and take the latest complete frame. Frames carry their own geometry attachments, and `.idle` status means nothing changed, which is a free "no visual change" signal for `suspected-noop`.
- **Points vs. pixels.** `SCStreamConfiguration.width/height` are **pixels**. Display and window frames are **points**. Multiply by the filter's `pointPixelScale` for full resolution. To produce a model-sized image, set `width/height` to the model's target size with `scalesToFit` and `preservesAspectRatio`. The scaling then happens inside the capture pipeline rather than in your process, which avoids a full-resolution CPU copy (measure on your hardware). Keep a separate full-resolution capture path only for `zoom`.
- **Exclude yourself.** Filter out the host's and the harness's bundle ids. Set `NSWindow.sharingType = .none` on the "agent active" HUD and any overlay so they never appear in captures. The model must not read its own transcript, approval prompts, or the user's chat input off the screen.
- **Occluded and off-Space windows.** Per-window capture works for occluded, non-frontmost windows, which is what makes background operation possible. Behavior for minimized windows and windows on other Spaces is not documented. Verify on hardware and degrade to "activate with consent" when capture fails.
- **Encoding.** PNG via ImageIO for UI text sharpness. JPEG at 0.8–0.9 when bandwidth matters. Do not send HEIC.

### Perception: the Accessibility tree

- **Read in bulk.** Use `AXUIElementCopyMultipleAttributeValues` for role, subrole, title, value, description, identifier, position, size, enabled, focused, and children, which is one IPC round trip per node. Frames come from `AXPosition` + `AXSize`, in global top-left points. Do not depend on the undocumented `AXFrame`.
- **Bound everything.**
  - Set a global messaging timeout early (`AXUIElementSetMessagingTimeout(systemWide, ~1s)`) and per-element overrides for known-slow apps.
  - Enforce a traversal deadline checked *between* calls (a timeout cannot interrupt a call already in progress) and node budgets (on the order of a dozen levels, ~1k nodes, a few hundred children per node; tune per app).
  - Return partial trees with a `truncated` reason.
  - Unbounded traversal is the most common way AX-based automation hangs.
- **Threading.** AX calls are synchronous, blocking IPC. Run them on a **dedicated serial thread** (a custom executor, or a `DispatchQueue`-backed actor) with its own run loop for `AXObserver` notifications. Never use the Swift cooperative pool, which it would starve, and never message your own process's AX from the main actor, which can deadlock. `AXUIElement` is not `Sendable`, so keep live elements inside the AX executor and export value snapshots plus opaque ids.
- **Lazy trees.** Chromium and Electron apps build their AX tree on demand. Set `AXManualAccessibility = true` on the app element. Avoid `AXEnhancedUserInterface` except on Chromium browsers when necessary: it changes window-animation behavior and breaks window positioning, so reset it if you also move windows. Canvas apps, games, and WebGL-heavy UIs expose little. For those, merge Vision OCR (`RecognizeTextRequest`, 15+; `RecognizeDocumentsRequest` for tables, 26+) into the element map and fall back to pixels.
- **Compact text for the model.** Prune to elements that are actionable or carry text. Collapse single-child groups. Drop zero-size or offscreen nodes. Truncate long values. Keep frames in a side table, not in the model's text:

  ```
  window "Untitled — TextEdit" app=TextEdit obs=o_7f3c
  [e1] toolbar
    [e2] button "Bold"
    [e3] popup "Font" value="Helvetica"
  [e5] textarea focused value="Hello wor…(1.2k chars)"
  [e6] button "Save" default
  ```

- **Re-resolve before acting.** An element id is valid only with its observation. Before acting, re-read role, title, and frame and compare them to the snapshot. Treat `kAXErrorInvalidUIElement` or drift as `refused` and request a re-observe. Pin process start time as well as pid, because pids are recycled.

### Action: the delivery ladder

| Rung | Mechanism | Steals focus or cursor? | Verifiable? | Fails on |
|---|---|---|---|---|
| 1. Semantic | `AXUIElementPerformAction` (`AXPress`, `AXShowMenu`, `AXConfirm`, `AXIncrement`…), set `AXValue`, set `AXFocused`, menu-bar walk | no | yes (read back) | elements not in the tree, web inputs that ignore AX value writes |
| 2. Process-routed events | `CGEvent.postToPid(pid)` | no | partly (observe) | canvas and game apps, key-window-only fields, minimized windows (Return/Space/Tab don't commit), Chromium web content (pixel right-click arrives as left-click) |
| 3. Foreground | activate the app, `CGEvent.post(tap: .cghidEventTap)`, restore the previous app and cursor | **yes** | partly | nothing, but it interrupts the user |

- **Background-first is the default.** Escalating to rung 3 is a policy event. It requires `delivery: "foreground-allowed"` on the lease, and on a host target with `humanPresence: shared` it is announced in the HUD. After foreground actions, restore the previous app, focus and cursor, but never override something the user changed in the meantime. User input always wins over restoration.
- **Event mechanics:**
  - Use an event source with private state (`CGEventSource(stateID: .privateState)`) so synthetic modifiers don't leak into, or get polluted by, the user's physical keyboard.
  - Double and triple clicks set `mouseEventClickState` to 1, 2, 3 on each down/up pair.
  - Scroll with `scrollWheelEvent2Source` in pixel units.
  - Type with `keyboardSetUnicodeString` in chunks of ≤20 UTF-16 units, split on grapheme boundaries (the per-event limit is reported, not documented, so verify on 26 and 27). Some apps translate from the virtual keycode and ignore the string. Fall back to `set-value`, or to pasteboard + ⌘V with save, verify, and restore.
  - Settle ~50 ms between move and click, and release modifiers and buttons in `defer`.
- **AX results lie in both directions.** `kAXErrorCannotComplete` after `AXPress` can mean success, because the target ran a modal and missed the timeout. Some presses return before the selection actually changes. Report `unverifiable` and observe. Never re-press.
- **Private APIs are optional accelerators.** Private window-server entry points can give more realistic per-process event delivery, and private calls are the only way to enumerate or switch Spaces. These are fine for Developer ID distribution but can break in any release. Load them with `dlsym`, probe at startup, fall back to the public API, and report which path ran in the outcome evidence.

### Structured channels (rungs 1–2 of the control ladder)

- **Apple Events** (AppleScript, JXA, Scripting Bridge) are the most reliable channel for scriptable apps: Finder, Mail, Safari (`do JavaScript`), the iWork apps, Music, Xcode, and many productivity apps. Consent is **per target app**. Probe with `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)`. In unattended contexts the consent prompt times out (~2 minutes) and counts as denial. UI scripting through "System Events" is AX under another name and adds nothing over the native AX path.
- **Shortcuts** reach App Intents: `shortcuts run "Name" -i <input> -o <out>`. Any App Intent the user has wrapped in a Shortcut becomes a structured, GUI-free action. Expose the user's shortcut list as a discoverable catalog, gated by the same grant model. A shortcut that asks for input will pause the CLI, so enforce a timeout.
- **Launching without stealing focus.** `NSWorkspace.openApplication(at:configuration:)` with `activates = false`, `NSWorkspace.open(_:configuration:)` for URLs, or `open -g`.
- **On-device models.** On 27, the Foundation Models framework's on-device model accepts images, has a ~8K context, and ships an OCR tool. It is too small to plan, but fine as a local `vision-describe` offering for cheap, private sub-tasks such as "is this dialog an error?" or "summarize this subtree." It is a `generate` model, so as a `guard` it runs only through decision emulation, flagged `calibrated: false`. It can add caution (route to confirm) but never authorize an action. Gate on OS version and model availability. On 26 it is text-only with a ~4K context.

### Coordinates

- **Canonical space:** CoreGraphics global display space, origin at the top-left of the primary display, y down, in **points**. AX positions, SCK window frames, `CGEvent` locations, and `AXUIElementCopyElementAtPosition` all use it.
- **Cocoa is bottom-left, y up.** Convert once at the host boundary: `cgY = primaryScreenHeight − cocoaY − height`. Secondary displays can have negative origins.
- **Model pixels → points** go through the observation's `ScreenshotGeometry` (README § Coordinate contract). Retina is handled by the geometry, not by telling the model to halve coordinates.

### Safety specifics on the host desktop

- **Kill switch.** The primary guarantee is at the action layer (README § Safety): the host never synthesizes the stop key while a session is active. Detect the user's key press with a *listen-only* event tap, which needs only Input Monitoring and is the lower-risk option. A *modifying* tap could also swallow synthetic stop-key events from other sources. However, revoking Accessibility while an active tap is installed has been reported to hang system input. Treat a modifying tap as optional hardening: test the revoke path and remove the tap on any permission change.
- **Hide or exclude non-granted apps** during the agent's turn and restore them at turn end, on abort, and on host crash. Use a watchdog in the host and a timeout on unhide.
- **Single controller.** The host enforces the lease. A second harness asking for the same display gets `target-busy`.
- **Sensitive app categories.** Default tiers: browsers *view* unless the domain is granted, terminals and IDEs *click*, System Settings, Finder, password managers, and trading/banking apps *blocked or sentinel-warned*. Detect categories by bundle id and app category, never by window title, which is attacker-controllable screen content.
- **Sanitize app names before they reach the model.** Installed-app lists injected into tool descriptions are a prompt-injection channel. Treat app names as untrusted strings: restrict their character set, bound their length and the number listed, and prefer apps from system-managed install locations.

### Isolation: macOS VMs and their limits

- **Virtualization.framework** runs macOS guests on Apple silicon. The license and the framework both cap a host at **two concurrent macOS guests**. Linux guests are uncapped. Signing in with an Apple Account inside a guest needs a 15+ host and a 15+ guest.
- **Tooling:** Tart (OCI-distributed images, CI integrations; its maintainers joined OpenAI in April 2026 and dropped license fees), Lume (CLI, local HTTP API, and MCP control from the Cua project), Anka and Orka for fleets, and UTM for manual setups.
- **Drive from inside.** Install the same host app in the golden image, grant permissions once interactively (on 27, MDM can't pre-grant Accessibility), snapshot, and connect over a forwarded port or vsock. Driving from outside over VNC gives pixels only and no AX. Keep VNC for the human live view.
- **What doesn't isolate:**
  - A second login session via fast user switching. Capture and TCC are per GUI session. Capture from non-foreground session contexts (launchd, SSH) has been reported to return wallpaper or redacted images while reporting success. There is no documented support for agents in background sessions.
  - A virtual display (only via a private API) gives the agent its own screen area but not its own cursor, focus, or menu bar. It helps only in combination with background delivery, and it has persistence side effects.

### Swift module structure

```
ComputerUseKit (SwiftPM, macOS 15+)
├─ CUCore          Sendable value types only: TargetLayout, WindowRef{pid, processStart, windowID, bounds},
│                  ObservationID, ElementRef, ScreenshotGeometry, Action, ActionOutcome, PermissionSnapshot, errors.
│                  No AppKit/TCC imports → unit-testable anywhere; this is what the harness library depends on.
├─ CUPermissions   PermissionBroker: preflight/request per service, change polling → AsyncStream, Settings deep-links.
├─ CUCapture       actor CaptureService: shareable-content cache, window/display/rect capture, own-app exclusion,
│                  GPU-side downscale, optional long-lived SCStream, full-res zoom, ImageIO encode, Vision OCR merge.
├─ CUAccessibility AX executor (dedicated thread + run loop), bounded snapshotter, Chromium/Electron enablement,
│                  observers, element re-resolution and drift check, semantic actions, compact-text renderer.
├─ CUInput         InputInjector: background (AX → postToPid; optional private path behind a probe) and foreground
│                  (global post + activate/restore); chords; Unicode chunking; scroll; drag; agent-cursor overlay.
├─ CUAppControl    NSWorkspace launch/hide/quit (activates=false), open URL, Apple Events runner with consent probe,
│                  `shortcuts` wrapper and catalog.
├─ CUHostProtocol  Codable request/response + capability negotiation; peer code-signature validation.
└─ CUIsolation     (optional) VM adapters (Tart/Lume CLI or Virtualization.framework), in-guest connector, VNC observer.

ComputerUseHost.app   LSUIElement; links all of the above; serves CUHostProtocol; owns grants;
                      onboarding checklist, "agent active" HUD (sharingType = .none), stop key, lease enforcement.
```

The harness depends on `CUCore` and `CUHostProtocol` only. The `DisplayTarget` implementation it receives is an XPC client. Pure pieces (pruning and rendering the AX tree, coordinate mapping, action classification) live in `CUCore` and are tested without permissions.

A capture sketch showing the geometry discipline:

```swift
struct ScreenshotGeometry: Sendable, Codable {
    let capturedRect: CGRect      // CG global points, top-left origin
    let imageSize: CGSize         // pixels actually sent to the model
    let scaleFactor: Double       // backing scale of the captured display
    func toGlobal(_ p: CGPoint) -> CGPoint {
        CGPoint(x: capturedRect.minX + p.x * capturedRect.width  / imageSize.width,
                y: capturedRect.minY + p.y * capturedRect.height / imageSize.height)
    }
}

actor CaptureService {
    func captureWindow(_ id: CGWindowID, maxLongEdge: Int) async throws -> (CGImage, ScreenshotGeometry) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == id }) else { throw CUError.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let rect = win.frame                     // global points; verify it matches the captured content
                                                 // (shadows, title bar) on each OS version — see list below
        let scale = min(Double(filter.pointPixelScale),                 // never upscale past native
                        Double(maxLongEdge) / Double(max(rect.width, rect.height)))
        let cfg = SCStreamConfiguration()
        cfg.width = Int((rect.width * scale).rounded())                 // pixels → GPU downscale
        cfg.height = Int((rect.height * scale).rounded())
        cfg.scalesToFit = true; cfg.showsCursor = false; cfg.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return (image, ScreenshotGeometry(capturedRect: rect,          // the same rect the image was sized from
                                          imageSize: CGSize(width: image.width, height: image.height),
                                          scaleFactor: Double(filter.pointPixelScale)))
    }
}
```

---

## Alternatives

### CLI borrowing the terminal's grants

Run the drivers inside the harness CLI and let users grant Screen Recording and Accessibility to their terminal.

**When this works:** developer tools whose users already live in a terminal and accept that every program run there inherits the grants.

**Why not as default:** the grant is far broader than the agent, its attribution is confusing, it doesn't work for servers or GUI hosts, and grants break when the binary moves or is re-signed. Keep it as the dev escape hatch.

### Sandboxed Mac App Store app

**When this works:** an agent that only needs event posting and the system content picker. Both are sandbox-compatible.

**Why not as default:** AX on other apps is unavailable in the sandbox, and App Review guidelines restrict using accessibility features for non-accessibility purposes. Without AX there are no element refs, no semantic actions, and no background delivery. The result is pixels only.

### VM driven purely over VNC

**When this works:** quick isolation with no in-guest setup, and CI-style throwaway runs.

**Why not as default:** pixels only, foreground-only input inside the guest, no AX, and no verification evidence beyond screenshots. An in-guest host gives the full contract.

### Private-API-first delivery

Use private window-server entry points as the primary input path and private CGS calls for Spaces.

**When this works:** power-user tools willing to chase OS releases.

**Why not as default:** any point release can break it silently. Use it behind a capability probe, with the public path as the fallback, and record which path ran.

---

## Anti-patterns

- **Using `CGWindowListCreateImage`.** It is obsoleted in the SDK you build with and changes behavior across releases. ScreenCaptureKit only.
- **Sizing captures in points.** It gives half-resolution, blurry screenshots, and the coordinate mapping drifts. Configuration sizes are pixels.
- **AX on the cooperative pool or the main actor.** A slow app blocks a pool thread for the full messaging timeout, and messaging your own process from the main actor deadlocks.
- **Unbounded AX traversal.** One pathological app (a deep web view, a menu bar extra) hangs the whole observe step. Budgets, deadlines, partial results.
- **Permission inference from side effects.** "Window names came back nil, so we lack Screen Recording" stopped being true on 27 and was never supported. Preflight.
- **Foreground delivery by default on a shared desktop.** The user's cursor jumps and keystrokes land in the wrong window. Background-first, with foreground as a consented escalation.
- **Retrying an AX press that returned an error.** It may have succeeded. Observe first.
- **Detecting sensitive apps by window title.** Titles are screen content that an attacker controls. Use bundle ids and categories.
- **A host socket without peer authentication.** It hands the host's grants to any local process.
- **Assuming managed fleets can pre-approve everything.** On 27 Accessibility always needs a user click. Onboarding must handle "declined."

---

## Verify on hardware before relying on

These questions could not be settled from documentation:

- Per-window ScreenCaptureKit capture of minimized windows and windows on other Spaces, on 15, 26, and 27.
- Whether PPPC Post Event pre-grants still apply on 27.
- The `keyboardSetUnicodeString` per-event length limit on 26 and 27.
- Whether current Chromium and Electron builds need only `AXManualAccessibility` or also `AXEnhancedUserInterface` for full web-content trees.
- What the 26+ `SCScreenshotConfiguration` "ignore UI elements" option actually removes (cursor, menu bar, overlays).
- Whether a window's `SCWindow.frame` exactly matches the region a `desktopIndependentWindow` capture produces (shadow, title-bar inclusion) when `ignoreShadowsSingleWindow` is set. Any mismatch shifts every click.
- Whether pasteboard reads by a background host trigger the 15.4+ privacy prompt, and how often.

---

## Cross-references

- [computer-use/README.md](./README.md): display-target contract, action model, grants, layered safety, screenshot budget, CU sub-agent.
- [Execution Environments](../execution-environments/): the backend registry and observer-token machinery that display targets reuse. The `isolation` vocabulary and the macOS-VM display-target kind are defined in the README manifest here.
- [Tool System § Permissions](../../core/tool-system/permissions.md): grants and tiers map onto availability rules and argument-level gating.
- [Model Pool § Model classes](../../core/model-pool/model-classes.md): on-device models as `local-only` offerings for the `guard` and `vision-describe` roles.
- [Interface § Approval UX](../../surfaces/interface/approval-ux.md): where the host's onboarding and per-action approvals render.
