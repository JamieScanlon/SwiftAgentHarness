# Computer use: open feedback for the spec team

These are the spec issues still open after the November 2026 revision. Each one is a place where `harness-template/backends/computer-use/README.md`, `macos.md`, or a page they lean on is silent, ambiguous, or inconsistent, and the implementation had to choose. Each item gives the problem, what the implementation does, and a suggested change. Spec references are relative to `harness-template/`.

Features the implementation hasn't built yet are tracked in [COMPUTER_USE.md](COMPUTER_USE.md) under "Not built". They aren't spec issues.

## Inconsistent

### Window conditions in `wait-for` have nothing to evaluate against

`backends/computer-use/README.md` § The canonical action model gives `WaitCondition` a window case, `{ window: "appears" | "disappears"; app?; titleContains? }`. But `Observation` (§ Runtime contract) lists no windows and no titles, so a driver evaluating against fresh snapshots has nothing to compare. `macos.md` § Anti-patterns also calls window titles attacker-controlled screen content.

**Implementation:** a window condition becomes a bounded wait followed by an observation, and the evidence says so.

**Suggest:** add a window list to observations, with titles marked untrusted, or drop the window case from `WaitCondition`.

## Gaps

### How a surface fetches an approval image

`surfaces/interface/README.md` makes the `image` block a blob `ref` with required `alt`, and `approval-ux.md` puts a crop of the target on computer-use cards. Neither says how a surface turns the ref into bytes, or who may fetch it. Blobs belong to a conversation, and a surface may be a remote client.

**Implementation:** `GET /conversations/{id}/computer-use/images/{blobID}` serves an image that a live run of that conversation stored, and nothing else. Without a blob store, as for a session a host drives by hand, the ref is a `data:` URL.

**Suggest:** name the fetch route in the communication layer, scoped to the card's conversation, and allow `data:` refs where there is no blob store.

### How a reattaching client proves it holds the lease

`macos.md` § The host protocol keeps a lease for a short grace period after its connection drops, so the holder can reconnect. It doesn't say how the new connection proves it is the same holder. Without that, any client the host authenticates could adopt another client's lease during the grace period.

**Implementation:** each lease carries a reattach token, which is replaced on every reattach. Events for a lease whose connection is gone are dropped, not queued.

**Suggest:** specify the token, or another proof of holdership, in the lease response and the reattach request.

### Where a mode's computer-use policy lives

`backends/computer-use/README.md` § Permission classification per action lets a mode make computer use stricter: it can deny computer use, or require confirmation on Interact. `core/conversation-manager/modes.md` gives `ModeProfile` no field for the second, and doesn't say whose mode applies when a delegate starts a session.

**Implementation:**
- The setting is `subAgents.computerUse.confirmInteract`, placed in the Sub-Agent Pool's slice because the pool starts sessions.
- The mode of the conversation that delegates and the mode of the user's root conversation both apply, so a nested delegate in an ordinary mode doesn't escape a strict one.
- The mode is read once, when the session starts.
- Like `deny`, the setting only accumulates through `extends`.

**Suggest:** add the field to `modes.md`. Also say which conversations' modes apply to a nested delegate, and whether a mode change mid-session applies to a running session.

### Telling a browser's chrome from its page

§ Sessions, leases, grants, and tiers ("What a browser grant covers") splits a desktop browser into the chrome, which follows the app grant, and the page, which follows domain grants. It doesn't say how a driver decides which part an element or a point belongs to.

**Implementation:** an element is on the page when it carries a URL. A point is on the page when it lies in the observation's `pageBounds`. Anything else is chrome.

**Suggest:** state the rule, and add the page's bounds to the observation contract so drivers report them.

### When watch mode ends

§ Safety is layered, layer 5, puts a session in watch mode on a sensitive-domain signal. It doesn't say whether watch mode ends when the session leaves the flagged domain, or lasts for the rest of the session.

**Implementation:** watch mode lasts for the rest of the session, because the session can't tell when the vendor would stop flagging.

**Suggest:** state how long watch mode lasts.

## Ambiguous

### Who "the user who started the takeover" is

§ Display targets as an execution-environment family accepts takeover input only "from the session of the user who started the takeover". A takeover can start from the oversight surface rather than from a live-view connection, so no live-view session exists to bind it to.

**Implementation:** during takeover, every user link of the conversation carries input, and observer links never do. Each link connects once, and the user can revoke any one connection.

**Suggest:** say what the takeover is bound to: a live-view connection, the user's identity, or the surface that started it.

### What it means for a result to reference a download

§ Sessions, leases, grants, and tiers deletes a managed browser's lease-scoped downloads at release "unless the result references a file".

**Implementation:** a file counts as referenced when the result's text contains its name or path.

**Suggest:** give the result a structured field that names the files to keep, rather than matching text.

### Which targets outlive a lease

§ Display targets as an execution-environment family says "targets that outlive a lease (VMs, desktop containers, hosted browsers)" use the persistent-runtime lifecycle. Whether a VM or container outlives its lease is a deployment choice, not a property of the kind.

**Implementation:** VMs and desktop containers are started per lease and removed at release, and the next start sweeps any that a dead harness left behind. None enters pruning.

**Suggest:** describe the lifecycle by behavior, for example "targets kept between leases (a VM kept warm)", rather than by kind.

### A pending approval's image reference

§ Recording, audit, replay gives each holder of an observation image its own reference, and lists a pending approval among the holders. An approval ends with the lease, and the session's reference already lasts longer than the lease, so the approval's reference never extends an image's life.

**Implementation:** no separate reference is kept for approvals. Their crops are stored under the session's reference.

**Suggest:** drop the approval from the list of holders, or say when its reference would outlast the session's.
