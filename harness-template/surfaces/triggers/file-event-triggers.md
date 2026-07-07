# File-Event Triggers — Recommended Architecture

## TL;DR

A watched directory is two different things, and the page keeps them separate. As an **event queue**, a directory the harness fs-watches (`workspace/events/`) is the recommended **internal transport** between every trigger adapter and the activation pipeline: an adapter — cron, a webhook handler the agent wrote, a manual drop — writes a small JSON event file, the watcher picks it up within ~100ms and normalizes it into a [`Trigger`](./triggers.md#the-normalized-trigger-object). It makes the trigger queue *inspectable* (`ls workspace/events/`) and each event a *replayable artifact*. As a **configuration store**, a directory the harness walks at startup (the `HOOK.md` directories pattern) discovers handlers that respond to *other* events — that's config discovery, not trigger ingest, and the two must not be conflated.

The non-negotiable infrastructure for the queue pattern: **per-filename debounce** (editors fire 3–10 events per save), **watcher-error recovery** (the watch handle dies on volume/network/rename churn), **parse-retry with backoff** (a half-written file reads as invalid JSON), **rename-on-read** to avoid losing a re-write between read and delete, and **staleness rules decided per event type**. Critically, **the file pattern grants no trust by itself** — a file's trust comes from a sidecar, a directory convention, or registration metadata, never from the bare fact that it appeared on disk.

The event-queue pattern and the filesystem-as-configuration pattern are the two variants. This page sits under the architecture-level recommendation in [triggers.md](./triggers.md).

---

## Why this belongs in the harness

The filesystem is the lowest-common-denominator IPC mechanism: every language can write a file, every process can watch a directory, and the result is durable, inspectable, and replayable without a message broker. For a single-user assistant where the agent owns its own integrations, "write a program that drops an event file" is a dramatically simpler integration story than "stand up an HTTP server with HMAC routes." Even when you *do* run a real webhook server, routing validated events through a watched directory turns the in-flight trigger queue into something you can `ls`, `cat`, and re-fire by hand — which is worth a great deal during a 2am incident. The cost is a set of filesystem-specific failure modes (partial writes, watcher death, debounce, deletion races) that are easy to get wrong and that this page exists to get right.

---

## Recommendation

### Two patterns, kept distinct

| | Event queue (`workspace/events/`) | Configuration store (`HOOK.md` dirs) |
|---|---|---|
| **Purpose** | A *trigger* arrives as a dropped file | *Handlers* are discovered at load |
| **When read** | Continuously, on fs-watch | At startup + on directory change |
| **What it produces** | A `Trigger` per file | Registered handlers for *other* events |
| **Lifecycle** | File consumed/deleted after firing | File persists; defines behavior |
| **Reference** | `workspace/events/` watcher | `HOOK.md` discovery system |

They share a mechanism (watch a directory) and nothing else. The queue *is* a trigger source; the config store *configures responses to* triggers. Mixing them — treating a dropped `HOOK.md` as a fire, or a queued event as a handler registration — is a category error that produces confusing double-fires and phantom handlers.

### The event-queue pattern (recommended internal transport)

The watcher reads JSON event files of three types:

```ts
type ImmediateEvent = { type: "immediate"; channelId: string; text: string };
type OneShotEvent   = { type: "one-shot";  channelId: string; text: string; at: string };       // ISO 8601 + offset
type PeriodicEvent  = { type: "periodic";  channelId: string; text: string; schedule: string; timezone: string }; // cron + IANA tz
```

The three types map one-to-one onto the schedule kinds in [scheduling.md](./scheduling.md) (`immediate`≈fire-now, `one-shot`≈`at`, `periodic`≈`cron`) — the file is just a different *transport* for the same scheduling semantics. After execution, `immediate` and `one-shot` files are **deleted**; `periodic` files **persist** until explicitly removed, because they encode a standing schedule, not a single fire.

**Recommendation: use this directory as the internal seam between adapters and the activation pipeline, even when the originating event is an HTTP webhook.** A validated webhook route writes its event file here after passing the gate in [webhook-ingest.md](./webhook-ingest.md); the file becomes the audit-log artifact and the replay handle. The watcher is the in-process queue.

### Debounce per filename

A single editor save emits multiple filesystem events (write, rename, attribute change) — 3 to 10 is typical. Without debounce the trigger pipeline fires that many times for one logical drop. `mom` uses a **100ms per-filename debounce** (`DEBOUNCE_MS` in `events.ts`). Key the debounce on the *filename*, not the directory, so two unrelated event files landing in the same window still fire independently.

### Watcher-error recovery

`fs.watch` handles die — on volume unmount/remount, on network filesystems, on editors that rename-and-replace rather than write-in-place. A dead watcher silently stops delivering events, which presents as "the agent stopped responding to drops" with no error. `watchWithErrorHandler` wraps `watch()` so a thrown error or an `error` event triggers `onError`, and the caller closes and re-opens the watcher after `FS_WATCH_RETRY_DELAY_MS` (5s). This is required infrastructure, not a nicety — a long-running watcher *will* hit one of these conditions.

### Parse-retry with backoff

Some programs (and some editors) write a file in two stages, so an early read sees a truncated, invalid-JSON file. Don't drop it on first parse failure: retry with exponential backoff — `mom`'s pattern is **100ms → 200ms → 400ms**, then log and skip after max retries. A skip must not block the rest of the queue; one malformed file should never wedge the watcher.

### Rename-on-read to avoid the deletion race

The naïve consume sequence — read file, execute, delete file — has a hole: a re-write from the producing program that lands *between* read and delete is silently lost when the delete fires. **Mitigation: rename the file on read (atomic on a single volume), then process the renamed file and delete the renamed copy.** A re-write of the original name after the rename is a *new* event, correctly preserved. This is easy to get wrong by reaching for "read then delete," so it's called out explicitly.

### Staleness rules, decided per event type

On startup the harness finds files that were dropped while it was *not* running. The right action differs by type, because each type encodes different intent about catch-up (mirroring [scheduling.md § Missed-fire behavior](./scheduling.md#missed-fire-behavior-decide-per-schedule-kind)):

- **`immediate`:** compare file mtime against harness start time. If the file predates startup, it's stale — **delete without executing**. An "immediate" event that's hours old is not immediate anymore.
- **`one-shot`:** if `at` is in the past, **fire late** (the reminder is still wanted); if `at` is in the future, schedule a `setTimeout`.
- **`periodic`:** **don't catch up** missed runs; wait for the next occurrence.

Document these rules explicitly. Encode them as the recommendation rather than picking one global policy.

### Trust does not come from the filesystem

This is the security crux. A file appearing in the watched directory tells you *nothing* about who put it there or whether to trust its content. Classification must come from elsewhere:

- A file the **agent itself wrote** via a known tool is `system` or `user-deferred`, depending on which tool wrote it.
- A file dropped by an **external program** (e.g. a webhook handler the agent authored) inherits the trust of *the source that program validated against* — a signed GitHub webhook makes it `known-party`; an anonymous POST makes it `unknown-party`.
- The carrier of that classification is a **sidecar `.trust` file, a directory-layout convention** (`events/known-party/…` vs `events/unknown-party/…`), **or registration metadata** — never the bare presence of the file.

Whatever the carrier, the resulting `Trigger.trust` drives the envelope-wrapping in [input-provenance.md](./input-provenance.md). Treat any file whose provenance can't be established as `unknown-party` and wrap it fully.

### The configuration-store pattern (related but distinct)

The filesystem-as-configuration variant walks the filesystem at startup to discover hook directories, each containing an `HOOK.md` (frontmatter + a `metadata.harness` block) and a `handler.ts`. The discovered handlers respond to named lifecycle events — `command:new`, `session:compact:before`, `gateway:startup`, `message:received` — *not* to the appearance of the file. This is filesystem-**as-configuration**: the directory walk populates a handler registry once; the files are behavior definitions, not events. It belongs on this page only to draw the contrast — if your design wants both, keep the discovery walk and the event watch as two separate subsystems reading two separate directories.

---

## Alternatives

### HTTP server / message broker (vs watched directory) as primary transport

A real broker (Redis Streams, NATS, SQS) or an inbound HTTP server gives you backpressure, multi-consumer fan-out, delivery guarantees, and cross-host distribution that a single-host watched directory can't. Choose a broker when events cross hosts, when you need more than one consumer, or when volume is high enough that per-file overhead matters. Choose the watched directory when the harness is single-host and single-user, when inspectability/replayability matter more than throughput, and when you want zero operational dependencies. The two compose: an HTTP receiver ([webhook-ingest.md](./webhook-ingest.md)) that *writes to* the watched directory after validation gets the broker-free local queue *and* the public endpoint.

### inotify/FSEvents directly (vs Node `fs.watch`)

`fs.watch` is portable but lossy — it coalesces events, behaves differently across platforms, and is the reason debounce and watcher-recovery are mandatory. Binding directly to `inotify` (Linux) or `FSEvents` (macOS) gives finer-grained, more reliable events at the cost of portability and a native dependency. Worth it only if you've measured `fs.watch` losing events under your load; for most harnesses the `fs.watch` + debounce + recovery stack is the pragmatic choice, and it's what `mom` ships.

### Polling the directory (vs watching it)

A `readdir` on a timer needs no watch handle and so has no watcher-death failure mode — attractive on flaky network filesystems where `fs.watch` is unreliable anyway. The cost is latency (the poll interval) and steady wakeups. Reasonable fallback specifically for network mounts; for a local `workspace/events/`, watching with recovery is both faster and cheaper.

---

## Anti-patterns

- **Treating "file appeared" as "content is trusted."** The filesystem is an unauthenticated drop point. Provenance must come from a sidecar, a directory convention, or registration metadata; absent that, classify `unknown-party` and wrap.
- **Read-then-delete without rename-on-read.** A producer re-write between read and delete is silently lost. Rename atomically on read, then process and delete the renamed copy.
- **No debounce on file events.** One editor save fires the pipeline 3–10 times. Debounce per filename (~100ms).
- **No watcher-error recovery.** A dead `fs.watch` handle silently stops delivering events and presents as an unresponsive agent. Wrap the watch, detect errors, close-and-reopen on a delay.
- **Dropping a file on first JSON parse failure.** Two-stage writes produce transient invalid JSON. Retry with backoff; skip-and-log only after max retries, and never let one bad file block the queue.
- **Catching up missed `periodic` events on startup.** A standing "every 5 minutes" periodic that was down for a day must not fire 288 times. Only `one-shot` (past `at`) fires late; `immediate` past startup is stale and deleted; `periodic` waits for the next occurrence.
- **Conflating the event queue with the config-store walk.** A queued event is a fire; a discovered `HOOK.md` is a handler registration. Reading one as the other produces phantom handlers and double-fires. Keep them in separate subsystems over separate directories.
- **Unbounded growth of `periodic` files.** They persist by design; without an age-out or explicit cleanup they accumulate. Apply the same age-out discipline as recurring cron ([scheduling.md § Age-out](./scheduling.md#age-out-for-recurring-jobs)).

---
