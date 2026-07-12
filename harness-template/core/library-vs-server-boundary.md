# The Library-vs-Server Boundary in Practice

> The [core README](./README.md) asserts a clean split: the inner ring is library-shaped, and the Communication Layer is the only component that talks to the outside world. This page is about what that assertion costs to keep true — and what happens to harnesses that start library-shaped and bolt a server on later.

## TL;DR

Design **server-shaped contracts from day one**, even if you ship library-shaped for months. The expensive part of the library→server migration is not the socket — it's the inventory of **state that was implicit in the library case**: object references standing in for addressable resources, blocking stdin prompts standing in for an approval lifecycle, process lifetime standing in for persistence, ambient `cwd`/env standing in for workspace identity, Ctrl-C standing in for cancellation. Each of these is invisible while caller and harness share a process, and each becomes a rewrite the day they don't. The mitigations are cheap at design time and brutal at retrofit time: address resources by id, publish events in envelopes, make every layer boundary async and serializable, and run the CLI as a client of an in-memory transport rather than a caller of the inner ring. Then "adding the server" is configuration, not migration.

## Why this deserves its own page

Almost every harness starts as a CLI: one process, one user, one conversation at a time. The inner ring's layers exist as modules; the "client" calls them directly. This is a perfectly good way to ship v1 — and it silently accumulates assumptions that only hold while the caller and the harness share an address space.

Then a second surface arrives — a web UI, a mobile app, a channel adapter, a trigger — and the team discovers that "expose the loop over a socket" is not a feature but an excavation. The interesting question is not *whether* to have a server (the [Communication Layer](./communication-layer/README.md) page covers the wire itself) but *which library-era decisions make the server cheap or catastrophic to add*.

## The two starting shapes

**Library-first.** The harness is a package; the CLI (or host app) imports it and calls layer APIs directly. Fast to build, trivial to debug, zero deployment story. Every assumption below is available to be made accidentally.

**Server-first.** Everything is behind the wire from day one; even the local CLI speaks the protocol. Honest, but front-loads ceremony the solo case doesn't need — and teams under pressure route around ceremony, which is worse than not having it.

The recommendation is a third shape: **library-shaped deployment, server-shaped contracts.** The code runs in one process, but the boundaries inside it are already wire-safe. Embedded mode (the in-memory transport described in [communication-layer § Embedded mode](./communication-layer/README.md)) is the mechanism that makes this real rather than aspirational: the CLI is a *client*, it just happens to be a client whose transport is a channel instead of a socket.

## The inventory: implicit library state

This is the meat of the page. Each row is something the library case gets for free from shared process state, and what the server case needs instead. Use it as a checklist: any row where your harness relies on the left column is a scheduled migration cost.

| Implicit in the library case | Required on the wire | Owned by |
|---|---|---|
| Caller holds a live conversation *object* with methods | Conversation addressed by **id**; operations are requests against it | [Conversation Manager](./conversation-manager/README.md) |
| Conversation state lives in memory, dies with the process | Durable transcript + catalog; conversation outlives any process or client | [Persistence](../backends/persistence/README.md) |
| Streaming = the caller iterates an async sequence | Event **envelopes** with per-topic seq, replay window, backpressure rules | [Communication Layer](./communication-layer/README.md) |
| Approval = block on stdin until the user types y/n | Approval as a first-class lifecycle: request, route to attached clients, dedupe, expire, survive reconnect | [Tool System permissions](./tool-system/permissions.md), [approval UX](../surfaces/interface/approval-ux.md) |
| Cancellation = Ctrl-C / process signal | Explicit cancel operation, propagated through Pools and sub-agent transports | [Agent Runtime](./agent-runtime/README.md), the three Pools |
| Identity = whoever ran the process | Authentication at connection, authorization per topic / per resource | Communication Layer |
| Workspace = ambient `cwd` and env vars | Workspace as an explicit, recorded property of the conversation | [Execution environments](../backends/execution-environments/README.md) |
| Errors = exceptions unwinding to the caller | Typed error envelopes that serialize and correlate to a request | Communication Layer schema |
| Config = objects passed into constructors | Config as inspectable resources (registries, capability queries) | The three Pools |
| One consumer, always caught up | Many consumers on flaky networks: reconcile-and-watch, lagging, re-snapshot | Communication Layer |
| Triggers = the host app calls a function on its own schedule | Trigger ingestion as a trust-classified input envelope at the wire | [Triggers](../surfaces/triggers/README.md) |
| "Current turn" state in local variables | Run as an addressable record derived from the transcript | [Conversation Manager runs](./conversation-manager/runs.md) |

