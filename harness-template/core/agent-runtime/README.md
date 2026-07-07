# Agent Runtime — Recommended Architecture

## TL;DR

The Agent Runtime is **the inner loop and nothing more**: assemble messages → call the model (via the Pool) → consume the event stream → dispatch tool calls → append results → check stop conditions → loop. It's **stateless across invocations** — it takes a conversation as input and emits events to whoever's listening; it doesn't own state, doesn't decide which model to use, doesn't compact, doesn't enforce permissions, and doesn't manage budget. The discipline of **keeping the runtime dumb** is what makes everything around it pluggable.

The cleanest crystallization is a minimal agent-core inner loop: on the order of ~700 lines that do exactly this and nothing more. A common anti-pattern is an inner loop function of ~1700+ lines that accumulates more responsibility than the Pool/Engine/Tool factoring would put on it; the parts of such functions that are not the loop itself are recommendations to push *out* into other layers.

---

## Why this belongs as its own layer (and why it should stay small)

Every harness has an inner loop. The question isn't whether you have one — you do — it's how much else lives in it. Two failure modes show up over and over:

1. **The smart runtime.** The loop accumulates retry logic, model-selection heuristics, compaction triggers, permission flows, budget checks, and adapter-specific event handling. Each addition seemed reasonable in isolation. The result is a 2000-line function that nothing can refactor because every concern in the harness has touched it. This is the path most single-binary CLIs walk.
2. **The plugin-everywhere runtime.** The loop is so abstracted that every step is a hook, every state transition is an event, every decision is delegated to middleware. The result is a 200-line runtime and a 5000-line graph of indirection that nobody can follow. This is the path most "framework" harnesses walk.

The right shape is a small, dumb, imperative loop that pulls work from sharply-defined external layers. The runtime asks the Model Pool which model to use; the Pool answers. The runtime hands the request to the Pool; the Pool runs it and streams events back. The runtime hands tool calls to the Tool System; the Tool System runs them and returns results. The runtime hands the next-turn context assembly to the Context Engine; the Engine returns the message array. The runtime appends, checks stop, loops.

Said differently: **the runtime is the orchestrator of one turn, not the owner of any one decision in that turn.** Decisions live in the layers around it; the runtime calls them in the right order.

---

## Recommendation

### The loop, as small as it goes

```
loop {
  messages    = ContextEngine.assembleForTurn(conversation, runOptions)
  modelEntry  = ModelPool.resolve(runOptions.modelQuery)
  request     = buildRequest(messages, conversation.tools, modelEntry)

  for event of ModelPool.invoke(modelEntry, request, signal) {
    publish(event)                              // tokens, reasoning, tool-call deltas
    accumulate(event into assistantMessage)     // build the assistant turn as it streams
  }

  conversation.append(assistantMessage)

  if assistantMessage.toolCalls.isEmpty || stopReason.isTerminal {
    break
  }

  for toolCall of assistantMessage.toolCalls {
    toolResult = ToolSystem.dispatch(toolCall, conversation, signal)
    conversation.append(toolResult)
    publish(toolResult)
  }

  if shouldStop(conversation, runOptions) {
    break
  }
}
```

That's the runtime. Everything that isn't in those lines lives somewhere else.

A few details worth being explicit about:

- **`ContextEngine.assembleForTurn`** is called *every* iteration, not once per turn. The Context Engine decides what gets included this iteration — past messages may get trimmed, summarized, or re-fetched as the conversation grows. The runtime doesn't know the difference between "verbatim history" and "compacted summary"; it just gets a message array.
- **`ModelPool.resolve`** is called every iteration too, in case routing changes mid-turn (a sub-agent decided to switch to a cheaper model halfway through; the user changed mode from agent to chat). The Pool returns a `ModelEntry` and the runtime uses it.
- **Tool calls execute after the assistant message is fully accumulated**, not as deltas arrive. Streaming the tool-call *deltas* to subscribers is fine (UI wants to render them as they form), but actually *executing* a tool happens once, after the streaming completes for that tool. Mid-stream tool execution is a correctness trap.
- **Stop conditions are checked twice** per iteration: after the model emits no tool calls (natural stop) and after tool results are appended (max-iterations / external cancel / context-budget exhausted). Don't merge; the two checks have different semantics. The "natural stop" check is itself mode-shaped — under an agent-style `terminal-tool` policy a no-tool-call turn is a *stall to recover from*, not a stop. See [§ Termination policy and stall recovery](#termination-policy-and-stall-recovery).

