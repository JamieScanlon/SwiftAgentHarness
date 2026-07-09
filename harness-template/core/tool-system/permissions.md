# Tool Permissions — Classification and Policy

> Sibling page of [tool-system/README.md](./README.md). This is the *classification* half of the approval story: which tools exist for an agent, which calls need a decision, and who may escalate. The *delivery* half — how an "ask" reaches a human and comes back — is [approval-ux](../../surfaces/interface/approval-ux.md). The hook mechanics that carry decisions are on [extensibility](../../cross-cutting/extensibility/README.md).

## TL;DR

Permissions are **two planes, both owned by the Tool System**. The *availability plane* filters the registered tool list before the model ever sees it: layered allow/deny policies that **intersect** (a tool must survive every layer) with **deny always winning** and a non-empty allowlist meaning default-deny. The *gating plane* decides per call, at dispatch time, among exactly three outcomes — **allow / ask / deny** — because danger is usually in the *arguments* (the command line, the file path), not the tool name. Every decision carries a typed *reason* (which rule, which mode, which hook, which classifier) so audit and "why was this blocked" tooling come for free. Rules use a tool-name-plus-argument-matcher grammar (`exec(npm run *)`, path globs for file tools) over *normalized* tool names. Permission *modes* are named presets over these primitives, not a second policy system. Sandboxed execution is what makes permissive defaults tolerable — the policy that applies depends on the execution context, and escalation out of the sandbox is a typed, sender-allowlisted mode whose approvals bind the exact approved action to the executed one.

---

## The two planes: availability vs. gating

**Availability** is decided when the tool list is assembled for a turn. A tool denied here is not "ask" — it is *absent*: not in the schema block, not callable, invisible. This plane is cheap, cache-stable (the filtered list is deterministic per config), and — critically — robust to prompt injection: no text in the context window can call a tool that was never registered into the turn.

**Gating** is decided when the model actually emits a call. The same tool can be harmless or destructive depending on arguments — a shell tool running `rg -n TODO` versus `rm -rf ~`. So the dispatch pipeline runs a per-call decision (the `before_tool_call` hook seam; see [extensibility](../../cross-cutting/extensibility/README.md)) that returns **allow**, **deny**, or **ask** — the last producing a surface-agnostic approval request that [approval-ux](../../surfaces/interface/approval-ux.md) delivers.

Keep the planes distinct. Folding availability into gating ("register everything, deny at dispatch") wastes context tokens on uncallable tools and leaks their existence to the model. Folding gating into availability ("if it's risky, don't register it") loses argument-level discrimination — you end up denying the whole shell tool because *some* commands are dangerous.

---

## Recommendation

### Layered resolution: intersection, deny-wins, closed-world allowlists

Resolve availability through an ordered pipeline of policy scopes, each a `{ allow?, deny? }` record. The scopes that recur across production harnesses, outermost first:

1. **Profile** — a named base allowlist (`minimal`, `coding`, `messaging`) selected per agent or per provider.
2. **Global policy** — instance-wide `tools.allow` / `tools.deny`.
3. **Provider-specific policy** — overrides keyed by provider or provider/model, for models that can't be trusted with (or don't support) certain tools.
4. **Per-agent policy** — the agent's own allow/deny.
5. **Group/channel policy** — restrictions attached to where the conversation lives (a group chat may deny tools a DM allows).
6. **Sandbox policy** — an extra slice applied *only when the session is sandboxed* (see below).
7. **Mode slice** — the active conversation mode's `.tools` view ([modes](../conversation-manager/modes.md)); composes by intersection with the conversation-level whitelist.
8. **Per-run whitelist** — an optional further narrowing passed with a single run.

Three invariants make the pipeline predictable:

- **Intersection, never union.** A tool must pass *every* scope. Merging scopes by union is the classic privilege-escalation bug: a permissive global rescuing a tool the agent config deliberately denied.
- **Deny beats allow at every layer.** There is no layer whose allow can override another layer's deny. Tool policy is the hard stop — even the escalation machinery below cannot resurrect a denied tool.
- **Non-empty allow = closed world.** If a scope lists any allows, everything unlisted is blocked in that scope. An empty or absent allowlist means "no opinion," not "allow nothing."

Two operational details worth copying: **warn, don't fail, on unknown allowlist entries** (config written for a plugin that isn't loaded, or a core tool unavailable under the current provider — a startup failure for a stale entry is worse than a deduplicated warning naming the entry and the fix); and **structural denials for sub-agents** — control-plane, scheduling, and direct-messaging tools are denied to sub-agents unconditionally, with a wider deny list for leaf agents than for orchestrators (see [agent-orchestration](../sub-agent-pool/agent-orchestration.md)).

### The rule grammar

Rules need three levels of specificity:

- **Bare tool name** — `exec`, `read`. Match on *normalized* names: lowercase, aliases resolved (`bash` → `exec`), legacy names from renames mapped to canonical ones. An unnormalized match is how a rename silently opens a hole — the deny list still says `bash`, the tool now registers as `exec`.
- **Group aliases** — `group:fs`, `group:runtime`, `group:web`, plus plugin ids and `group:plugins` expanding to a plugin's contributed tools. Groups are maintained by the registry, so policy files survive tool additions ("deny everything that can touch the network" keeps meaning that).
- **Argument matchers** — `tool(pattern)`: `exec(npm run *)`, `web_fetch(https://internal.corp/*)`, path globs for file tools. Parentheses in content are escaped; command patterns match either a bare command name (PATH-invoked only — `rg` matches `/opt/homebrew/bin/rg` but not `./rg`) or a full path glob when you want to trust one binary location. **Canonicalize paths before matching** — resolve symlinks and `..` on the *argument*, and forbid traversal segments in the *pattern* — or path rules are bypassable by construction.

For evaluation order, prefer **deny-wins over declaration-order first-match**. First-match-in-order (used by one studied harness's filesystem middleware, with a permissive default when nothing matches) is simpler and composes nicely per-sub-agent, but it couples correctness to rule ordering and its permissive default inverts the safe failure mode. If you adopt it anyway, make the default explicit and lint for unreachable rules.

Compound inputs decompose: a shell chain like `echo ok && ./deploy.sh` passes only if *every top-level segment* passes, and the composed decision records per-segment reasons. Matching the raw string instead of parsing the chain is one of the two grammar bypasses that recur in practice (the other is uncanonicalized paths).

### Every decision carries a reason

The gating plane's output is not a boolean. It is `{ behavior: allow | ask | deny, reason }` where reason is typed: *rule* (which rule, from which scope), *mode* (which mode preset), *hook* (which plugin), *classifier* (below), or *composition* (the per-segment map for compound commands). Reasons feed four consumers: the audit stream ([observability](../../cross-cutting/observability/README.md)), a user-facing "why was this blocked" explainer with the fix-it config key, shadowed-rule detection (an allow that can never fire because a broader deny precedes it), and denial-pattern telemetry. Deciding without recording *why* costs nothing today and everything the first time an operator asks which config line to change.

### Permission modes are presets, not a second system

Interactive harnesses converge on cycling modes: *default* (rules decide, unknown → ask), *plan/read-only* (mutating tools denied wholesale), *accept-edits* (file edits auto-allowed, exec still gated), *bypass* (everything auto-allowed), sometimes *auto* (classifier-assisted, below). Implement each mode as a **registry record over the same primitives** — a `.tools` slice plus a default-decision override, with display metadata (title, symbol, color) for surfaces that render a mode indicator — not as branches in the dispatch path. Two hard rules: **bypass needs a killswitch** — an instance-level config that forces deny for designated tools even in bypass mode, because "I turned off approvals" must not mean "nothing can ever be blocked"; and **mode transitions are hookable** (entering plan mode swaps the tool slice; *exiting* it is itself an approval-gated action — the exit request is a classified approval like any other, not free text).

### Sandboxed defaults: policy depends on execution context

Sandbox, tool policy, and elevation answer different questions — *where* code runs, *what* is callable, and *how to escape* — and the three compose (see [execution-environments](../../backends/execution-environments/README.md)). The permission-relevant consequences:

- **A sandbox-only policy slice.** `tools.sandbox.tools.allow/deny` applies only while the session is actually sandboxed. This is what lets a sandboxed agent default toward *allow* (the blast radius is the container) while the same agent unsandboxed defaults toward *ask*.
- **Effective policy is the stricter of requested and host-local.** When execution crosses onto a real host, the host keeps its own approvals state; config requesting `ask: on-miss` cannot loosen a host whose local state says `ask: always`. The host a command runs on gets the last word, always.
- **Ship an `explain` inspector.** A debug command that prints the effective tool list and, per blocked tool, *which scope* blocked it and the config key that would change it. The pipeline has eight scopes; without the inspector every denial becomes a support thread.

### Escalation paths

Escalation is the controlled inverse of the deny rules, and every path is *scoped, attributed, and bounded*:

- **Elevation** (sandbox escape for exec) is a session-scoped mode with an inline per-message variant, gated by *both* an instance/agent enable flag and a **per-sender allowlist** — what the agent may do and who may authorize it are independent checks. Elevation never overrides tool policy: a denied `exec` stays denied. Full treatment on [execution-environments](../../backends/execution-environments/README.md).
- **Durable grants** ("allow always") are *writes of a new rule into a named scope* — session, project, or user — through the same rule grammar, with provenance retained. There is no separate "remembered approvals" store to drift out of sync; an allow-always answer to `exec(npm test)` simply appends that rule where the user chose. Harden the automatic ones: inline interpreter evals (`python -c`, `node -e`) stay approval-only even when the interpreter binary is allowlisted, and never mint durable rules from them.
- **Approval binding.** An approval is a contract about a *specific* action. Bind the approved run to its canonical form — exact argv, cwd, and where feasible a content hash of the script file being invoked — and reject at execution if anything drifted. Approve-then-swap (edit the script between approval and execution) is the TOCTOU attack the binding exists to stop; if the binding can't identify exactly one concrete target, refuse to mint the approval rather than pretend coverage.
- **Denial hygiene.** A denied approval must also poison the session's memory of *prior* runs of the same command, or the model helpfully "reuses" stale output and defeats the denial.

### Ask-machinery defaults

Every ask carries a **timeout and a timeout behavior** (deny is the right default; a queue that waits forever is a hung turn). Separately, an **unreachable-UI fallback** decides what happens when nobody can be asked at all — headless runs, dead surface: *deny*, *allowlist-only*, or *allow*, defaulting to deny. Ask frequency is its own knob (*off* / *on-miss* — prompt only when no allowlist rule matched / *always*), and a durable allow-always grant does not suppress prompts when the effective mode is *always*. Convenience trust — e.g. auto-allowlisting the binaries shipped by installed skills — is fine as an explicit opt-in inside one trust boundary, never as a silent default.

### Classifier-assisted gating (optional layer)

One studied harness adds an LLM layer: a fast model reads the transcript and the pending command and auto-approves calls a human predictably would. Constraints that keep it safe: it sits **between** the rules and the human — deny rules and the killswitch still win, and it can only convert *ask* → *allow-once*, never mint durable grants; its approvals are labeled with a *classifier* reason so they're auditable and rate-measurable; it runs with thinking disabled and a tight token budget (it's on the latency path of every gated call); and its transcript is dumpable for debugging misclassification. It is advisory automation over the rule system, not a replacement for it.

