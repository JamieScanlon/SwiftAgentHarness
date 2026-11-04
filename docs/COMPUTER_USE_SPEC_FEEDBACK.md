# Computer use: feedback for the spec team

This reviews every row of "Implementation notes and spec gaps" in [COMPUTER_USE.md](COMPUTER_USE.md), as they stood before the spec's November 2026 revision, against the spec: `harness-template/backends/computer-use/README.md` and `macos.md`, plus the pages they lean on. The question for each row: did the implementation have to decide something because the spec is unclear, wrong, or silent? Or was the decision forced by something outside the spec, such as Swift, this harness's existing architecture, or a vendor's API?

Spec references below are relative to `harness-template/`.

## Status after the November 2026 revision

The spec team revised the computer-use pages, and the pages they lean on, in response to this review. The implementation now follows the revision, and [COMPUTER_USE.md](COMPUTER_USE.md) describes it. The sections after this one are the review as it was sent, kept for reference.

**Adopted as suggested.** The revision settles these the way the review proposed, and the implementation already worked that way or now does:
- `computer_*` tool names; `view`, `click`, and `full` tiers for every action in the canonical model, `menu` and `hold` at `full`.
- Geometry-bound images are never resized after capture; capture is sized to the tightest of the model's caps (long edge, pixel area, visual tokens) and the result pipeline's.
- The `computer-use` role needs tool calling and vision (or a bound `vision-describe`); the feature picks the native dialect when present.
- The vendor `intent` field is logged and shown as the model's claim, never input to classification or the intent check.
- Keep 3, prune every 15: the image cap wins. The pruned marker is a harness-written line, with no model call.
- `verify` counts as progress at the current step count, and "fresh" means captured after the last delivered action.
- Separate `timeCeilingAt`, deadline, and grant expiry, with `endsAt` derived; time limits start when the lease is granted.
- Labels may raise an action's class, never lower it; capture filtering meets the exclusion rule.
- The specialist's result is treated as untrusted in the parent, and validated against `returnSchema`.
- `click` on a DOM ref is a trusted pointer click; `press` is DOM activation.
- Images stay in the ephemeral lane; a crash can't make them durable.
- A native toolset may need another API than the provider's default, recorded on the feature.
- Consecutive failing batches stand in for "the same subgoal"; the observed app stands in for the frontmost one in the state digest.
- An explicit default-target rule; Android named as the phone case.
- Gaps filled as the implementation had filled them: initiator and presence on leases, the `ReleaseReason` list, refusals counting toward the no-progress window, a missing-grant field, the scratchpad, the grounder's JSON answer, labeled-screenshot selection, harness lines outside the envelope, refused unknown arguments, oversight going to the root conversation, stop declining pending requests, observers paused during takeover, replays rediscovered from the transcript, and display host versioning, liveness, and host-to-client events.

**Adopted differently.** The revision chose another answer than the review or the implementation had. The implementation was changed to match:

| Topic | The review or implementation had | The revision chose |
|---|---|---|
| Approval-card image block | Inline data plus alt text | A blob `ref` with required `alt` and optional `mime`; surfaces fetch the blob |
| `humanPresence` | `shared` or `none` | `shared` or `exclusive`, and the host-target rules apply to every shared target, phones included |
| A launched browser's isolation | `container`, explained | A new `process` value: isolated for data, not for network |
| Desktop browsers | Capped at `view`, so they couldn't be launched | Browser controls follow the app grant up to `click`; pages follow domain grants; `open-url` needs a browser granted at `click` |
| Typing then Return | Name it as a gap, or make Return after typing consequential | Return is classified as the control it triggers (the form's submit, the window's default button) |
| Ceiling question | `ask_user`, parsing a yes | A continue-or-stop approval card; a timeout stops |
| Stop key | Escape, configurable | A dedicated chord (⌃⌥⌘. here), since the agent needs Escape |
| Watch mode viewers | The user's viewers only | Any open live-view connection |
| Watch mode without a live view | The session ends | A present user confirms on a card |
| Foreground delivery on macOS | Foreground for every action when the lease allows it | Background first; foreground only for known-hostile app classes, or after a background action came back `suspected-noop` |
| Unanswered question or handoff | The user unavailable or the handoff declined; handoffs time out at 30 minutes | The session ends `needs-user`; handoffs time out at 15 minutes |
| Repeated failure | Escalate at every third failing batch | Escalate once; the answer resets the count; failing again before progress is `no-progress` |
| Audit retention | Held until unmarked by default | A fixed length, 30 days by default |
| Image retention | One expiry per blob, moved at release | A reference per holder with its own expiry; the session's moves with the time ceiling |
| Diffs | Session-stable refs, used as the diff's key | Refs stay per observation; a separate stable key. The implementation keeps session-stable refs as that key (see the notes) |
| Live-view links | Reusable until they expire | Single-use for connecting, with per-connection revocation |
| Takeover input | Every one of the user's links | Only the session of the user who started the takeover. Takeover starts from the oversight surface here, so this is read as the user's own links (see the notes) |
| Remote delegate needing input | Idle, since nobody could answer | Paused, not idle |
| Desktop scripts | Browser targets only | Allowed through mechanisms whose target app the harness validates; none is built yet |
| Vendor-stored conversations | Acknowledge it | Record `dataRetention: "vendor-stored"`, offer a stateless mode, and exclude such bindings under zero retention |
| Text-only tool results | Images in the next user message | The same, plus a marker in the tool result, and a preference for an API whose tool results hold images |
| Desktop container network | No network by default | A network policy enforced at the namespace and its egress filter |

