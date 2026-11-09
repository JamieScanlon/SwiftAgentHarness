# Computer use: open feedback for the spec team

The spec team adopted the change request in [COMPUTER_USE_SPEC_CHANGE_REQUEST.md](COMPUTER_USE_SPEC_CHANGE_REQUEST.md): the live view of the user's own Mac, `target-unavailable`, and display sleep and the lock screen are now in `backends/computer-use/README.md` and `macos.md`, and the implementation follows them. Some rules came back stricter than we asked: relocking is mandatory and explicit, remote takeover input reaches only the handoff's app and no broad-reach app, keys go to that app's process, and takeover is never recorded.

What's still open after that update is below. Spec references are relative to `harness-template/`.

## Local input ending a remotely unlocked session: not implemented

`macos.md` § Safety specifics on the host desktop says a session the user unlocked remotely should end with `target-unavailable` ("someone started using this Mac"), and the host should lock the Mac, when someone uses the Mac's own keyboard or mouse. It applies "where the host can tell local input apart from Screen Sharing input and from its own synthesized events".

We can't tell either thing yet:
- **Whether the unlock was remote.** The harness sees only that the Mac was locked and then wasn't. A user who walked up and unlocked it at the Mac looks the same.
- **Whether input is local.** Telling the Mac's own keyboard from Screen Sharing input is one of the spec's own hardware questions (§ Verify on hardware before relying on).

Until both are settled on hardware, the host doesn't end the session on local input. The existing `userTyping` event still pauses the agent's input while anyone types.

## Relocking after a crash

§ Safety specifics requires relocking "on every release path, including abort and the crash watchdog". Every release, every abort, and a display host releasing a dropped holder relock. A lease taken over from a holder that died without releasing relocks first. Two paths remain:
- **The display host itself crashes.** Nothing in its process survives to lock the Mac, and there's no separate watchdog process.
- **In-process development mode.** The harness and the target share a process, so a harness crash leaves the Mac unlocked.

A watchdog outside the host process would close both. The spec could say whether one is required, or whether the hosted shape with its liveness check is enough.

## Which app a user-started takeover is for

README § Display targets limits remote takeover input to "the app the handoff is for (the working app when the agent called `handoff`)". A takeover the user starts from the oversight surface, with no handoff, has no such app. We use the working app when the takeover starts, the same rule as a handoff, and take no remote input when there is none. The spec could say so, or say that a takeover without a handoff takes no remote input.

## How the Mac is locked

§ Safety specifics allows the Lock Screen shortcut or "a lock call behind a capability probe". We post ⌃⌘Q from a private event source and fall back to sleeping the display when the Mac isn't locked 2 seconds later. Whether that shortcut locks at once on 26 and 27, including during Screen Sharing, is on the spec's hardware list.
