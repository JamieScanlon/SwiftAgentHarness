# Parallel Execution & Dispatch

> Sibling page of [tool-system/README.md](./README.md). Covers both levels of tool parallelism — runs competing for lanes, and calls inside one model turn — plus the ordering guarantees, the locks that make concurrent writers safe, and the tool-result middleware split (which lives here because its two seams differ exactly in their dispatch-vs-persistence consistency requirements). The runtime's role is deliberately thin: it *asks* the Tool System what may run in parallel ([agent-runtime](../agent-runtime/README.md)); this page is the policy it asks.

## TL;DR

Parallelism exists at **two independent levels**. *Run-level:* a lane-aware FIFO — every session gets a per-session lane with concurrency 1 (one active run per session, ever), and each run additionally occupies a global lane (`main` ≈ 4, `subagent` ≈ 8, `cron` separate) so background work can't starve inbound replies. *Batch-level:* within one turn's tool calls, partition **contiguous concurrency-safe calls** into parallel groups (bounded by a cap, ~10) and let each unsafe call form a singleton serial group — order across groups is preserved, so a mutating call still runs strictly after everything before it. Safety comes from the registry's `isConcurrencySafe(input)` *predicate* ([schema-and-registration](./schema-and-registration.md)), evaluated fail-closed: unparseable input or a throwing predicate means *not safe*. Results stream as they complete but **commit in call order**, and the `tool_use`/`tool_result` pairing invariant is never violated. Shared state during a parallel group is handled by **queueing mutations and applying them deterministically after the group**, and durable writes go through a **process-aware file lock** (pid + process-start-time, stale reclaim, reentrancy as explicit opt-in, watchdog force-release). Tool-result rewriting has **two seams on purpose**: runtime-neutral middleware on the deliver-to-model path, and a persist hook on the transcript-write path.

---

## Run-level parallelism: lanes

Before any batch policy applies, decide how many *agent runs* execute at once. The proven shape is a lane-aware FIFO queue where a lane is a named drain with a concurrency cap:

- **Per-session lane, concurrency 1.** Every run enqueues under `session:<key>`. This is the single most load-bearing guarantee in the system: *one active run per session*. Without it, two triggers landing together (a message and a cron tick) interleave tool calls against one transcript and one workspace.
- **Global lanes cap overall parallelism.** Each run also occupies a shared lane — `main` for inbound conversation (default ≈ 4), `subagent` for delegated work (default ≈ 8, higher because sub-agent runs are the fan-out mechanism), `cron` for scheduled jobs. Unconfigured lanes default to 1. The two-level structure means "this session is busy" and "the host is busy" are independent backpressure signals.
- **Nested runs must not inherit their parent's lane.** A cron job that dispatches inner agent work while itself occupying the `cron` lane deadlocks the lane at cap 1. Re-lane nested dispatches (`nested:<session>`) explicitly. Lane inheritance is the standing pitfall of lane systems; make lane assignment a resolved decision, not an ambient default.

Queue admission (what happens to messages arriving mid-run — steer into the live run vs. followup enqueue) is the Conversation Manager's story: see [runs](../conversation-manager/runs.md).

## Batch-level parallelism: order-preserving partition

One model turn may emit several `tool_use` blocks. The dispatch policy:

1. **Ask each tool, per call:** `isConcurrencySafe(input)` — a predicate of the *parsed arguments*, owned by the registry entry. Fail closed on every edge: input that doesn't parse → not safe; a predicate that throws (e.g. a shell-parse failure inside a command classifier) → not safe.
2. **Partition preserving order:** consecutive safe calls coalesce into one parallel group; every unsafe call is a singleton group. Groups execute strictly in sequence. The consequence is exactly the right guarantee: a mutating call runs after every call the model listed before it and before every call after it, while runs of reads between mutations still fan out.
3. **Bound the fan-out.** Cap in-flight calls within a group (~10, operator-tunable). Unbounded `Promise.all` over model-chosen batch sizes is an invitation to fd exhaustion and rate-limit storms.
4. **Stream progress as-completed; commit results in call order.** Progress events may interleave freely for UI liveness, but the `tool_result` blocks append to the conversation in the order of their `tool_use` blocks, and the pair invariant (result always follows its call; compaction never splits them — [compaction](../context-engine/compaction.md)) holds unconditionally.

What is *not* recommended: dependency-analysis reordering — running a mutating call concurrently with "unrelated" reads, or hoisting reads across a write. Every studied production system rejects this; argument-level aliasing (does `rm -rf dir` affect `read dir/file`?) is undecidable at the string level, and the failure is silent corruption. If the order-preserving partition is more machinery than a harness wants, the acceptable floor is simpler: any unsafe call in the batch serializes the *whole* batch. Both are sound; pick by taste. Reordering is not sound; don't.

Two operational details:

- **Track in-flight call ids as shared state.** The set of in-progress `tool_use` ids drives spinners, cancellation targeting, and the interrupt path (`interruptBehavior: cancel | block` per entry — [schema-and-registration](./schema-and-registration.md)).
- **Defer shared-context mutation.** Tools may modify the dispatch context (new working directory, mode transition, discovered capability). In a parallel group, applying these mid-flight makes sibling results depend on completion order. Queue context modifiers as they're emitted and apply them *after* the group completes, in call order — deterministic regardless of racing.

## Conflict handling: locks, not hope