**Still open.** The revision leaves these to the implementation, or the implementation hasn't built them yet:
- Egress filtering for desktop containers and VMs: containers stay without a network unless the operator acknowledges an unfiltered one.
- OpenAI's stateless mode: it needs each turn's encrypted reasoning items, which the conversation doesn't carry.
- A mode requiring confirmation on Interact.
- How a surface fetches an approval image's blob, how a reattaching client proves it holds the lease, and how window conditions in `wait-for` are evaluated without window titles. The implementation's answers are in the notes.

## Verdicts

| Verdict | Meaning | Rows |
|---|---|---|
| Contradiction | Two spec statements, on one page or across pages, can't both hold | 15 |
| Design problem | The rule can be built, but as written it is unsafe or wrong in a case the spec doesn't consider | 6 |
| Not implementable as written | The rule depends on something the harness can't observe or compute | 8 |
| Gap | The spec is silent on a behavior an implementer has to choose | 34 |
| Ambiguous | The spec says something with more than one reasonable reading, or uses an undefined term | 21 |
| Not a spec issue | Forced by Swift, this harness, or a vendor or platform, or a scope choice | 22 |

84 of the 106 rows point at something the spec could improve. Most of those are gaps and ambiguities, the expected cost of a design-level spec. The contradictions, design problems, and unimplementable rules are the ones worth fixing first; each would trip any implementer, not just this one.

## Recommended changes, most important first

### Contradictions

1. **Tool results may resize screenshots; computer use forbids it.** `core/tool-system/result-formatting.md` § Image sanitization says to "enforce provider caps by transformation", downscaling oversized images. `backends/computer-use/README.md` § Coordinate contract maps every model coordinate through the geometry recorded at capture, and its anti-patterns call silent resizing a coordinate break. If the sanitizer downscales a screenshot, every click lands wrong without an error. **Suggest:** result-formatting exempts images whose geometry is bound to later input, and replaces an oversized one with its marker instead of resizing it. Computer use then sizes captures to the pipeline's own cap as well as the model's.

2. **`view` tier versus Navigate actions.** § Sessions defines `view` as "the app appears in observations only". § Permission classification lets Navigate actions (`scroll`, `move`, `launch`) run "within grant", which reads as allowed at `view`. **Suggest:** say which tier Navigate needs (the implementation uses `click`), or redefine `view` to include them.

3. **The classification table is incomplete.** It never classifies `drag`, `pointer`, `hold`, `menu`, or `wait-for`. Every action in the canonical model needs a class and a minimum tier. A `menu` walk reaches the same commands as shortcuts, so it plausibly needs `full`.

4. **The `computer-use` role excludes the function-tool path.** `core/model-pool/model-classes.md` binds the role to "generate + `computer-use` feature", falling back to `main` "if it has the feature". The computer-use README's dialect table offers harness function tools to models without a native toolset. Read together, a model without the feature can never be the specialist. **Suggest:** the role requires tool calling and vision, or a bound `vision-describe`. The feature, when present, picks the dialect.