### Stateless across invocations

The runtime function takes `(conversation, runOptions, signal)` and returns when the loop terminates. It holds no state between invocations:

- No conversation cache — pass the conversation in.
- No model-pool cache — call the Pool every time.
- No tool registry of its own — call the Tool System.
- No "current cwd," "current user," "current credentials" — those are properties of the conversation or of the runOptions.

This is the property that makes the runtime trivially reentrant: two concurrent calls on the same process for two different conversations are isolated by construction. Single-binary CLI implementations often accumulate some module-level state (current model, current cwd, logger) that fights this property in practice; the minimal-loop shape avoids it by construction.

The test for whether you've achieved it: can you run two `agentLoop(...)` calls concurrently in one process and have them not interfere? If yes, the runtime is stateless. If no, find the global.

### Pooling a heavy execution context

The "no state of its own" rule is easy when the per-turn execution context is cheap to assemble each iteration. In practice many harnesses bundle the model client, the tool manager, the MCP/A2A wiring, and the rendered system prompt into a single per-conversation **execution context** object — call it an orchestrator, a session, an engine — that is expensive enough to build that you want to reuse it across a conversation's turns. A lean loop stays light enough to dodge this; some implementations clone a per-child context; subprocess-per-agent takes it to the extreme of a whole OS process per execution context. The question this section answers is what to do in the in-process middle ground, where the context is heavy but you don't want a process per conversation.