---

## Alternatives

### Declaration-order rule lists with permissive default

First matching rule wins; no match → allow. Used per-sub-agent by a graph-middleware harness for filesystem scoping, where each sub-agent gets a short, locally-reasoned list. Attractive for its composability; rejected as the *general* model because the permissive default fails open and correctness couples to ordering. Viable inside an already-sandboxed scope.

### File/mailbox-based approval routing for swarms

A leader-worker harness routes permission requests as files in `pending/` and `resolved/` directories (or mailbox messages): workers write requests, the leader lists and resolves them. This is a *delivery* topology, not a classification model — classification stays as above; the pattern earns its place when workers have no UI and the leader is the only human-adjacent process. See [approval-ux](../../surfaces/interface/approval-ux.md) for the general delivery story.

### A `dangerous: boolean` per tool

The floor. It can't express argument dependence (all shell commands equally dangerous), scope dependence (dangerous in a group chat, fine in the operator DM), or context dependence (sandboxed vs not). Every harness that starts here grows the layered system above; start with the layered system.

---

## Anti-patterns

- **Union-merging policy scopes.** A tool denied per-agent but allowed globally must stay denied. Union is privilege escalation with a config-shaped face.
- **Matching unnormalized names or raw command strings.** Alias drift (`bash` vs `exec`), legacy tool renames, and unparsed shell chains (`safe-cmd && rm -rf ~`) are the three standard grammar bypasses. Normalize names, parse chains, canonicalize paths.
- **Allow rules that shadow nothing.** An allowlist entry that a broader deny makes unreachable is a config lie. Detect and warn — the shadowed rule is usually the fossil of a security decision someone thinks is still in force, or the intended fix that never applied.
- **Approval without binding.** Approving "the command" while executing whatever string the caller holds *now* invites approve-then-swap. Bind argv/cwd/content at approval; reject on drift.
- **Model-controllable escape flags.** A `dangerously_skip_sandbox: true` tool parameter without sender-allowlist machinery lets the model request its own elevation in-band. Escape hatches are session modes granted out-of-band, or they are holes.
- **Prompt-only enforcement.** "You may not use the browser tool" in the system prompt is guidance, not policy; injection removes it. The Gateway-level allow/deny survives because it never passes through the context window.
- **Per-tool bespoke approval flags.** Each tool growing its own `requires_approval` + message format fragments classification across the codebase and couples it to surfaces — the same trap as per-tool permission UI components ([approval-ux, cautionary tale](../../surfaces/interface/approval-ux.md)).
- **Ask-by-default without timeout defaults.** An ask with no `timeoutBehavior` is an unbounded hang on every headless surface.

---

## Cross-references

- [approval-ux](../../surfaces/interface/approval-ux.md) — delivering the *ask*: `MessagePresentation` cards, `/approve` fallback, decision vocabulary (`allow-once | allow-always | deny | timeout | cancelled`), core-owned lifecycle.
- [extensibility](../../cross-cutting/extensibility/README.md) — the `before_tool_call` hook seam, the `requireApproval` structured return, block-beats-approve, decision-vs-observation hook typing.
- [execution-environments](../../backends/execution-environments/README.md) — sandbox modes/scopes, elevated mode, exec-approval flow at the exec boundary.
- [modes](../conversation-manager/modes.md) — the mode's `.tools` slice and intersection with conversation whitelists.
- [agent-orchestration](../sub-agent-pool/agent-orchestration.md) — structural sub-agent denials by role and depth.
- [observability](../../cross-cutting/observability/README.md) — where decision reasons land: audit bus, denial telemetry, redaction at the emit boundary.
