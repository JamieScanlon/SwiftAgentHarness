# Computer use on the user's own Mac: proposed spec changes

Nov 8, 2026 · @Jamie Scanlon

## Summary

We ask the spec team for three changes to the computer-use pages, all about the user's own Mac. SwiftAgentHarness has built all three for a downstream client, but the spec today either says the opposite or says nothing.

1. **A live view of the user's own Mac, limited to the apps the user granted.** The spec treats the host desktop as a target with no live view.
2. **A typed way for a target to say the user must act at it first**, such as waking or unlocking it, returned to the parent as `needs-user`.
3. **Rules for display sleep and the lock screen on the host desktop**, including a remote unlock that only the user can do, with their own password.

Spec references are relative to `harness-template/`. Proposed wording is a starting point; the decisions behind it are what we need confirmed.

## Background

A downstream client, SileniaAI, lets a user start computer-use runs on their Mac from a phone, usually while away from the Mac. That raised three problems the spec doesn't cover:

- **The user can't see the run or finish a handoff.** A login or 2FA step needs the user, and the user isn't at the Mac.
- **The display is asleep.** Every observation failed until the progress check ended the run.
- **The Mac is locked.** With macOS set to ask for the password as soon as the display sleeps, a sleeping display means a locked Mac. The agent can't get past the lock screen, and mustn't try.

The client sent three change requests, and SwiftAgentHarness built them between commits `be2a426` and `d7aef91`. Each decision below is already implemented, so this request asks the spec to catch up, or to tell us where it disagrees.

## Change 1: a live view of the user's own Mac, limited to granted apps

A shared host desktop may serve a live view, but it shows and takes input only within the user's grants. That lets a user away from the Mac watch the run and finish a handoff, while the view never becomes a remote desktop.

What we decided:

- **Frames.** Frames use the agent's capture filter: granted apps, minus excluded apps, never the harness's own UI. The pointer is shown, and frames keep coming during takeover. Where an ungranted window, or the harness's own, covers part of a granted one, that part is blanked, so the view shows where input won't land.
- **Input during takeover.** A pointer event lands only where the top window at that point belongs to a granted app. The harness's own windows and its activity indicator count as ungranted. A drag is checked at every move, and a release outside granted windows lands where the drag last was. Keys and text go through only while a granted app is frontmost. System shortcuts need the frontmost app's `system-keys` flag. The stop key is never passed.
- **Tiers limit the agent, not the user.** Takeover is the user acting, so a granted app's tier doesn't limit their input.
- **No observer links** on a shared target unless the operator opts in.
- **Disclosure.** The grant dialog says: "Your granted apps' windows can be watched from a live view, and controlled from it during a takeover."
- **Presence is unchanged.** A present user on a shared target finishes a handoff at the machine or through its live view. We assume a host that can serve a view is paired with a client that can show one; a pairing with neither waits out the handoff's timeout.
- **Watch mode.** On a shared target, a sensitive-domain session continues while a view is open, or after a present user confirms on a card. "Only while a view is open" stays the rule for exclusive targets.

Where the spec needs to change:

| Spec location | Says today | Proposed |
| --- | --- | --- |
| `backends/computer-use/README.md` § Manifest, `humanPresence` | Only `exclusive` says "People may watch through a live view or act during takeover." | Add under `shared`: "It may serve a live view limited to granted apps; see § Display targets." |
| README § Display targets as an execution-environment family | Doesn't say what a live view's frames contain or where a viewer's input may go. Allows observer links on any target. | Add a rule, "A shared target's live view stays within the grants", carrying the frame, input, tier and observer bullets above. |
| README § Sessions, leases, grants, and tiers | Silent on how a present user finishes a handoff on a shared target. | Add: "On a shared target a present user finishes a handoff at the machine or through its live view. A pairing with neither waits out the handoff's timeout." |
| README § Safety is layered, item 5 | Splits watch mode only by whether the target has a live view, and gives "the host desktop, which is the user's own screen" as the example without one. | "On exclusive targets with a live view, the session continues only while a view is open. On shared targets, it continues while a view is open or after a present user confirms on an approval card. On targets without a view, only the card applies. With no view open and no user attached, it ends." |
| README § Safety is layered, item 7 | "On isolated targets the user acts through the live view." | "On isolated targets the user acts through the live view. On a shared target the user acts at the machine, or through its live view where it has one." |
| README § Oversight surfaces, live view bullet | "…or, on targets without one, a present user's confirmation." | "…or, on shared targets and targets without one, a present user's confirmation." Add: surfaces offer the view for a handoff on a shared target, and say the user can act at the machine instead. |
| `backends/computer-use/macos.md` TL;DR item 7 and § Isolation | Describe live views only for VM guests. | Add that the host app may serve a granted-apps view of the host desktop, per README § Display targets. |
| macos.md § Perception: ScreenCaptureKit, "Exclude yourself" | Covers the model's captures only. | Add: "Live-view frames of the host desktop use the same filter, and blank the parts of granted windows that other windows cover." |

## Change 2: a target can say the user must act at it first

A target that can't be used until the user does something at it throws a typed `target-unavailable` error with a reason the user can act on. The parent gets `needs-user` with that reason, and nothing retries it. Today the spec has no such error, so a sleeping display looked like a failed observation and the session retried until the progress check stopped it.

What we decided:

- **Where it can come from.** `lease`, `observe` or `act` may throw `target-unavailable(reason)`. The reason says what to do, for example "this Mac is locked; unlock it and try again".
- **At lease.** The lease is refused, and the parent gets `needs-user` with the reason before any step runs.
- **Mid-session.** The action that hit it comes back `refused` with the reason as evidence. The rest of its batch is `not-executed`, and the session ends at once with terminal reason `target-unavailable`. The parent gets `needs-user` with the reason.

Where the spec needs to change:

| Spec location | Says today | Proposed |
| --- | --- | --- |
| README § Runtime contract | Names no error for a target the user must act at. | Add: "`lease`, `observe` and `act` throw `target-unavailable` with a user-facing reason when the target can't be used until the user acts at it, such as waking or unlocking it. It is never retried." |
| README § Runtime contract, `ReleaseReason` | "Each session terminal reason releases with the same-named value." There is no `target-unavailable` value. | Add `"target-unavailable"` to `ReleaseReason`. We release as `cancelled` today, which breaks the same-name rule; see open question 1. |
| README § The computer-use sub-agent | Lists the terminal statuses, but not when a target the user must act at gives `needs-user`. | Add: "`needs-user` with the target's reason means the user must act at the target, such as waking or unlocking it, before delegating again." |

## Change 3: display sleep and the lock screen on the host desktop

The lock screen is a hard stop for the agent. Only the user gets past it, with their own password, at the Mac or through macOS Screen Sharing. A session that found the Mac locked leaves it locked. The spec says nothing about display sleep or the lock screen today.

What we decided:

- **Waking.** A host target may wake the display for a lease: it declares user activity and holds a "prevent idle display sleep" assertion until release. After release the user's own sleep and lock settings apply again. It is off by default.
- **The lock screen refuses the agent.** A locked session refuses the lease, and refuses `observe` and `act` if it locks mid-lease, with `target-unavailable` (Change 2). The agent never types into the lock screen. Lock state comes from the OS session, never from screen content.
- **Lock state is part of the grant request.** A new optional runtime method, `isLocked()`, defaults to `false`. The harness asks it just before the grant dialog, so the dialog can offer to unlock as part of approving. The answer travels with the lease request as `targetLocked`.
- **The only unlock is the user's.** The user types their own password into macOS, at the Mac or through Screen Sharing. The harness never receives, stores or relays it, and never drives the lock screen.
- **Only the lease waits.** A host may give the lease a bounded wait for an unlock already under way, with the display kept awake meanwhile. A Mac that locks mid-session is refused at once. The wait is zero by default.
- **Leave it as you found it.** A session that found the Mac locked, at the dialog or at the lease, may sleep the display at release. With the Mac set to ask for its password immediately, that locks it again. With a delay set, it stays unlocked until the delay passes. It is off by default.
- **Over the host protocol.** Lock state is a capability-gated request (`lock-state`). A host without the capability is taken as unlocked and never asked, so the lease still refuses a locked Mac as before.

