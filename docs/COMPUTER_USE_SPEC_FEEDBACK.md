# Computer use: open feedback for the spec team

Questions raised by a downstream change request: a live view of the user's own Mac, limited to granted apps, so a user who started a run from their phone can watch it and complete handoffs. Each item gives the problem, what the implementation does today, and a suggested change. Spec references are relative to `harness-template/`.

The part of the request that needs no spec change is built: `RemoteDisplayTarget` can have the harness serve a display host's live view from the host's frames, and a shared target's live view takes no observers by default. What remains is a live-view mode for `MacHostDisplayTarget` on the user's own Mac, which waits on the decisions below.

## 1. May a shared host desktop have a live view?

**Problem.** The spec treats a live view as something isolated targets have and the host desktop doesn't:
- `backends/computer-use/README.md` § Runtime contract, `humanPresence`: "People may watch through a live view or act during takeover" appears only under `exclusive`.
- § Safety is layered, not a single gate, item 5, names "the host desktop, which is the user's own screen" as the example of a target without a live view.
- The same section, item 7: "On isolated targets the user acts through the live view."
- `backends/computer-use/macos.md` describes live views only for VM guests (TL;DR item 7, § Isolation: macOS VMs and their limits).

None of these forbids a host-desktop view, but none allows one either.

**Implementation.** `MacHostDisplayTarget` gives out live frames only with `servesLiveFrames`, which is meant for VM guests. Those frames show the whole main display, every app except the excluded ones. Its viewer input goes to the foreground with no grant check. For the user's own Mac it stays off, so the host desktop has no live view.

**Suggested change.** Allow a live view of a shared host target in one mode only: it shows granted apps, and it takes input only for granted apps during the user's takeover. Items 4 and 5 give the terms. The grant dialog should say so, for example: "Your granted apps' windows can be watched from a live view, and controlled from it during a takeover."

## 2. Does a present user have to be able to see the target?

**Problem.**
- `userPresent` is "an interactive user is attached and can answer approvals now" (§ Sessions, leases, grants, and tiers).
- Host targets need an operator initiator and a present user (the same section, on `initiator` and `userPresent`).
- A user on a phone, connected to the server on their Mac, qualifies on both counts, but can't see the Mac's screen. A handoff on the host desktop, such as a login, 2FA, a CAPTCHA, or a payment, then has nothing to be completed in. It waits out its 15 minutes, and the run comes back `needs-user`.
- The rationale for `shared` is that "a person may be using this screen right now". A present user who is somewhere else makes that rationale weaker, not stronger.

**Implementation.** Presence is the run's origin: interactive runs count as present wherever the user is. A handoff on the host desktop waits for its full timeout, whether or not the user can reach the screen.

**Suggested change.** Pick one:
- **(a) The live view is the answer.** Accept item 1. A remote user completes handoffs through the view, and the presence rule stays as it is.
- **(b) Presence also says where the user is.** Split "can answer approvals" from "is at the target". A shared target with no live view could then end a handoff at once as `needs-user` when the user isn't at it, rather than wait 15 minutes. It could also refuse the host desktop for such a run.

(a) is what the change request asks for. (b) is worth having even with (a), for hosts that don't enable the view.

## 3. Watch mode on a shared target that has a live view

**Problem.** § Safety is layered, not a single gate, item 5, splits watch mode by whether the target has a live view. On targets with one, the session continues only while a view is open. On targets without one, a present user confirms on an approval card. If the host desktop gains a view under item 1, the first rule applies. A user sitting at their Mac would then have to open a live view of their own screen to keep a sensitive-domain session going.

**Implementation.** The session uses the manifest's `observerAccess`: a target that declares a live view waits for a viewer, and one that doesn't asks for a confirmation card.

**Suggested change.** On a `shared` target, accept either: an open view, or a present user's confirmation on a card. Keep "only while a view is open" for `exclusive` targets, where nobody is at the screen.

The same reasoning applies to the oversight surface. The interface shouldn't tell a user at the Mac to "use the live view" for a handoff on a shared target. It should offer the view and say they can act at the machine instead.

## 4. What may a viewer's input reach on a shared target?

**Problem.** § Display targets as an execution-environment family and § Oversight surfaces say a live view takes input only from the user who started a takeover. They don't say where that input may go. On an isolated target everything on the screen belongs to the session. On the host desktop, a user link during takeover is remote control of the whole Mac, so a link that leaks reaches everything.

**Implementation.** For VM guests, viewer input goes to the foreground with no further check, which is right for a disposable guest.

**Suggested change.** On a shared target, viewer input during takeover reaches granted apps only:
- **Pointer events.** The window on top at the point must belong to a granted app. The agent's own hit test lets the harness's windows through, because a foreground delivery brings the app to the front first. Viewer input brings nothing forward, so here the harness's own windows and the "agent active" HUD count as not granted, or the working app is brought to the front when takeover starts.
- **Drags.** Checked at every move while a button is held, and at the release, so a drag can't drop into an ungranted app.
- **Keys and text.** Delivered only while a granted app is frontmost.
- **Global shortcuts** (⌘Tab, ⌘Space, ⌃⌘Q, Force Quit, …): only with `system-keys`, the same rule the classifier applies to the agent (`README.md` § Permission classification per action). The system handles them whatever app is frontmost, so the frontmost check doesn't cover them.
- **The stop key** is never passed through.

**A question in return.** Does a granted app's tier limit the user? The suggestion is no: tiers limit the agent, and takeover is the user acting. A `view`-tier app would then still take the user's typing.

## 5. What does a shared target's live view show?

**Problem.** The spec says nothing about what a live view's frames contain. For the host desktop, the agent's captures show granted apps only (`macos.md` § Perception: ScreenCaptureKit, "Exclude yourself"). A whole-display view would show the user's own observers what the agent itself is never shown.

**Implementation.** Live frames from `MacHostDisplayTarget` show the whole main display, minus excluded apps, with the pointer.

**Suggested change.** Frames use the agent's capture filter: granted apps, minus the excluded ones, never the harness's own UI. The pointer can be shown. Frames keep coming during takeover, unlike the agent's capture.

**What the frames must show about ungranted windows.** That filter leaves ungranted windows out entirely. A granted window under an ungranted one is drawn as if it were on top. The viewer clicks it, and the click is refused with no visible reason. Suggest blanking the area where an ungranted window, or the harness's own window, covers a granted one, so the view shows where input won't land.

## 6. Observers on a shared target

**Problem.** § Display targets as an execution-environment family allows observer links on any target: an observer link "is view-only and may be shared with someone who is only watching". On a shared target that is a view of someone's own screen, even when limited to granted apps.

**Implementation.** Since `a732b5e`, a shared target's live view takes no observers. A host can allow them with `DisplayLiveViewConfiguration.maxObserversPerSharedFeed`. This is stricter than the spec and compatible with it.

**Suggested change.** Have the spec say this: observers on a `shared` target only if the operator opts in. Otherwise, confirm that the implementation's default is a local choice.