Parallel groups plus multi-process deployment (a gateway process, node hosts, concurrent CLI invocations) mean durable state needs real mutual exclusion:

- **Transcript writes take a process-aware file lock.** Exclusive-create lockfile next to the transcript, payload carrying `pid`, `createdAt`, *and the process start time* — pid alone is insufficient because PIDs recycle, and a recycled pid makes a dead lock look held. Stale detection enumerates its reasons (dead pid, recycled pid, too old, malformed payload) and reclaims; acquisition retries with bounded backoff and fails with an error naming the owner and lock path — a timeout that can't say who holds the lock is undebuggable.
- **Reentrancy is an explicit opt-in, not a default.** Same-process re-acquisition silently succeeding is how accidental recursive writers pass tests and corrupt production transcripts. The caller who genuinely needs nesting declares it.
- **A watchdog force-releases over-held locks** (max-hold ≈ 5 min, derived from the run timeout plus grace), and signal handlers release synchronously on termination — then re-raise the signal rather than swallowing it.
- **Workspace file writes have their own story** — queued single-writer plus session lock at the execution-environment seam; see [execution-environments](../../backends/execution-environments/README.md). The Tool System doesn't duplicate that machinery; it relies on it.

## The tool-result middleware split

Two hook seams rewrite tool results, and they are different on purpose:

- **Result middleware (dispatch path).** Registered via the plugin SDK, declared per *agent runtime* it supports, running after execution and before the result re-enters the model. This is where truncation-for-context, secret redaction toward the model, and noisy-output compaction live. It is runtime-neutral in interface but runtime-scoped in declaration — a middleware states which runtimes it understands rather than being force-fed all of them.
- **Persist hook (transcript path).** A decision-capable hook (`tool_result_persist` — [extensibility](../../cross-cutting/extensibility/README.md)) rewriting what is *written to history*.

The split matters because the two paths have different consistency requirements. The dispatch path is per-run and ephemeral — an aggressive rewrite costs one confused turn. The persist path is durable and shared — it feeds compaction summaries, session resumption, audit, and every future run; a lossy rewrite there is permanent. Collapsing the seams forces one policy to serve both, and it will be wrong for one. Typical composition: middleware first (what the model sees now), persist hook second (what history keeps) — deliberately allowing *history to retain more than the model saw*, e.g. full output persisted while a truncated view is delivered.

Sub-agent result delivery (announce queues, push-based completion) rides the Sub-Agent Pool's machinery, not this page — see [agent-orchestration](../sub-agent-pool/agent-orchestration.md).

---

## Alternatives

### Whole-batch serialization on any unsafe call

The conservative floor: one mutating call makes the entire batch sequential. Simpler to implement and to explain; gives up read fan-out around writes, which mostly matters for search-heavy coding agents whose models emit large mixed batches. Sound; choose it freely when batch sizes are small.

### No batch parallelism at all

Strictly sequential dispatch. Correct by construction and the right starting point for a young harness — batch parallelism is an optimization, and per-session lanes at the run level already deliver most of the throughput that multi-conversation deployments need. Add the partition when tool latency, not model latency, dominates turns.

### Advisory locking via in-memory mutexes only

Works exactly until there are two processes. Any harness with a gateway daemon *and* a CLI (or node hosts) has two processes; the file lock with liveness detection is the actual requirement.

---

## Anti-patterns

- **Dependency-analysis reordering.** "These calls look independent" at the argument-string level is a guess; racing a write against a read that aliases it corrupts state silently. Preserve model-emitted order between safety classes.
- **Lane inheritance for nested dispatch.** The cron-job-spawns-agent deadlock: parent occupies the lane, child waits for it, forever. Resolve lanes explicitly for nested runs.
- **Unbounded group fan-out.** The model decides batch size; the model does not know your fd limits or provider rate caps. Cap it.
- **Applying context modifiers mid-group.** Sibling results become a function of completion order — irreproducible, unreplayable. Queue and apply post-group in call order.
- **Pid-only lockfiles.** Recycled PIDs make dead locks immortal. Store process start time; verify both.
- **Silent reentrant locks.** Recursive acquisition as default behavior hides real double-writer bugs. Opt-in, loudly.
- **One rewrite seam for dispatch and persistence.** The redaction that history needs and the truncation the model needs are different transforms with different blast radii. Keep both seams.
- **Streaming results as the commit order.** As-completed is for progress display only; committing results in completion order breaks the pairing expectations of everything downstream (compaction, replay, provider validation).

---

## Cross-references

- [tool-system README](./README.md) — the parallelism-policy and middleware rec bullets this page expands.
- [schema-and-registration](./schema-and-registration.md) — `isConcurrencySafe(input)` and `interruptBehavior` as registry-entry fields with fail-closed defaults.
- [agent-runtime](../agent-runtime/README.md) — the dispatch loop that consumes this policy ("the runtime asks; the Tool System decides").
- [runs](../conversation-manager/runs.md) — queue admission, steering, followup semantics above the lane layer.
- [compaction](../context-engine/compaction.md) — the tool-pair invariant that commit ordering protects.
- [execution-environments](../../backends/execution-environments/README.md) — workspace FS atomicity (queued writer + session lock).
- [extensibility](../../cross-cutting/extensibility/README.md) — hook typing for `tool_result_persist`; middleware registration surface.
- [agent-orchestration](../sub-agent-pool/agent-orchestration.md) — sub-agent fan-out, announce queues, completion delivery.
