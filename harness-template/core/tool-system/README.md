# Tool System — Recommended Architecture

> Layer brief. Detailed designs (permission models, parallel execution, schema normalization, MCP integration, etc.) belong in sibling pages here as they're drafted.

## TL;DR

The Tool System is the **only sanctioned path to side-effects** in the harness. It owns the registry of callable capabilities, the schema normalization across providers, the **permission gate**, the dispatch pipeline (with parallelism policy), and the result formatting that the runtime appends to the conversation. Like the Model Pool and the Sub-Agent Pool, it has **transport adapters** underneath that hide where a tool actually runs — in-process, via MCP, via shell, via HTTP. Together with those two it forms the [three-Pool pattern](../README.md#the-three-pool-pattern).

Sub-agent invocation is exposed to the model through this layer too: the [Sub-Agent Pool](../sub-agent-pool/) auto-registers "delegate" tools that the model calls like any other tool; the Tool System routes them to the Pool.

---

## Why this belongs as its own layer

If any layer other than the Tool System can produce side-effects, the harness has lost the central guarantee that *every observable change to the outside world goes through one gate*. Three things attach to that gate and only that gate:

1. **Permission policy** — which tools require approval, what kind, from whom, with what timeout, with what default behavior on timeout.
2. **Audit and observability** — what was called, with what arguments, returning what result, in which conversation, by which agent (parent vs sub-agent vs delegate).
3. **Sandbox enforcement** — what file system, what shell, what network, what credentials. The sandbox is a property of the dispatch context, not of the tool definition.

If permission, audit, or sandbox enforcement live anywhere else, multiple call sites have to coordinate and they'll drift. Gather them all on the Tool System.

A second framing that pays off: **the Tool System is to "things the model can do" what the [Model Pool](../model-pool/) is to "things the model can run on" and the [Sub-Agent Pool](../sub-agent-pool/) is to "things the model can delegate to."** Same registry / capability-query / dispatch / transport-adapter shape.

---

## Recommendation (overview)

Detailed designs for each bullet below are sibling pages (or live elsewhere when noted). This README is the architectural framing.

- **Tool registry entry shape.** Id, description (model-facing), JSON-Schema parameters, capability metadata (read-only vs mutating, parallelizable, sensitive), permission policy, transport binding. Mirror of the Model Pool / Sub-Agent Pool entry shape.
- **One typed `registerTool(...)` plus per-capability registration helpers.** Single canonical surface; capability-specific helpers (`registerWebSearchProvider`, `registerImageGenerationProvider`) for tools that have stronger contracts than "function with JSON schema."
- **Provider-aware schema normalization, centralized.** Some providers reject `anyOf`/discriminated unions in tool schemas. Normalize once at registration, not in every provider plugin..
- **Permission gate as a structured pipeline.** `before_tool_call` returns `requireApproval: { title, description, severity, timeoutMs, timeoutBehavior, onResolution(decision) }`. Approvals deliver as native UI cards on the surface the user is on (Slack/Discord/MS Teams) with `/approve` as fallback. Elevated mode (`tools.elevated`) is an explicit per-tool sandbox-bypass path.
- **Tool policy lives at the Gateway, separate from the model's prompt.** Per-agent `tools.allow` / `tools.deny` lists block tool calls regardless of what `SOUL.md` / `AGENTS.md` says. Two layers — prompt-level guidance and Gateway-level hard enforcement — survive prompt injection.
- **Tool-result middleware as a runtime-neutral seam.** `registerAgentToolResultMiddleware()` rewrites tool results after execution and before they're returned to the model. Distinct from `tool_result_persist` (which rewrites transcript writes). The split matters because runtime delivery and transcript persistence have different consistency requirements.
- **Parallelism policy.** Per-session lane (one active run per session) plus a global lane (`main` defaults to 4, `subagent` to 8). Parallel batches require all-pure tools; any mutating tool serializes the batch. Transcript writes use a process-aware file-based lock with explicit reentrant opt-in.
- **Result formatting.** Text vs structured payloads, image handling at multiple stages (sanitize before logging/emitting, preserve recent turns byte-for-byte, replace older processed images with markers to keep prompt-cache prefixes stable). `tokenjuice`-style compaction tools for noisy `exec`/`bash` outputs as a separate tool the agent can opt into.
- **Tool-pair safety.** Compaction must never split `tool_use` from `tool_result`; the boundary moves to keep the pair together. Six-of-six invariant — see [../context-engine/compaction.md](../context-engine/compaction.md).
- **Tool discovery and surfacing.** Deterministic ordering for registries / plugin lists / file-system results before payloads ever hit the model, to keep the prompt cache stable across runs.

---

## What consumes the Tool System and what it consumes

**Consumers (callers):**
- The [Agent Runtime](../agent-runtime/) dispatches tool calls emitted by the model.
- The [Sub-Agent Pool](../sub-agent-pool/) auto-registers delegate tools into the Tool System and consumes the dispatch path for them.
- Slash-command surfaces resolve commands to tool invocations.

**Backends (transport adapters underneath):**
- In-process function tools (the simplest case).
- MCP servers (stdio, SSE, HTTP) — tools provided by external processes.
- Shell-tool adapters (sandboxed bash / Python / etc.).
- HTTP / gRPC service adapters.

**Reads from registries:**
- Tools registry (its own).
- Skills registry (a Skill bundle can contribute tools).

---

## Open design questions (not yet drafted as sibling pages)

These are the topics that need substantive treatment as sibling pages in this folder; the bullets here are the research-stage notes carried forward from before the architecture lock-in.

- **Tool schema and registration.** Declarative vs imperative APIs; JSON-Schema vs framework-specific shapes; how schemas are versioned.
- **Permission models in detail.** Allow/deny lists, per-call user prompts, sandboxed defaults, escalation paths..
- **Tool-result middleware split.** Runtime-neutral middleware vs transcript-write hooks.
- **Parallel execution.** When to allow it, ordering guarantees, conflict handling..
- **Result formatting and image sanitization.**.
- **Tool-pair safety with compaction.** The invariant that compaction never splits `tool_use` from `tool_result`.
- **Tool discovery and surfacing mid-session.** How new MCP-provided tools get announced; deterministic ordering rules.
- **Tool-use summaries.** Short labels generated after each tool batch for SDK display. Some implementations use a fast/cheap model for git-commit-subject-style 3-5 word summaries of each tool batch.

---