Three of these deserve expansion, because they're the ones that most often force rewrites rather than refactors.

### Object references vs addressable resources

The library-era signature `let conversation = harness.createConversation()` returning an object with `send()`, `on()`, `cancel()` methods is the single most expensive habit to unwind. Every method on that object is a hidden RPC that was never designed as one; every closure the caller registers is a callback that can't cross a wire; the object's identity *is* its address, so nothing else can ever attach to the same conversation. The server-shaped version costs one level of indirection — `harness.conversations.append(id, input)` — and buys the entire multi-client story: two clients holding the same id are automatically attached to the same conversation, because the id is the address and the state lives behind it. This is the [README's](./README.md) "conversation is the unit of addressability, not the connection" commitment, applied at the *library* API surface, before any wire exists.

### Blocking prompts vs approval lifecycle

A library-shaped permission gate blocks the tool dispatch thread on user input. That design encodes four assumptions at once: there is exactly one client, it is attached right now, it can answer synchronously, and nothing else needs to proceed meanwhile. All four are false on the wire. The migration isn't "send the prompt over the socket" — it's introducing an approval *record* with its own lifecycle (pending → resolved/expired), routing to whichever clients are attached, deduplication when the same approval is re-requested, and a policy for what happens when no client is attached at all. That's a subsystem, not a transport change, which is why it's worth building the record-shaped version even when its only consumer is a terminal prompt.

### Ambient environment vs workspace identity

In a single process, tools resolve relative paths against `cwd`, read env vars, and write files wherever the process happens to be. None of that is *recorded* — it's ambient. The moment a conversation can be resumed from another process (or another machine), the ambient environment is gone, and any tool result that depended on it is unreproducible. The fix is workspace canonicality (per [execution environments](../backends/execution-environments/README.md)): the workspace is an explicit property of the conversation, recorded at creation, and every path in every tool result is resolved against it. Library-first harnesses that skip this discover it as data corruption — transcripts full of paths that mean nothing outside the original process.

## The migration path, staged

For a harness that already exists in library shape, the path to server-canonical runs through four stages. The ordering matters because each stage is the prerequisite that keeps the next one mechanical.

**Stage 1 — ids and events, still in-process.** Replace returned live objects with ids + operations; replace registered callbacks with published event envelopes on an in-process bus. No socket, no serialization, no persistence yet. This is the *hard* stage — it forces the implicit-state inventory above — and it's where the real design work happens. Everything after it is plumbing.

**Stage 2 — persistence.** Conversations outlive the process: transcript + catalog per [persistence](../backends/persistence/README.md). Now an id can be resolved after a restart, which is the property every later stage leans on.

**Stage 3 — the Comm Layer in front, CLI becomes a client.** Introduce the Communication Layer with the in-memory transport; move the CLI from calling layers to subscribing to topics and issuing requests. Same process, same binary, but now there is exactly one door, and the CLI walks through it. This stage is cheap *if* stage 1 was done — the envelopes already exist; the Comm Layer just routes them.

**Stage 4 — open the socket.** Real transport, authentication, per-topic authorization, replay windows sized for real networks. Multi-client attach falls out rather than being built.

The trap to name explicitly: **the stages look incremental, but the cost is front-loaded and the payoff is back-loaded.** Stage 1 delivers no user-visible feature — it's pure internal restructuring — which is why teams defer it, ship stages 2–4 against object-shaped APIs, and end up with the dual-runtime problem below. Budget stage 1 as the migration; treat 2–4 as its consequences.

## Alternatives

### Server-first from day one

Skip the library phase entirely; even local development runs client-against-daemon.

**When this works:** the team already knows multi-client is the product (a hosted service, a mobile-first product), or the harness is being extracted from an existing server codebase.

**Why not as default:** the solo-CLI case pays a daemon-management tax (lifecycle, ports, stale-process debugging) for clients it doesn't have yet, and the friction pushes contributors toward side-channel shortcuts. Embedded mode gives you the same contracts without the operational surface; prefer it until a real second client exists.

### Library-only, permanently

Some harnesses are SDKs by intent — the deliverable *is* the embeddable inner ring, and the host application owns all client concerns.

**When this works:** the harness is a component in someone else's product and will never own a surface.

**What still applies:** everything except stage 4. Ids-not-objects, event envelopes, explicit workspace, approval records — the host application benefits from every one of them, because the host has its own UI thread, its own persistence, its own multi-window story. "Library-only" is a deployment decision, not an excuse to re-couple the layers.

### Dual API: library surface and server surface, maintained side by side

Expose both `harness.conversations.append(...)` as a public library API *and* the wire protocol, as co-equal supported surfaces.

**Why to avoid it:** two public contracts over one implementation always drift — features land on the convenient surface first, semantics diverge in the gaps (does the library call emit the same events the wire does? does cancellation behave identically?), and every bugfix needs two verifications. The embedded-mode answer is strictly better: there is one contract (the protocol), and the "library API" is a generated client bound to the in-memory transport. One runtime, one semantics, two transports.

## Anti-patterns

- **Handing live objects across the boundary.** Conversation objects with methods, tool-result objects holding file handles, callback closures registered into layers. Every one is a future serialization failure. Ids, envelopes, and typed values only.
- **The "fast path" bypass.** The CLI keeps one direct call into the inner ring "because latency" after the Comm Layer exists. That path silently stops emitting events, skips authorization, and becomes the place where the two semantics diverge. In-process transport is fast enough; there is one door.
- **Blocking the dispatch thread on user input.** The stdin-shaped permission prompt, and its cousins: pausing the loop awaiting an interactive editor, or a confirmation dialog owned by a specific surface. Anything that blocks a turn on a *particular connected client* breaks the moment clients can detach.
- **Persisting stage 2 against object-shaped state.** Serializing the library's in-memory object graph (closures elided, handles dropped) instead of designing the transcript as the source of truth. The result is a save format that only the original process shape can load — persistence that can't survive the very migration it was supposed to enable.
- **Ambient environment in durable state.** Relative paths, env-var references, or host-specific absolute paths recorded into transcripts and memory. Resolve against the explicit workspace at write time; durable state must be readable from a process that shares nothing with the writer.
- **Two runtimes.** A "library mode" codepath and a "server mode" codepath that grew separately — different event ordering, different error shapes, approval working in one and not the other. The entire point of embedded-mode-as-in-process is that this fork never happens: same code paths, different transport.
- **Deferring stage 1 because it ships nothing.** The most common failure. The socket gets added against object-shaped APIs under deadline pressure, the wire wraps method calls one-to-one, and every implicit-state item in the inventory above surfaces as a production incident instead of a design task.

## References

- [core/README.md](./README.md) — the library-runnable inner ring assertion and server-with-typed-clients as canonical deployment
- [communication-layer/README.md](./communication-layer/README.md) — the wire itself; embedded mode as the single component that decides whether the boundary holds
- [conversation-manager/README.md](./conversation-manager/README.md) — conversation as first-class resource; [runs.md](./conversation-manager/runs.md) for run addressability
- [backends/persistence/README.md](../backends/persistence/README.md) — transcript + catalog as the durable source of truth
- [backends/execution-environments/README.md](../backends/execution-environments/README.md) — workspace canonicality
- [tool-system/permissions.md](./tool-system/permissions.md) and [surfaces/interface/approval-ux.md](../surfaces/interface/approval-ux.md) — the approval lifecycle that replaces blocking prompts
- [surfaces/triggers/README.md](../surfaces/triggers/README.md) — trigger ingestion as trust-classified wire input
