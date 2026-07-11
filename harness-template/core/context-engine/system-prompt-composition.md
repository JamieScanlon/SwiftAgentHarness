# System-prompt composition

## TL;DR

The system prompt is **not one string — it's a structured artifact of named sections**, assembled fresh each turn by the Context Engine's `assemble` phase from contributions that arrive through defined seams. Each section has exactly one owner; contributors fill or override sections *by name* and never receive the full string to mutate. Layering runs harness defaults → provider plugin (model-family overlay) → mode profile → workspace instruction files → per-conversation overrides → engine dynamic additions, with a **volatility-ordered layout**: stable sections above the cache boundary (byte-identical across turns, cached), per-turn material below it. Four levers of increasing strength serve every customization need — section directive, section suppression, section override, full-prompt override (escape hatch only). Sub-agents don't inherit the prompt; they get a *recomposed* task-scoped one (rules and tool notes, no persona or user files) — except forks, which must keep the prompt byte-identical to reuse the parent's cache. The assembled result can be recorded as a `SystemPromptAssembly` Checkpoint so "what did the model see on turn 17" is always answerable.

---

## Recommendation

### A structured artifact with named sections

The reference layout, in order:

```
[Identity]              who/what the agent is
[Capabilities]          what it can do (high-level, not a tool catalogue)
[Constraints]           hard rules — safety, scope, boundaries
[Personality]           the voice/tone file, when present
[Mode directive]        the mode-shaped behavioral block
[Memory]                frozen index snapshot + workspace instruction files
[Skills]                index of available skills (names + descriptions)
[Tool guidance]         high-level guidance about tool use
--- CACHE_BOUNDARY ---
[Attachments]           inline content or summaries of attached resources
[Extra instructions]    per-conversation prompt.extraInstructions
[Dynamic additions]     engine-contributed systemPromptAddition (recall hints, etc.)
```

