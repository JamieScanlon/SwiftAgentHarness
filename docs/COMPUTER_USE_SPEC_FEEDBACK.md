# Computer use: open feedback for the spec team

Both sections below are written up for the spec team as one change request, [Computer use on the user's own Mac: proposed spec changes](https://claude.ai/artifact/L1RBD8sdFYNyTZMQmgzSyq), saved here as [COMPUTER_USE_SPEC_CHANGE_REQUEST.md](COMPUTER_USE_SPEC_CHANGE_REQUEST.md). It adds two items found while writing it: the `target-unavailable` terminal reason releases as `cancelled`, against README § Runtime contract's rule that each terminal reason releases under its own name; and the hardware checks macos.md § Verify on hardware before relying on should list for sleep and lock.

## A live view of the user's own Mac: decided, spec text pending

A downstream change request asked for a live view of the user's own Mac, limited to granted apps, so a user who started a run from their phone can watch it and complete handoffs. The spec treated the host desktop as having no live view. The questions below were decided, and the implementation follows the decisions. The spec text still says otherwise in the places each item names. Spec references are relative to `harness-template/`.

### 1. A shared host desktop may have a live view, in one mode

**Decided.** A shared host target may serve a live view that shows granted apps only and takes input only for granted apps during the user's takeover (items 4 and 5). The grant dialog says so: "Your granted apps' windows can be watched from a live view, and controlled from it during a takeover."

**Spec text to change.**
- `backends/computer-use/README.md` § Runtime contract, `humanPresence`: "People may watch through a live view or act during takeover" appears only under `exclusive`.
- § Safety is layered, not a single gate, item 5: "the host desktop, which is the user's own screen" is the example of a target without a live view.
- The same section, item 7: "On isolated targets the user acts through the live view."
- `backends/computer-use/macos.md` describes live views only for VM guests (TL;DR item 7, § Isolation: macOS VMs and their limits).

**Implementation.** `MacHostDisplayTarget.Configuration.liveFrames: .grantedApps`. The VM guest's whole-display frames are `.wholeDisplay`. `ComputerUseGrantRequest.liveViewNotice` carries the dialog text.

### 2. Presence stays as it is; the live view is how a remote user completes a handoff

**Decided.** Option (a). Hosts and clients are assumed to be aligned in capability: a host that can serve a screen view is used by a client that can show a live view. Mismatched pairs aren't solved for, and the handoff timeout is acceptable there.

**Spec text to change.** § Sessions, leases, grants, and tiers could say that a present user on a shared target completes a handoff at the machine or through its live view, and that a pairing with neither waits out the handoff's timeout.

**Implementation.** No change to presence.

### 3. Watch mode on a shared target: an open view or the user's confirmation

**Decided.** On a `shared` target, either an open view or a present user's confirmation on a card keeps a sensitive-domain session going. "Only while a view is open" stays for `exclusive` targets. Surfaces offer the view for a handoff on a shared target, and say the user can act at the machine instead.

**Spec text to change.** § Safety is layered, not a single gate, item 5, which splits watch mode only by whether the target has a live view. § Oversight surfaces, for the handoff guidance.

**Implementation.**
- The session asks for the card on a shared target when nobody is watching its view.
- Activity intents and the session listing carry `sharedScreen`.
- The terminal's handoff dialog says to use the target at the machine or through the link.

### 4. A viewer's input on a shared target reaches granted apps only

**Decided.** During takeover, a viewer's input on a shared target reaches granted apps only:
- **Pointer events.** The window on top at the point must belong to a granted app. The harness's own windows and the HUD count as ungranted.
- **Drags.** Checked at every move. A release outside granted windows lands where the drag last was.
- **Keys and text.** Delivered only while a granted app is frontmost.
- **Global shortcuts.** Only with the frontmost app's `system-keys` flag.
- **The stop key.** Never passed.

A granted app's tier doesn't limit the user: tiers limit the agent, and takeover is the user acting.

**Spec text to change.** § Display targets as an execution-environment family and § Oversight surfaces, which say who may send input but not where it may go.

**Implementation.** `MacHostDisplayTarget.liveInput` with `.grantedApps`. The stop key is refused in every mode.

### 5. A shared target's frames show what the agent sees, with covered parts blanked

**Decided.**
- Frames use the agent's capture filter: granted apps, minus the excluded ones, never the harness's own UI. The pointer is shown.
- Frames keep coming during takeover.
- Where an ungranted window, or the harness's own, covers a granted one, that part is blanked, so the view shows where input won't land.

**Spec text to change.** § Display targets as an execution-environment family, which doesn't say what a live view's frames contain. `macos.md` § Perception: ScreenCaptureKit, beside "Exclude yourself".

**Implementation.** `MacHostDisplayTarget.liveFrame` with `.grantedApps`.

### 6. No observers on a shared target unless the operator opts in

**Decided.** A shared target's live view takes no observer links unless the operator opts in.

**Spec text to change.** § Display targets as an execution-environment family, which allows observer links on any target.

**Implementation.** `DisplayLiveViewConfiguration.maxObserversPerSharedFeed`, 0 by default.

## The host desktop asleep or locked: implemented, spec silent

A downstream change request found that a run started away from the Mac failed every observation, because its display was asleep, and that a Mac set to lock when its display sleeps shows a lock screen the agent can't, and mustn't, get past. The spec says nothing about display sleep or the lock screen. Spec references are relative to `harness-template/`.

**Implemented.**
- `MacHostDisplayTarget.Configuration.wakesDisplay`, off by default: each lease declares user activity and holds a "prevent idle display sleep" assertion until release.
- A locked Mac refuses the lease, and refuses observing and acting mid-lease, so the agent never types into the lock screen.
- `DisplayTargetError.targetUnavailable(reason)` for a target the user must act at first. A lease refused with it, or a session that hits it, ends at once as `needs-user` with the reason. The session's terminal reason is `target-unavailable`, and its lease is released as `cancelled`.

**Implemented later, for a locked Mac the user unlocks remotely.** A second change request asked for the user to unlock the Mac from a phone, through macOS Screen Sharing, as part of approving the session.
- `DisplayTarget.isLocked()`, with a default of `false`. The registry asks it before the grant dialog and passes the answer as `ComputerUseGrantRequest.targetLocked`, and to the target as `LeaseRequest.targetLocked`. It crosses the display host wire under a new `lock-state` capability, as protocol version 7.1.
- `MacHostDisplayTarget.Configuration.unlockTimeout`, zero by default: how long a lease waits for an unlock already under way. Only the lease waits; a Mac that locks mid-session is still refused at once.
- `MacHostDisplayTarget.Configuration.relocksOnRelease`, off by default: a session that found the Mac locked sleeps its display at release, which relocks a Mac set to ask for its password immediately.
- The harness never sees the password; the user types it into macOS itself.

**Spec text to consider.**
- `backends/computer-use/macos.md` § Safety specifics on the host desktop could cover display sleep and the lock screen. The change request asked for three notes there, which this project can't make since the spec is read-only: lock state is part of the grant request; the only supported remote unlock is the user's own password, through Screen Sharing; and a session that found the Mac locked leaves it locked.
- `backends/computer-use/README.md` § The computer-use sub-agent could list a target the user must wake or unlock among the `needs-user` cases, and § Runtime contract could name an error for it.
