# Computer use: open feedback for the spec team

Nothing is open. The spec team adopted the change request in [COMPUTER_USE_SPEC_CHANGE_REQUEST.md](COMPUTER_USE_SPEC_CHANGE_REQUEST.md), then resolved the four items this file raised after that update:
- **Local input ending a remotely unlocked session.** The lease now carries `remoteUnlock`, set when the unlock card was answered off the Mac. Ending the session on local input still waits on telling local input apart on hardware, as `macos.md` § Safety specifics on the host desktop allows.
- **Relocking after a crash.** A relock-pending marker, with the host as a launchd agent that checks for it at startup. Development mode offers no unlock flow.
- **Which app a user-started takeover is for.** The working app when the takeover starts, or no remote input when there is none.
- **How the Mac is locked.** The Lock Screen shortcut, then a check, then display sleep, then a notice to the conversation if it's still unlocked.

The implementation follows the spec as updated. The questions `macos.md` § Verify on hardware before relying on lists for sleep, lock, and remote input are still unverified.