The wrong move is the tempting one: hold **one** execution context per session and rebind it whenever the active conversation or model changes. That is just the [module-level global](#anti-patterns) in heavier clothing. The moment two runs are live at once — a main run plus a sub-agent it spawned, an active-memory recall firing mid-loop, or simply two conversations in one session — they fight over the single slot. Each rebind cancels the other's in-flight model call, tears down its event listeners, and thrashes; the symptoms are mysterious connection cancellations and runs that never settle. The single shared slot also can't be reference-counted, so there is no safe point to tear it down.

The right move is to own the execution context as a small **pool keyed by `(conversationID, model)`**, acquired per run. This keeps the runtime's "isolated by construction" property while letting an expensive context be reused across a conversation's turns:

- **Acquire on run start, resolve by conversation, release on run end.** Each run holds a handle for its entire lifetime (completion *and* cancellation paths both release). Resolution everywhere is `contextFor(conversationID)` — never a session-global "current context" pointer. A run can never have its context swapped or torn down underneath it.
- **Reference-count, and never evict an in-use entry.** The handle is the refcount. Idle eviction and invalidation skip any entry with a live holder.
- **Deduplicate concurrent builds.** Two acquires racing on the same key must await one in-flight build, not build twice — a double build means two model clients (and, for local inference, two model loads) for one conversation. Store the in-flight build task in the key map and have late arrivals await it.
- **Per-entry teardown releases only that entry's own resources.** Connection-pooled, cross-conversation infrastructure (MCP / A2A / ACP managers) is owned at the *session* and torn down once, at session end — never when one conversation's context is evicted. Conflating these two lifetimes is its own [anti-pattern](#anti-patterns): evicting one conversation's context must not disconnect tools for every other conversation.
- **Invalidate per conversation, and unhook immediately.** A mode or model change rebuilds *that* conversation's entry and leaves every other entry untouched. Unhook the stale entry from the lookup tables at invalidation time so the next acquire builds fresh, while any still-running holder drains against the old instance and tears it down on release.
- **Bound the pool, but keep resource control in the Model Pool.** An LRU + idle-TTL cap bounds memory. Pooling execution contexts is a *state-isolation* mechanism, not a concurrency-control one — the number of orchestrators alive says nothing about how many model calls may run at once. Backpressure on inference (and, for local models, GPU/VRAM pressure) stays in the [Model Pool](../model-pool/)'s scheduler. Keep the two concerns separate or you will conflate "how many conversations are warm" with "how many tokens are generating."
- **Fail safe on ambiguity.** If a legacy accessor still asks for "the current execution context" without naming a conversation, it must no-op or return empty when more than one run is live — never mutate an arbitrary entry. A no-op under concurrency is recoverable; mutating the wrong conversation's lifecycle is a silent corruption.

The pool is the bridge between the stateless-runtime ideal and the heavy-context reality: the runtime still carries no state, the context is owned by a structure that is keyed, ref-counted, and isolated per conversation, and the two-concurrent-`agentLoop` test still passes.

### Streaming, generator-shaped

The runtime should be a generator (or `AsyncIterable`-shaped) that yields events as they happen, with a final return value when the loop terminates. An `EventStream<AgentEvent, AgentMessage[]>` shape is exactly right:

```ts
function agentLoop(
  prompts: AgentMessage[],
  context: AgentContext,
  config: AgentLoopConfig,
  signal?: AbortSignal,
): EventStream<AgentEvent, AgentMessage[]>
```

The caller can consume events as they arrive (for streaming UI) and await the final return (for "give me the resulting message array"). One return path supports both use cases.

An `async function*` shape is the same idea in a different syntax. Both work; pick whichever your language idiom prefers. The thing to avoid is callback-based event emission *plus* a returned promise *plus* mutation of an external state object — that's three coordination paths for what should be one.

### What the runtime emits

The runtime is the producer of `conversation/{id}/events` (per the topic taxonomy in [communication-layer.md](../communication-layer/)). Concretely:

- `turn.started` — turn id, initiating input
- `loop.iterationStarted` — iteration count, message count
- `model.callStarted` — model id, request size estimate
- Model events — token deltas, reasoning blocks, tool-call deltas, usage info (forwarded from the Pool's normalized event stream)
- `model.callCompleted` — stop reason, final usage
- `tool.callStarted` — tool name, arguments
- `tool.callCompleted` — result shape (or error)
- `loop.iterationCompleted`
- `turn.completed` — final stop reason, total iterations, total cost (sum across iterations)

Two lifecycle events to handle carefully: `model.callStarted` should fire *after* the Pool has actually dispatched (not while it's queued — that's the Pool's `queued` state), and `turn.completed` should fire after all events have been published, including the final tool result events.

Crucially: the runtime forwards the Pool's normalized model events through. It doesn't re-parse them, re-shape them, or filter them. The Pool already normalized; the runtime is a passthrough for those events (tagged with the conversation+turn context).

### Stop conditions

Three reasons the loop terminates, in priority order:

1. **External cancellation.** `signal.aborted` becomes true (user clicked stop, parent agent cancelled, conversation-level deadline hit). Loop breaks at the next safe point — between iterations, ideally — and emits `turn.cancelled`.
2. **Natural stop from the model.** The assistant message has no tool calls and the stop reason is terminal (`stop_sequence`, `end_turn`). Loop breaks, emits `turn.completed`.
3. **Bounded stop.** Iteration count exceeded `maxIterations` (default ~25), context budget exhausted, or the Tool System returned a "halt" signal (e.g., a tool that explicitly asks the loop to stop). Loop breaks, emits `turn.bounded` with the reason.

The `maxIterations` cap is non-negotiable. Without it, a model that keeps calling tools without making progress can loop indefinitely; with it, you get a predictable upper bound and a clear failure mode. Make the cap configurable per conversation; default sized for the model's typical agent workload.

### Termination policy and stall recovery

[§ Stop conditions](#stop-conditions) lists *why* the loop can break; this section is about *who decides the natural-stop boundary*, because that decision is mode-shaped. The runtime reads the active mode's `runtime.termination` slice (see [conversation-manager/modes.md § Termination policy](../conversation-manager/modes.md#termination-policy)) and runs **one generic loop parameterized by it** — it never branches on a mode id.

Two policies cover the corpus:

- **`bare-message`** — the turn ends when the assistant emits no tool calls. The conventional chat shape; this is the `assistantMessage.toolCalls.isEmpty` break in [§ The loop](#the-loop-as-small-as-it-goes).
- **`terminal-tool`** — the loop continues by default and ends only when the model calls a halt-signal tool (`finish`, `ask_user`, `exit_plan_mode`). A no-tool-call turn is a **stall**, not a stop.

The reason `terminal-tool` exists: in an autonomous run, "assistant message with no tool call" is overloaded. It can mean *done*, *blocked*, or *stalled* — the model narrated "let me do X" and dropped the call, a format-compliance failure that, left in history, few-shots itself into recurring. Inferring termination from the *absence* of a tool call cannot separate these. `terminal-tool` resolves the ambiguity by making *done* and *blocked* positive, validated tool calls, leaving "no tool call" to mean exactly one thing: stalled — recover.

#### The decision function

Keep the runtime dumb: the policy is a single pure function the loop calls each iteration, not a web of conditionals threaded through the loop body.

```ts
type TerminationDecision = {
  action: "stop" | "continue" | "recover" | "bounded"
  toolChoiceNext: "auto" | "required"
}

function evaluateTermination(
  assistant: AssistantMessage,
  iter: IterationState,
  policy: TerminationPolicy,
): TerminationDecision
```

The minimal loop from [§ The loop](#the-loop-as-small-as-it-goes), with the policy hook spliced in:

```
toolChoice = iter.forcedNext ?? "auto"
assistant  = stream(model, msgs, toolChoice)

terminal = assistant.toolCalls.find(tc => ToolSystem.isHaltSignal(tc))
if terminal { dispatch(terminal); break("completed") }   // finish / ask_user / exit_plan_mode

switch evaluateTermination(assistant, iter, policy).action {
  "stop":     break("completed")                          // bare-message: no tool calls
  "recover":  if ++iter.stalls > policy.recovery.maxAttempts break("bounded")
              if policy.recovery.rollbackStalledTurn rollback(assistant)
              iter.forcedNext = "required"                // re-roll; model must act
              continue
  "continue": dispatchAll(assistant.toolCalls); appendResults()
}
if iterations >= maxIterations break("bounded")
```

- **chat** → `evaluateTermination` returns `stop` on an empty-tool-call turn; `toolChoiceNext` stays `auto`. Byte-for-byte the existing bare-message break.
- **agent** → returns `recover` with `toolChoiceNext: "required"` on a stall; the next model call is forced to emit a tool. Reset `iter.stalls` to 0 on any successful tool-calling turn.

The runtime gains one small generic step parameterized by config — it does *not* gain mode names or provider shapes, so it stays on the "small fixed set of named decisions" side of the line, not the indirection side (per [§ Anti-patterns](#anti-patterns)).

#### Halt signals belong to the tool, not the mode

`ToolSystem.isHaltSignal(tc)` reads a `haltsLoop: true` flag on the tool definition. This is what keeps the runtime free of tool names *and* the mode free of runtime mechanics: the mode lists `finish`/`ask_user` in `tools.allow`, the tool declares `haltsLoop`, the runtime asks the Tool System. Three independently-owned facts compose into "agent mode stops on `finish`" with no layer hardcoding another's vocabulary. Plan mode's `exit_plan_mode` is just another `haltsLoop` tool — plan termination falls out of the same mechanism rather than being special-cased.

#### Two budgets, not one

`maxIterations` is the run-level floor — it bounds a model that calls tools forever without ever calling `finish`. `recovery.maxAttempts` is a *separate, consecutive-stall* sub-budget so a degenerate narration loop bound-stops after a couple of re-rolls instead of spending the entire iteration budget on rollbacks. Reset the stall counter on any tool-calling turn; a single stall mid-run should cost one forced re-roll, not the whole budget. Both terminate via the `bounded` stop from [§ Stop conditions](#stop-conditions), with distinct reasons (`max-iterations` vs `stall-unrecovered`) so subscribers can tell a runaway tool-caller from a stuck narrator.

#### Forced tool choice stays provider-agnostic

`toolChoiceNext` is the abstract value `"auto" | "required"` (or `{tool: name}`). The Model Pool's adapter maps it to provider shape — Anthropic `tool_choice: {type: "any"}`, OpenAI `tool_choice: "required"`. The runtime never emits provider-specific request fields (per the coupling anti-pattern in [§ Anti-patterns](#anti-patterns)). And because forcing a tool call can degrade reasoning on some models, agent mode should carry a no-op `think(scratchpad)` tool in its allow-list so "reason without acting" is itself a legal tool call — otherwise `required` can trap a model that legitimately needs to deliberate before acting.

**The wire field is an optimization, not the enforcement.** Whether the adapter actually emits `tool_choice` depends on the binding's [`toolChoice` capability](../model-pool/#the-model-registry-entry): on a binding that reaches the `required` rung the wire field does the work cheaply; on a binding that doesn't (many local/OpenAI-compat endpoints), the adapter omits it and the directive is silently a no-op. So the runtime must never *trust* that `required` was honored — it enforces forcing itself, provider-agnostically, by inspecting the result. When `toolChoice == "required"` and the assistant turn comes back with no tool call, the turn is rejected (not appended) and recovery runs: an *ephemeral, non-`user`-role* reminder ("a tool call is required for this turn") is prepended to the next model call, escalating by attempt count, with a synthetic `think` injection once consecutive stalls cross a threshold — capped by `recovery.maxAttempts` → `bounded`. This behavioral path is the actual correctness guarantee and it holds identically whether or not the binding could honor the wire field; the capability only decides how often the reminder loop has to fire. The two layers must stay distinct: the Model Pool owns *encoding* (emit the wire field when capable), the runtime owns *enforcement* (reject-and-re-roll until a tool is called or the budget is spent). A harness that has only the wire field is unenforced on weak providers; one that has only the reminder loop wastes a round-trip on every forced turn even where the provider could have done it for free.

#### Don't train the stall

A recovered stall must not teach the model to stall again. Two disciplines: (1) the recovery reminder is an *ephemeral, non-`user`-role* nudge the Context Engine strips from the persisted projection — never an injected `[user]: continue`, which both pollutes history and conditions the model on "stop → wait for continue → resume"; (2) with `rollbackStalledTurn`, the stalled assistant turn never lands in `rawEvents` at all, so the persisted transcript shows clean action rather than stall-then-rescue. Rollback here is the same partial-turn discipline as [§ Cancellation hygiene](#cancellation-hygiene): a turn either completes coherently or it did not happen.

### Tool-call dispatch ordering

When the model emits multiple tool calls in one assistant message:

- **Sequential by default.** Dispatch in order, await each, append result before dispatching the next. Predictable, simple to reason about.
- **Parallel if all tools are pure / commutative.** Some tools are read-only (file reads, search, capability queries) and have no ordering dependencies. The Tool System (not the runtime) decides which tools are parallelizable; the runtime asks "may I dispatch these in parallel" and gets a yes/no per pair.
- **Serial if any tool is mutating.** As soon as a tool that mutates state is in the batch, fall back to sequential for the whole batch. Don't try to be clever about partial parallelism; the bug surface is high.

This is one of the few places where the runtime makes a real decision rather than delegating; even so, the *policy* (which tools are parallelizable) belongs to the Tool System, not the runtime.

### Sub-agent invocation as ordinary tool calls

Per the [sub-agent-pool.md](../sub-agent-pool/) recommendation, delegate calls are auto-registered as tools in the Tool System. From the runtime's perspective, calling `delegate_to_researcher` is a tool call like any other:

- Tool System recognizes it as delegate-class and routes to the Sub-Agent Pool.
- The Pool runs the delegate (in-process or remote, the runtime doesn't care).
- The Pool returns either a synchronous result or a "running, will announce later" handle.
- For sync: the runtime appends the result and continues.
- For async: the runtime appends the handle and continues; the Sub-Agent Pool will eventually announce the completion as a fresh input event into the conversation, which produces a new turn.

The async case is where the runtime's stateless shape pays off: the announcement comes in as a regular input, the runtime processes it as a regular turn, and there's no "long-running tool call" state hanging around in the loop.

### Cancellation hygiene

When `signal.aborted` fires mid-iteration, do this in order:

1. Stop reading from the Pool's event stream (the Pool's adapter sees the signal too and tears down the upstream call).
2. Discard partial assistant message accumulation — never append a half-streamed message to the conversation; either fully complete or roll back.
3. Cancel any in-flight tool calls (pass the signal through; tools that don't honor it get force-killed by their adapter after a grace period).
4. Append a `custom` entry of type `run_cancelled` to `rawEvents` under the conversation's write lock, carrying `{runId, iteration, reason, cancelledAt}`. This is what makes the run derivable as cancelled rather than open-with-dead-process. The contract is end-to-end across layers — see [conversation-manager/runs.md § Cancellation contract](../conversation-manager/runs.md#cancellation-contract).
5. Emit `turn.cancelled` with the iteration count where it stopped.
6. Return.

Partial state in the conversation is the most common cancellation bug. The conversation should be in a coherent state at all times — either the assistant turn completed or it didn't happen. Half-completed turns confuse the next iteration's context assembly.

A subtlety worth being explicit about: an assistant message that *fully streamed* before the cancel signal should be kept (append normally) before the cancellation marker. The model said it, `rawEvents` is the unedited record of what happened, and discarding it makes the next replay non-deterministic. Discard only *partially-streamed* accumulation. This is one of the lines you can only get right if you're explicit about it.

### Resumption: stateless replay from rawEvents

Because the runtime is stateless across invocations and `rawEvents` is append-only, **resumption is just re-invoking `agentLoop(...)` against the same conversation**. There is no separate "resume" entry point and no in-flight state to reconstruct. This shape is what makes both the architectural decision to leave deliberate user-driven pause/resume out of scope (per [conversation-manager/runs.md § Why deliberate pause/resume is out of scope](../conversation-manager/runs.md#why-deliberate-pauseresume-is-out-of-scope)) and the byte-identical wire prefix needed for prompt-cache hits *fall out of the architecture* rather than requiring dedicated machinery.

Three things make this work:

1. **`rawEvents` is the canonical input.** The Context Engine's `assembleForTurn` reads from it; the projected view it produces depends only on `(rawEvents, derivedEvents, config)`. Two runtime invocations against the same conversation, at the same head, with the same config, produce the same projected view — and therefore the same wire request, byte-identical for any reasonable serializer. Provider prompt-cache logic (Anthropic's cache, OpenAI's automatic caching) hits on this prefix automatically. No special handling required.
2. **The runtime carries no state of its own.** Per [§ Stateless across invocations](#stateless-across-invocations), there's no in-memory accumulator that has to be reconstructed. A fresh `agentLoop(...)` call against the conversation's current head is indistinguishable from a continuation of the prior call.
3. **Pause/resume cycles look like cancel-then-restart.** An approval-gated tool call (sub-agent over A2A awaiting user approval; remote tool with multi-round permission protocol) is handled by the Tool System or Sub-Agent Pool with a synchronous block on dispatch; the runtime sees one `dispatch` call that returns when the gate clears, no different from a slow tool. For the pathological case where *the runtime itself* must exit while the gate is open (process restart, gateway redeploy), the contract is: cancel the run via the [Cancellation contract](#cancellation-hygiene), and on resume, `appendInput` against the conversation's `rawEvents` produces a new run that picks up from the same context. Prompt cache makes the second model call cheap.

Some single-binary implementations implement explicit `resumeAgent` logic — reconstruct the wire prefix from the sidechain transcript so the resumed run hits the cache. This template doesn't need that primitive, because every runtime invocation already replays from `rawEvents` and the byte-identical prefix is structural rather than something the runtime has to opt into.

**What the runtime does NOT do on resume:**

- **No in-flight tool re-dispatch.** If a tool call was in flight when the prior run died, the next runtime invocation does not "complete" it — it sees the conversation at whatever head the cancellation contract left it. If the cancellation marker is missing (process died without grace), the [Conversation Manager appends a `run_orphaned` marker on startup](../conversation-manager/runs.md#resumption-after-restart); the next user input opens a fresh run.
- **No partial message stitching.** A half-streamed assistant message is gone (per [§ Cancellation hygiene](#cancellation-hygiene)); the runtime starts the next iteration as if the model is being asked the same question fresh. The model regenerates; cache hits make this cheap.
- **No "implicit retry."** Resuming after a Pool error is the caller's choice (`appendInput` again or not); the runtime doesn't auto-retry.

The discipline pays off everywhere: orphan recovery, restart resilience, branch-and-rerun, and "let me see what would happen with a different config" all flow from the same primitive. Don't add a dedicated resume API; lean into the shape.

### Error handling

The runtime distinguishes three error classes:

- **Pool errors (model failed)** — the Pool already retried and failed over; if it surfaces an error, the call is genuinely unrecoverable. Runtime catches, emits `model.callError`, decides per `runOptions.onModelError` whether to break the loop (default) or surface to the model as a tool-result-style error and continue.
- **Tool errors** — the Tool System returned an error result. Append it to the conversation as a tool result with `isError: true`. Continue the loop — the model can decide what to do.
- **Runtime errors (the loop itself crashed)** — bug. Emit `turn.runtimeError`, surface up. Don't try to recover; the conversation may be in an inconsistent state.

Distinguishing tool errors from model errors is the part frequently gotten wrong. A tool that errored is information the model should see and respond to; a model that failed is something the loop has to decide about. They aren't the same shape.

---

## Alternatives

### Graph-executor alternative

Express the loop as a state machine: nodes for "call model," "execute tool," "compact," edges for transitions. The runtime is the framework's graph executor.

**When this works:** when your loop has substantial branching that's clearer as a graph than as imperative code — multiple distinct phases, parallel branches, conditional re-entry. Workflow-heavy systems benefit.

**Why not as default:** the standard agent loop is genuinely just "call → tools → loop." Expressing it as a graph adds indirection without illuminating anything; debugging becomes "read the graph definition + read the executor's state" instead of "read the loop." Reach for graph-shaped runtimes when your workflow actually is a graph; for plain agent loops, imperative is clearer.

A nuanced point: even when you use a graph executor, the *inner loop* is still an imperative call/tool/loop. The graph orchestrates phases above that; the loop is unchanged. So the choice is really "do you want graph orchestration *around* the loop," not "do you want a graph *as* the loop."

### Middleware-stack alternative

Every step of the loop wrapped in a `before/around/after` middleware chain. Cross-cutting concerns (logging, retry, hooks) install middleware rather than touching the runtime.

**When this works:** when you have many cross-cutting concerns that need to participate at the same hook points and you want them composable. Plugin-heavy harnesses benefit.

**Why not as default:** the cost is debuggability. A failure deep in a middleware chain has a stack trace that doesn't tell you which middleware did what. A simpler shape: the runtime has a *small fixed set* of named extension points (`beforeIteration`, `afterModelCall`, `beforeToolDispatch`, `afterToolResult`) that plugins can subscribe to. Same hook coverage, far easier to follow.

### Router/coordinator runtime (single-binary CLI alternative)

The runtime contains substantial routing logic — pre-loop classification of intent, dispatch to specialized sub-loops for different request types, post-loop result transformation.

**When this works:** when the harness needs intent-driven routing baked into the inner loop because no other layer is well-positioned to do it. Some single-binary CLIs accumulate this for slash-command handling, file-mention resolution, and ambient-context injection.

**Why not as default:** most of what accumulates in such runtimes belongs in the Context Engine (ambient context, file mentions) or the Tool System (slash commands as tool-shaped invocations) or the Conversation Manager (intent classification as a mode setting). Pull each concern out as it grows; don't let the runtime become the catch-all.

---

## Anti-patterns

- **Smart runtime.** The loop knows about provider-specific event shapes, runs its own retry, decides which model to call from heuristics, computes its own permission decisions, manages cache. Each addition was reasonable; the cumulative result is the loop owning everything. Push concerns out: provider event shapes belong to provider adapters; retry belongs to the Pool; model selection belongs to capability query; permissions belong to the Tool System; cache belongs to the Pool.
- **Module-level globals in the runtime.** A current-model variable, a current-cwd, a logger singleton. Until two concurrent runs happen on one process and they trample each other. State belongs to the conversation; the runtime carries no state of its own.
- **Session-singleton execution context.** The heavyweight form of the module-level global: one mutable orchestrator/model-client binding per session, rebound whenever the active conversation or model changes. A main run and a concurrently-spawned sub-agent (or two conversations in one session) then fight over the one slot — each rebind cancels the other's in-flight model call and tears down its listeners, and the binding can't be ref-counted so there's no safe teardown point. Own the per-conversation execution context in a pool keyed by `(conversationID, model)` (see [§ Pooling a heavy execution context](#pooling-a-heavy-execution-context)).
- **Tearing down shared infrastructure on per-run teardown.** When the per-conversation execution context is pooled, evicting or invalidating one entry must release only that entry's own resources. Connection-pooled MCP/A2A/ACP managers are shared across conversations and owned at the session; shutting them down because one conversation's context was evicted kills tools for every other live conversation. Per-entry teardown and session teardown are different lifetimes — don't route one through the other.
- **In-loop retry/backoff.** "If the model errors, sleep and retry inside the loop." The Pool already does this; doing it again in the runtime double-counts and breaks the Pool's queue accounting. Trust the Pool.
- **In-loop compaction triggers.** "If history is too long, summarize before the next iteration." Belongs to the Context Engine, called from `assembleForTurn`. The runtime doesn't know what "too long" means for this model; the Engine does.
- **In-loop permission checks.** "If the tool needs approval, prompt the user before dispatching." Belongs to the Tool System's permission gate, called from `dispatch`. The runtime doesn't know the policy; the Tool System does.
- **Coupling to one provider's event shape.** The runtime parses Anthropic-style `content_block_delta` directly. Then a second provider arrives and you can't add it without a rewrite. The Pool's adapters normalize; the runtime sees one event shape.
- **Mutating the conversation as the assistant message streams.** Appending a half-built message is a corruption trap; if cancellation fires mid-stream, the conversation contains a partial message that breaks subsequent context assembly. Buffer the assistant message in the loop frame; append only when complete (or roll back on cancel).
- **Callback-based event emission.** "Pass an `onEvent` callback into the runtime." Forces callers to coordinate consumption with the runtime's lifecycle, makes streaming UI awkward, and complicates error propagation. Generator-shaped (or `AsyncIterable`) is the right primitive — the caller controls consumption pace and lifecycle.
- **Conflating "stop" reasons.** Treating natural stop, max-iterations, cancellation, and context-budget exhaustion as one "the loop ended" signal. They mean different things to subscribers; emit them as distinct events with explicit reasons.
- **Branching on mode id in the runtime.** `if (mode === 'agent') { ...different loop... }`. Undoes the profile abstraction and means every new mode edits the loop. Read `runtime.termination` and run one parameterized loop; the mode contributes config, not control flow. (Mirrors the per-layer mode-name-check anti-pattern in [conversation-manager/modes.md](../conversation-manager/modes.md#anti-patterns).)
- **Inferring agent-run termination from a bare message.** Under a `terminal-tool` policy, "no tool call" means *stalled*, not *done*. Treating it as done strands half-finished work; the only legitimate stops are halt-signal tools (`finish` / `ask_user`). Conversely, applying `terminal-tool` recovery in chat mode turns a normal spoken answer into a forced-tool-choice loop the user can't end. The policy is mode-shaped for a reason; don't globalize either branch.
- **Unbounded stall nudging.** Escalating "continue" reminders with no cap loop forever on a model that won't comply. Cap with `recovery.maxAttempts` → `bounded`, keep the nudge ephemeral and non-`user`-role, and prefer forced tool choice over a textual nag so the failure isn't few-shotted into the transcript.
- **Forced tool choice with no terminal tool or no think tool.** Setting `tool_choice: required` without a `finish` in the allow-list means the model can never legitimately end the run; without a `think` no-op tool it can never reason without acting. Forced choice needs both escape hatches, or it traps the model.
- **Mid-stream tool execution.** Starting a tool call as soon as its delta arrives, before the assistant message finishes streaming. Sounds like a latency win; in practice it makes cancellation incoherent and breaks the contract that tool calls execute against a complete assistant message.

---