Two properties make this a design and not just a list. **Single ownership:** each section is filled by exactly one contributor — Identity/Capabilities/Constraints by harness defaults, Personality by the voice file ([surfaces/interface/personality.md](../../surfaces/interface/personality.md) authors it, this layer injects it), Mode directive by the active mode profile ([conversation-manager/modes.md](../conversation-manager/modes.md)), Memory by the frozen snapshot ([memory-injection.md](./memory-injection.md)), Skills by the registry index (names and descriptions only — bodies arrive as tool results, per the [README](./README.md#what-consumes-the-context-engine-and-what-it-consumes)). Contributors don't fight over placement, and a missing contributor means a cleanly absent section, not a hole in a template. **Volatility ordering:** sections are arranged most-stable-first so the cache boundary can sit as low as possible — the layout is a caching decision as much as an attention decision.

### Contribution, not mutation

The single most important interface rule: **no contributor ever receives the assembled string.** The legacy pattern — a `before_prompt_build` hook handed the full prompt to mutate — is the one to retire. It makes contributions order-dependent (two hooks that both prepend fight over who runs first), unauditable (nobody can say which hook produced which line), and cache-hostile (a hook that touches the prefix invalidates it silently).

Instead, every seam speaks in sections:

```ts
interface PromptContribution {
  stablePrefix?: string                      // load-time, above the boundary
  sectionOverrides?: Record<SectionName, string>  // replace a named section
  sectionDirectives?: Record<SectionName, string> // append within a named section
  suppress?: SectionName[]                   // emit nothing for these sections
}
```

The Engine collects contributions, resolves conflicts by the layering order below, and emits the sections in the canonical order. The boundary between "what is this section about" and "what does this contributor say about it" stays explicit — which is what makes the assembled prompt debuggable when three plugins, a mode, and a workspace file all have opinions.

### The layering order

Contributions apply in a fixed sequence; later layers win where they collide:

1. **Harness defaults** — the base Identity, Capabilities, Constraints, Tool guidance. What the prompt says when nothing else is configured.
2. **Provider plugin (model-family overlay)** — named-section overrides tuned per model family: one family wants concise-output and persona-latching discipline, another wants extended-thinking framing, a small model wants tool-discipline shorthand. Contributed at *load time* into the stable prefix and section overrides — never per-turn. Full treatment in [providers § Cache boundary and prompt contributions](../../backends/providers/README.md#cache-boundary-and-prompt-contributions).
3. **Mode profile** — the four levers below, read from `ModeProfile.context` at assemble time.
4. **Workspace instruction files** — the Managed → User → Project → Local precedence walk from [memory.md § project-instruction files](../memory/memory.md#project-instruction-files), concatenated nearest-last so the most local file lands latest, plus the framing line asserting these override defaults. The voice/tone file rides this layer into the Personality section.
5. **Per-conversation overrides** — `prompt.extraInstructions` (appended below the boundary) and `prompt.systemOverride` (the whole-prompt escape hatch), both conversation state owned by the [Conversation Manager](../conversation-manager/README.md).
6. **Engine dynamic additions** — `assemble()` may return a `systemPromptAddition` alongside its messages: recall hints, re-injection notices, transient per-turn guidance. Always below the boundary; never persisted as configuration.

The order encodes a policy: *specificity beats generality*. A workspace file outranks a provider overlay because the user's project knows more about the task than the model family does; a conversation override outranks the workspace because the user said so *here*. The framing lines make the same hierarchy legible to the model — a prompt that layers silently produces a model that averages its instructions instead of prioritizing them.

### Four levers, increasing strength

Generalized from the mode-profile design ([modes.md § System-prompt assembly under modes](../conversation-manager/modes.md#system-prompt-assembly-under-modes)) — the same ladder applies to any contributor:

1. **Section directive** — append a block within a designated section (a mode's behavioral framing, a plugin's usage note). The common case; composes with everything.
2. **Section suppression** — turn whole sections off via flags, not prose. A chat mode suppresses Tool guidance, Skills, and Memory by *not emitting them*, which beats emitting them plus "ignore your tools" and hoping the model listens. Structural removal outranks textual countermanding, always.
3. **Section override** — replace a named section's content entirely. For contributors that need to redefine Identity or Capabilities, not decorate them. Heavier; most contributors never need it.
4. **Full-prompt override** — `prompt.systemOverride` replaces the entire assembled artifact. Least composable: memory injection, skills, extra-instructions, provider overlays all stop applying unless the override re-adds them by hand. Keep it as the escape hatch for "I know exactly what I want the model to see," and surface a warning when it's active — silent full overrides are the leading cause of "why is memory not working" reports.

### Cache discipline: the boundary is an invariant

The prompt cache saves money only if the cached prefix is byte-identical across calls, so the assembly enforces a **boundary marker** splitting the artifact ([providers § cache boundary](../../backends/providers/README.md#cache-boundary-and-prompt-contributions)):

- **Above the boundary:** sections whose content is fixed at session start — defaults, provider overlays, personality, workspace files, the frozen memory snapshot, the skills index. Contributed at load time; the contribution helpers *reject* per-turn writes to this region rather than trusting contributors to abstain.
- **Below the boundary:** everything that may legitimately change per turn — attachments, extra-instructions, dynamic additions.

Two events are *allowed* to rebuild the prefix, both user-meaningful and session-rare: a **mode switch** (the Mode directive sits above the boundary because it's stable *between* switches; a switch is worth one cache rebuild) and a **model/provider change** (the overlay layer changes by definition). Everything else that wants to vary goes below the line or waits for the next session — the same trade the frozen-snapshot pattern makes for memory, applied to the whole artifact.

### Assembly is per-turn, pure, and auditable

Composition runs inside `assemble()` as part of the standard projection — a pure function of `(rawEvents, derivedEvents, config)`, where config carries every contribution source. Nothing about the prompt is stored as a side string; the same inputs always produce the same artifact.

Persist it *optionally*: a `SystemPromptAssembly` Checkpoint (`{ atTurn, assembledPrompt }`) in `derivedEvents` records what the model actually saw, turn by turn. Recommended on for transparency UIs and debugging sessions, off by default in production (it duplicates a large, mostly-stable string per turn). Even off, the pure-function property means any turn's prompt can be *recomputed* on demand via `project(id, config?)` — auditable-by-reconstruction is the floor, checkpointed is the upgrade.

Section provenance belongs in the audit trail: each emitted section tagged with its contributor (`defaults`, `provider:<id>`, `mode:<id>`, `workspace:<path>`, `conversation`, `engine`). When a prompt misbehaves, "which layer said that" is the first question; make it answerable without diffing strings.

### Sub-agent composition: recompose, don't inherit

`prepareSubagentSpawn` composes a *different* prompt, not a copy. The default scoping rules:

- **Rules travel; persona doesn't.** Sub-agents get operating rules and tool notes. They do not get the Personality section, identity/user files, or conversational memory — a search delegate speaking in the main agent's voice is wasted tokens, and user-profile material in a task agent is a privacy leak with no upside.
- **Conventions are optional per agent type.** A read-only exploration agent can skip workspace instruction files entirely (`omitWorkspaceConventions`) — it reads code, it doesn't write it, and the conventions are prompt weight it will never use.
- **Task framing replaces Mode directive.** The spawner's task description is the sub-agent's behavioral block; the parent's mode is irrelevant inside the delegate.
- **The fork exception.** A forked sub-agent (compaction summarizer, memory extractor) exists *specifically* to reuse the parent's prompt cache — its prompt must be byte-identical to the parent's, tools and all. Fork = same artifact, new messages; spawn = recomposed artifact. Never blur the two: a "mostly forked" prompt pays full cache-creation cost while pretending not to.

### Trust and framing

Sections carry different trust levels, and the composition must say so rather than letting position imply authority:

- **Workspace instruction files** are user-controlled but attacker-authorable (a cloned repo). They get the content scan from [memory.md § content scanning](../memory/memory.md#project-instruction-files) before inclusion, and their framing line grants them precedence over *defaults* — not over the harness's Constraints section, which no file-sourced layer may override or suppress.
- **Memory-derived content** is agent-written historical data: fenced and demoted per [memory-injection.md](./memory-injection.md).
- **Engine dynamic additions** are machine-generated hints, framed as such.

The rule that ties it together: **the Constraints section is override-proof from any file- or conversation-sourced layer.** Only harness defaults and (deliberately, auditably) the full-prompt override can change it. A layering system where a repo file can suppress the safety section has built a privilege escalation, not a prompt assembler.

---

## Alternatives

**Single template string with interpolation slots.** One big template, `{memory}` / `{skills}` / `{mode}` placeholders filled at assemble time. Simple, readable in one file, and fine for single-surface harnesses with no plugin ecosystem. It breaks at the first third-party contributor: no suppression, no override-by-name, no provenance, and every new concern edits the shared template. The named-section model is the same idea with a contribution interface in front of it — start here only if plugins are definitively out of scope.

**Full-string mutation hooks (`before_prompt_build`).** Hand each plugin the assembled string, let it mutate. Maximum flexibility, and the legacy approach in more than one mature harness — kept only for compatibility, with named sections recommended in its place. Order-dependent, unauditable, cache-hostile. If an existing hook API must be preserved, run it *after* section assembly as an explicitly-marked compatibility stage, and document that using it forfeits provenance and cache guarantees.

**Per-model hardcoded prompts.** A complete bespoke prompt per model family, selected at session start. Honest about the fact that model families want different prompting — but it multiplies every future edit by the number of families and drifts immediately. The provider-overlay layer captures the same per-family tuning as deltas against one canonical artifact.

**Developer-message instructions instead of system-prompt sections.** Push per-turn guidance (mode framing, recall hints) into developer/user-role messages appended to the conversation rather than the system prompt. Attractive where providers price or cache system prompts poorly, and it keeps the system prompt purely stable. Costs structure: the guidance now lives in message history where compaction, trimming, and branching have to treat it specially. The below-boundary suffix achieves the same freshness without teaching every other transformation about instruction messages. Reasonable as a provider-specific codec decision; wrong as the architecture.

---

## Anti-patterns

- **Handing contributors the full prompt string.** The mutation-hook pattern makes composition order-dependent and unauditable, and one careless prepend invalidates the cache prefix for every subsequent call. Contributions are named-section records; nobody sees the whole artifact until it's assembled.

- **Per-turn writes above the cache boundary.** A contributor that "just updates one line" in the stable prefix costs a full cache rebuild per turn — silently, since the request still succeeds. Enforce the boundary in the contribution helpers; don't rely on convention.

- **Textual countermanding instead of suppression.** Emitting the Skills section and adding "you are in chat mode, ignore your skills" leaves both instructions in context, and the model averages them. If a section shouldn't apply, don't emit it.

- **Full-prompt override as routine configuration.** `systemOverride` set in a template or shipped in a mode default means memory, skills, and overlays are silently dead for every conversation that inherits it. Escape hatch, per-conversation, with a visible indicator when active.

- **A tool catalogue in the prompt.** Tool schemas already travel in the request's tool block; re-listing them in Capabilities or Tool guidance duplicates tokens and drifts from the registry. The prompt carries *guidance about* tool use, never the inventory.

- **Persona and user files in sub-agent prompts.** Wasted tokens at best; a privacy leak at worst. Recompose task-scoped prompts for spawns; reserve inheritance for forks, where byte-identity is the entire point.

- **"Mostly forked" prompts.** A fork whose prompt differs from the parent's by one section pays full cache-creation cost while the code assumes it doesn't. Fork means byte-identical; anything else is a spawn and should be composed as one.

- **Registration-order-dependent assembly.** If loading plugin A before plugin B changes the prompt, composition has no defined layering. The layer order is fixed and documented; within a layer, contributions target disjoint sections or the conflict is a reported error, not a silent last-writer-wins.

- **File-sourced layers overriding Constraints.** A workspace file that can rewrite or suppress the safety section is a privilege escalation delivered via `git clone`. Constraints are override-proof from below; the framing line grants files precedence over defaults, not over hard rules.

- **Unanswerable "what did the model see."** If reproducing turn 17's prompt requires archaeology, every prompt bug becomes speculation. Pure-function assembly plus on-demand `project(...)` is the floor; `SystemPromptAssembly` Checkpoints and per-section provenance tags are the debugging upgrade.

---