5. **The vendor `intent` field and the intent check.** § Permission classification says the vendor `intent` field "is input to the intent check". § Safety layer 4 limits the check's input to the user's request, prior actions, and harness-derived identifiers, and says classification never uses "the model's own claim". A per-action intent written by a possibly steered model is exactly such a claim. **Suggest:** pick one. Leaving the field out of the check is the safer reading, and is what the implementation does.

6. **Retention guidance against the image cap.** § Context budget gives "keep 3, prune every ~25" and also says to keep requests under ~20 images. With those numbers a request can hold 28. **Suggest:** keep 3, prune every 15, or state that the image cap wins.

7. **Approval cards need an image block the vocabulary lacks.** § Oversight surfaces requires "a cropped image of the target region" on approval cards. `surfaces/interface/README.md` defines the portable vocabulary as text, context, divider, buttons, and select, and `approval-ux.md` builds cards from it. **Suggest:** add an `image` block (data plus alt text) with core-owned degradation to the alt text.

8. **Tool names `computer.*`.** Anthropic and OpenAI accept only `^[a-zA-Z0-9_-]{1,64}$` as tool names, so the dotted family name can't be sent. **Suggest:** name the family `computer_*`, or say the dotted form is notional.

9. **Progress from `verify` versus the definition of a step.** § What counts as progress decides progress per step, and § Budgets defines a step as "one action delivered to the driver". `verify` is never delivered to a driver, so a step can't be "a `verify` call". **Suggest:** say a verified criterion counts as progress at the current step count.

10. **`ResolvedBudgets.endsAt` can't be extended correctly.** It is the earliest of start + `maxDuration`, the deadline, and the grant expiry. § Extensions lets a present user extend the time ceiling, but never the deadline or the grant expiry. Once they are folded into one value, an extension can't tell which limit it is moving. **Suggest:** keep the three limits as separate fields and derive `endsAt` from them.

11. **Keep VNC for observers, yet links must be view-only.** § Display targets and `macos.md` § Isolation say to keep VNC for the human observer. § Display targets also requires observer links to be view-only by default, with input only during takeover. A standard VNC server (Tart's, a container's) can't be held to view-only outside takeover without a proxy. **Suggest:** allow an authenticated stream as the observer channel, or require a view-only-enforcing VNC proxy.