The remote unlock, as the client runs it:

1. The harness asks the target `isLocked()` and gets `true`.
2. The grant card says the Mac is locked and offers "Unlock and allow".
3. The user connects to the Mac's Screen Sharing from the phone, types their password at the lock screen, and disconnects.
4. The phone answers the card. The lease waits up to its configured time for the unlock to register, then the run starts.
5. At release, the session sleeps the display, which locks the Mac again.

Where the spec needs to change:

| Spec location | Says today | Proposed |
| --- | --- | --- |
| macos.md § Safety specifics on the host desktop | Covers the kill switch, capture, the single controller and app categories. Nothing on sleep or the lock screen. | Add bullets: **Display sleep** (waking), **The lock screen is a hard stop**, **The only unlock is the user's**, and **Leave it as you found it**, as decided above. |
| README § Runtime contract | No way to ask a target whether it's locked. | Add `isLocked?(): Promise<boolean>`, "asked before the grant dialog; targets with no lock screen omit it, which reads as unlocked." |
| README § Sessions, `LeaseRequest` | No lock field. | Add `targetLocked?: boolean // the target was locked when the user was asked for grants`. Add to the grant dialog bullet: "When the target is locked, the dialog may offer to unlock it as part of approving." |
| macos.md § The host protocol | Lists the protocol's disciplines; no lock state. | Add: "Lock state is a capability. A client takes a host without it as unlocked and doesn't ask." |
| macos.md § Verify on hardware before relying on | No entries for sleep or lock. | Add the hardware checks listed under open question 4. |

## Compatibility

Everything new is opt-in or has a default that keeps today's behaviour, so an implementation that does nothing stays conformant except in two places:

- **The new error and terminal status.** An implementation must end a session on `target-unavailable` instead of retrying, and report `needs-user`. Code that switches exhaustively over errors, terminal reasons or release reasons gains a case.
- **Watch mode on shared targets.** Item 5 now allows a card where a view isn't open. An implementation that still requires an open view on a shared target stays safe, but ends sessions that the new rule lets continue after a card.

A shared target with no live view behaves as before. The `isLocked()` method, the `targetLocked` field and the `lock-state` capability are all optional, and their absence reads as unlocked. Waking, the unlock wait and relocking are off by default.

## Open questions

1. **Which release reason does `target-unavailable` use?** We release as `cancelled`, which breaks the rule that each terminal reason releases under its own name. We'd rather add `"target-unavailable"` to `ReleaseReason` and switch to it. The alternative is to name it as an exception.
2. **Should the spec recommend defaults for remotely started host runs?** We ship waking, the unlock wait and relocking off. We lean towards "relock whenever the unlock wait is on", since a Mac left unlocked is the less safe state.
3. **Should the spec name Screen Sharing?** The alternative is "an OS-provided remote session in which the user types their own password", which also covers other platforms.
4. **Which hardware checks belong in macos.md?** We propose these four for § Verify on hardware:
   - Whether the session's screen-locked flag (`CGSSessionScreenIsLocked`) is reliable on 26 and 27, while the display sleeps and during a Screen Sharing session.
   - Whether declaring user activity wakes the display of a locked Mac.
   - Whether `IORequestIdle` on `IODisplayWrangler`, which `pmset displaysleepnow` uses, sleeps every display on Apple silicon on 27, including external ones and during Screen Sharing. It exists on the Apple silicon Mac we checked.
   - Whether "require password immediately" relocks after a forced display sleep.
5. **Do observers see a paused frame during takeover on a shared target?** Shared targets allow no observers unless the operator opts in. We assume the existing rule, a paused frame for observers during takeover, still applies when the operator does. Please confirm.