12. **"Same registry" versus "sibling, not extension".** § How this fits says display targets register in the execution-environments backend registry and reuse its lifecycle, pruning, and observer-token machinery, while being "a sibling of `SandboxBackendHandle`, not an extension of it". That registry is keyed by `SandboxBackendFactory`, its pruning applies only to persistent runtimes (which per-lease targets aren't), and its observer tokens are rules for noVNC rather than machinery. **Suggest:** say concretely what is shared: an id namespace, lifecycle hooks, a token issuer.

13. **Hiding windows versus filtering capture.** README § Sessions says to hide non-granted windows during the agent's turn. `macos.md` § Perception filters capture to the allowed apps. On a shared desktop, hiding the user's windows is disruptive, and filtering achieves the same protection. **Suggest:** accept capture filtering as meeting the rule.

14. **Labels in classification.** § Permission classification computes the class from the element's role, label, app, and URL. Safety layer 4 calls on-screen labels attacker-controllable. An attacker can relabel a destructive button to avoid confirmation. **Suggest:** labels may raise an action to consequential, never lower it.

15. **The managed browser's isolation value.** The target table gives a local Chromium `container / remote`. A launched browser is a separate process with a throwaway profile, not an OS container, and the `isolation` vocabulary has no value for that. **Suggest:** add one, or say that "no user data, nobody else using it" is what `container` means for policy.

### Design problems

1. **The specialist's result is not an injection firebreak.** § The computer-use sub-agent calls the structured result an injection firebreak. But `result` and `evidence` are model-written text from a context full of untrusted screen content, and can carry injected instructions to the parent verbatim. **Suggest:** treat those fields as untrusted content in the parent, with the provenance envelope, or validate them against `returnSchema` and say what that buys.

2. **Desktop scripts and per-app grants.** § Model dialects says code execution runs "under the same grants and domain policy", and names desktop input-automation libraries as one kind of script. A desktop script (AppleScript, shell-driven input) can reach any app, so per-app grants can't hold it. **Suggest:** limit scripts to browser targets, or say a desktop script needs a grant that covers every app.

3. **Click on a ref as `press`.** The canonical model lets a driver implement `click` on a ref as `press`, and defines `press` as "DOM click" for browsers. A DOM `click()` is an untrusted event that some pages ignore, so in a browser the two aren't interchangeable. **Suggest:** for DOM targets, `click` is a trusted pointer click at the element's live center.

4. **The durable image lane.** § Recording keeps observation images "in the durable lane while anything references them", with an ephemeral TTL after release. With content-addressed blobs this goes wrong two ways. A crash before release leaves images durable forever. And a later retention change can't shorten a durable copy that someone else holds under the same hash. **Suggest:** keep them in the ephemeral lane with an expiry past the lease's hard limit, and move the expiry at release.

5. **Vendors that keep the conversation.** Screenshot pruning (§ Context budget) assumes the harness owns the context it sends. OpenAI's and Gemini's computer-use APIs continue a turn from a response stored with the vendor, because each call depends on reasoning state the client never sees. The vendor then keeps every screenshot: pruning can't shrink it, and data retention is the vendor's. **Suggest:** acknowledge it and require the trade-off to be visible to users who need zero retention.

6. **Typing then Return.** Typing into a form and pressing Return submits it without a consequential label ever being seen, so harness-derived classification can't detect it. The spec doesn't address it. **Suggest:** name it as a known gap covered only by the intent check, or treat Return after typing into a form field as consequential.

### Not implementable as written

1. **"Same subgoal" failures.** § Ending a session escalates after "2–3 consecutive failed attempts at the same subgoal". The harness doesn't know subgoals. **Suggest:** consecutive failing batches.
2. **The state fingerprint's frontmost app.** On the host desktop the frontmost app is usually the harness itself, since the user just typed the request there, and its window is never observed. **Suggest:** the observed app. Also the fingerprint wants "element roles and depth", but `ElementRef` carries no depth or focus.
3. **Foreground escalation.** `macos.md` § Delivery ladder escalates to foreground delivery when background delivery fails. Background delivery often fails silently, so nothing triggers the escalation. **Suggest:** say whether foreground is used up front when the lease allows it, or which evidence triggers escalation.
4. **`wait-for(condition)`.** The condition is natural language that no driver can evaluate. **Suggest:** a small condition grammar (element appears, URL matches, …) or say it is a bounded wait followed by an observe.
5. **One-line summaries of pruned screenshots.** Describing what a screenshot showed needs a model call per prune. **Suggest:** the harness-written header line (observation id, app, window) is enough.
6. **The default target.** "The most isolated one that can do the job" can't be computed from a task's arguments. **Suggest:** an explicit rule, such as a browser target for tasks that grant domains and no apps.
7. **iPhones as paired devices.** An iPhone has no host-side automation channel without a developer tool chain on the device. **Suggest:** name Android as the phone case, or say what an iPhone driver needs.
8. **Watch mode on a target without a live view.** § Safety layer 5 says a sensitive-domain session "continues only while a live view is open". The host desktop serves none (it is the user's screen), so a sensitive-domain signal there must end the session. **Suggest:** say whether the user's presence at the host desktop counts as watching.

### Gaps

The spec is silent on these, and each implementation will choose differently. Grouped by area; the full table below has every row.

- **Leases and budgets:**
  - `LeaseRequest` needs who initiated the work and whether a user is present. The non-operator, host-target, and unattended-expiry rules all depend on both, and neither is in the type.
  - The size of a time extension.
  - The full `humanPresence` vocabulary (the example shows only `shared`).
  - `ReleaseReason` values, and how each terminal reason maps to one.
- **Progress and failure:**
  - Refused actions aren't steps, so a session refused at every turn never fills the no-progress window. And after the user answers the failure escalation, nothing ends the loop.
  - `ComputerUseResult` has no way to report a grant the task needed.
- **The specialist:**
  - What the scratchpad is.
  - The `grounder`'s answer format.
  - Which elements to tag on labeled screenshots.
  - How a result that mixes harness guidance and screen text is enveloped.
  - What happens to delegate arguments outside the schema.
- **Images on the wire:**
  - The image cap needs a pixel-area limit (`maxPixels`). Anthropic rejects images over about 1.15 MP, which the long-edge and visual-token caps don't bound.
  - What "an image block in the vendor's format" means for a vendor whose tool results can't hold images (chat completions).
  - A native toolset may need a different API than the provider's default (OpenAI's computer tool exists only on the Responses API).
- **Diffs:** they need refs that are stable across observations, while `macos.md` says an element id "is valid only with its observation". The diff format is unspecified.
- **Browsers:**
  - Which parts of a desktop browser are the page.
  - Whether a granted browser exposes pages on non-granted domains (it does: a privacy gap worth a sentence in the grant dialog rules).
  - Dialogs, popups, and downloads.
  - Sharing the user's real browser: which tabs the agent sees, and its downloads.
- **Desktop focus:** which app input with no target reaches when the frontmost app isn't granted. On the host desktop that is the usual case.
- **Oversight:**
  - Which conversation a delegated specialist's cards and questions go to.
  - Timeouts for questions and handoffs.
  - Whether stop also declines pending questions.
  - What observers see during takeover.
  - How observer links are revoked.
  - How the user acts inside an isolated target during takeover.
  - How long audit-marked runs are kept.
  - How replays are found later.
- **Display host:**
  - The `CUHostProtocol` format and versioning.
  - Holder liveness across a process boundary.
  - How the host's stop key reaches the harness (it needs host-to-client events).
- **Containers:** network policy is written for browser targets only, so a desktop container's network is unaddressed.
- **Tool System interplay:** a mode with an approve-everything policy double-gates computer actions.

### Ambiguities

- **`endsAt` "start":** the session's start, or the lease's, after the grant dialog closes?
- **The ceiling question:** asked "through `ask_user`", which returns free text, so a yes needs parsing.
- **The stop key:** the example implies Escape. Reserving it also stops the agent dismissing dialogs with Escape, a cost the spec should state.
- **`open-url`:** "opened in a granted browser target" is unclear on the host desktop. And with browsers capped at `view`, one can't be launched.
- **A "fresh observation" for `verify`.**
- **Images:** what "references" hold an image (two of the three listed end with the lease anyway), and whether `returnSchema` is validated.
- **Constraint re-injection:** the mechanism, whether every result or the system prompt.
- **Secrets:** what counts as a "secret" for URL blocking and redaction.
- **Per-call safety checks:** a vendor's check that belongs to a whole batch, under a rule that confirms per action.
- **Signals on observations:** a safety signal on an observe-class action. The class says allow, the signal says confirm.
- **Deferred loading:** vendor field names (`defer_loading`) appear beside harness registry fields, and in the parent the delegate is the thing deferred.
- **The host app:** the spec ships `ComputerUseHost.app` "as part of the kit" and calls in-process mode a dev escape hatch. A GUI app that embeds the harness is itself the responsible process.
- **The managed browser's network:** the "target's network" boundary for a local browser process, "private network", and how domain allow and block lists relate to domain grants.
- **Ref drift:** the frame tolerance is written for AX trees, and DOM elements move when scrolled.
- **Observer links:**
  - "Short-lived" tokens against a stream that stays open.
  - Who may type during takeover.
- **Paired devices:** whether the host-target rule applies to a phone that someone uses.

## Every row

| Section | Topic | Verdict | Note for the spec team |
|---|---|---|---|
| Contract | Tool names | Contradiction | Dotted names are invalid for Anthropic and OpenAI. |
| Contract | Type name | Not a spec issue | Swift's `Observation` module collides with the name. |
| Contract | `LeaseRequest` fields | Gap | Add initiator and presence; three rules depend on them. |
| Contract | Budget field names | Contradiction | One `endsAt` can't carry three limits with different extension rules. |
| Contract | When `endsAt` is fixed | Ambiguous | Say whether "start" is before or after the grant dialog. |
| Contract | Progress from verification | Contradiction | `verify` isn't a step under the spec's own definition. |
| Contract | State digest details | Not implementable as written | The frontmost app is the harness on the host desktop; elements carry no depth. |
| Contract | Time extension size | Gap | Size it. |
| Contract | Ceiling question | Ambiguous | `ask_user` is free text; the question is yes or no. |
| Contract | Release reasons | Gap | List `ReleaseReason` values and map terminal reasons to them. |
| Contract | Idle timeout events | Not a spec issue | This harness's in-process delegates emit no `DelegateEvent`; the spec says all adapters do. One small gap: is an A2A `input-required` delegate idle or paused? |
| Contract | `humanPresence` values | Gap | Enumerate them. |
| Contract | Registry | Contradiction | "Same registry" against "sibling, not extension"; say what is shared. |
| Grants | Tier for navigate actions | Contradiction | `view` is "observations only", but Navigate is "allow within grant". |
| Grants | Menus | Gap | The classification table omits `menu`, `drag`, `pointer`, `hold`, and `wait-for`. |
| Grants | Category rules | Gap | Say when category checks run; grant time knows only bundle ids. |
| Grants | Labels in classification | Contradiction | Labels are attacker-controllable; they may only raise the class. |
| Grants | Keyboard-submitted forms | Design problem | Type then Return submits unseen; name it or classify it. |
| Grants | Stop key | Ambiguous | Name the key and its cost: the agent loses Escape. |
| Grants | Browser launch | Ambiguous | `open-url` "in a granted browser target" on the host desktop; browsers capped at `view` can't be launched. |
| Grants | Browser controls and pages | Gap | Say which parts of a desktop browser are the page. |
| Grants | What a browser grant shows | Gap | A granted browser exposes pages on non-granted domains. |
| Grants | Working app on a shared desktop | Gap | Say where untargeted input goes when the frontmost app isn't granted. |
| Session | "Same subgoal" failures | Not implementable as written | Subgoals aren't observable; use consecutive failing batches. |
| Session | Refusals and the no-progress window | Gap | Refusals aren't steps; nothing ends a refusal loop after the user answers. |
| Session | Missing grants | Gap | Let a result report the grants a task needed. |
| Session | Unknown delegate arguments | Gap | Minor; probably a Tool System rule. |
| Session | Per-call timeout | Not a spec issue | The timeout is this harness's. Worth one line: tools that wait on the user shouldn't be cut off by a per-call timeout. |
| Session | Fresh observation for `verify` | Ambiguous | Define "fresh". |
| Session | Mixed tool results | Gap | Say how mixed harness and screen text is enveloped. |
| Session | Approval surface | Not a spec issue | A naming detail of this harness. |
| Session | Image retention lane | Design problem | The durable lane can't be shortened under content addressing, and crashes leave images durable. |
| Session | Tool images as attachments | Not a spec issue | This harness's attachment promotion. |
| Session | References the spec lists | Ambiguous | Two of the three references end with the lease. |
| Session | Retention defaults | Contradiction | Keep 3, prune ~25 allows 28 images, over the ~20 cap. |
| Session | Pruned screenshot summary | Not implementable as written | A one-line summary of pixels needs a model call; allow the header line. |
| Session | Catalog values | Not a spec issue | Vendor data. |
| Session | Pixel-area cap | Gap | `maxImage` needs `maxPixels`. |
| Session | Pipeline cap | Contradiction | Result formatting resizes images that computer use must not resize. |
| Session | `computer-use` role | Contradiction | Model Pool requires the feature; the README's function-tool path doesn't. |
| Session | Constraint re-injection | Ambiguous | Say how constraints reach every step. |
| Session | Specialist scratchpad | Gap | Define it. |
| Session | Binding `vision-describe` and `grounder` | Not a spec issue | This harness's role pipeline is decide-only. |
| Session | `vision-describe` scope | Not a spec issue | A scope choice. |
| Session | `grounder` answers | Gap | Define the output format. |
| Session | Labeled screenshots | Gap | Say which elements get tags. |
| Session | Return schema | Ambiguous | Validate or not, and what a mismatch does. |
| Session | Specialist delivery | Not a spec issue | A scope choice (synchronous runs). |
| Session | Specialist result trust | Design problem | `result` and `evidence` are model text shaped by untrusted content. |
| Session | OpenAI-style tool images | Gap | Say what to do when a vendor's tool results can't hold images. |
| Session | macOS `wait-for` | Not implementable as written | A natural-language condition no driver can evaluate. |
| Session | macOS window exclusion | Contradiction | README hides windows; `macos.md` filters capture. Accept filtering. |
| Session | macOS foreground delivery | Not implementable as written | Background failures are silent, so they can't trigger escalation. |
| Session | macOS keyboard layout | Not a spec issue | The spec already covers keycodes versus Unicode typing. |
| Session | Oversight routing | Gap | Say which conversation a specialist's cards go to. |
| Session | Question and handoff timeouts | Gap | Give defaults. |
| Session | Stop and pending requests | Gap | Say whether stop declines pending questions. |
| Session | Surface capability | Not a spec issue | This harness's capability flag. |
| Session | Replay index | Gap | Say how replays are found later. |
| Session | Replay thumbnails | Not a spec issue | An implementation detail. |
| Session | Audit retention | Gap | Give a length or say it is indefinite. |
| Session | Audit marks after a restart | Not a spec issue | An implementation detail. |
| Session | HUD placement | Ambiguous | The HUD lives in the host app; say where it goes in-process. |
| Session | Image block | Contradiction | Approval cards need an image; the presentation vocabulary has none. |
| Session | Terminal crops | Not a spec issue | A surface limit; core degradation covers it. |
| Session | Terminal controls | Not a spec issue | Keys are rightly left to surfaces. |
| Session | Tree diffs | Gap | Diffs need refs stable across observations; give a format. |
| Session | Secret detection | Ambiguous | Define "secret". |
| Session | Native toolset scope | Not a spec issue | Records which vendors are built. |
| Session | OpenAI's API | Gap | A native toolset may need a different API than the provider's default. |
| Session | OpenAI safety checks | Ambiguous | Batch-level signals under a per-action confirmation rule. |
| Session | Gemini's API | Not a spec issue | Vendor churn. |
| Session | Gemini actions | Contradiction | Vendor `intent` as intent-check input conflicts with harness-derived inputs only. |
| Session | Stored responses | Design problem | Vendors that keep the conversation defeat pruning and own retention. |
| Session | Signals with no action | Ambiguous | Signal versus observe class precedence. |
| Session | Native screenshots | Not a spec issue | An implementation detail. |
| Session | Native details | Not a spec issue | Vendor key names and platform limits. |
| Session | Deferred loading mechanism | Ambiguous | Vendor and harness fields are mixed. |
| Session | What is deferred | Ambiguous | In the parent, the delegate is what is deferred. |
| Session | Tool-level approval | Gap | Say how computer-use gating combines with mode approval policies. |
| Display host | No bundled host app | Ambiguous | A GUI app embedding the harness is its own responsible process. |
| Display host | Transport | Not a spec issue | A platform-API choice in this implementation. |
| Display host | `CUHostProtocol` shape | Gap | Give a format and version rule. |
| Display host | Holder liveness across a host | Gap | Liveness can't cross a process boundary as a closure. |
| Display host | Stop from the host | Gap | The protocol needs host-to-client events. |
| Display host | Live view and observer tokens | Not a spec issue | A pass-through choice. |
| Managed browser | Isolation of a launched browser | Contradiction | A local Chromium isn't a container; the vocabulary lacks a value. |
| Managed browser | Network boundary | Ambiguous | "The target's network" for a local process. |
| Managed browser | What "private" means | Ambiguous | Define private network. |
| Managed browser | Domain lists and grants | Ambiguous | Relate the policy lists to domain grants. |
| Managed browser | Ref drift | Ambiguous | Frame tolerance doesn't fit scrolled DOM elements. |
| Managed browser | Click on a ref | Design problem | DOM `click()` is untrusted; click and press differ in browsers. |
| Managed browser | Dialogs, popups, and downloads | Gap | Say how each is handled. |
| Managed browser | Default target | Not implementable as written | "Most isolated that can do the job" isn't computable from task arguments. |
| Managed browser | Live view transport | Not a spec issue | The spec allows a stream. |
| Managed browser | Observer tokens | Ambiguous | "Short-lived" against an open stream. |
| Managed browser | View-only and takeover | Ambiguous | Say who may type during takeover. |
| Managed browser | Observers during takeover | Gap | Say what observers see while capture is suspended. |
| Managed browser | Ending observers | Gap | Add revocation. |
| Managed browser | Paired devices | Not implementable as written | iPhones can't be driven this way; also say whether the host-target rule covers a phone. |
| Managed browser | Local VMs | Contradiction | VNC for observers can't be held to view-only. |
| Managed browser | Desktop container | Contradiction | The same VNC problem. Also a gap: container network policy. |
| Managed browser | The user's real browser | Gap | Say how the agent shares the browser: tabs and downloads. |
| Managed browser | Code execution as a peer path | Design problem | Desktop scripts can't be held to per-app grants. |
| Managed browser | Watch mode | Not implementable as written | Targets without a live view can't be watched. Also define "open". |
| Managed browser | Input during takeover | Gap | Say how the user acts inside an isolated target. |
