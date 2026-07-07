# Personality (The Voice Surface) — Recommended Architecture

## TL;DR

"What does my agent feel like to talk to" is an **interface concern** — it shapes the output surface — even though the file that holds it is *stored* like memory and *injected* like any other prompt section. This page goes deeper than the [interface README](./README.md) (§ Rec 10) on the voice/tone file and the return affordances that frame a session.

The prescriptive shape:

1. **Keep a voice/tone file separate from the operating-rules file.** Personality — tone, opinions, brevity, humor, boundaries, default bluntness — lives in a dedicated `SOUL.md`-style file, *distinct* from the `AGENTS.md`-style file that holds operating rules and procedures. Conflating "what the agent *sounds like*" with "what the agent *does*" makes both harder to tune.
2. **Personality has three owners, one per verb.** It is *authored* as an interface concern (it shapes the output surface), *injected* by the [Context Engine](../../core/context-engine/) (assembled into the system prompt), and *stored* as a workspace instruction file (a [Memory](../../core/memory/) concern). This page owns only the "what the agent feels like" framing; it cross-links the other two.
3. **The file is opinionated and short.** It carries behavioral instructions that *change how the agent feels* — "have a take," "skip filler," "short beats long, sharp beats vague" — not a backstory, a changelog, or a wall of vibes with no behavioral effect. Treat it like a prompt you iterate, pin, and evaluate.
4. **An away-summary is a separate, throwaway affordance.** When a user returns after stepping away, a *small-fast-model* call over the last ~30 messages (plus session memory) produces a 1–3 sentence "here's the task and the concrete next step" recap. It is deliberately **not** part of the compaction pipeline — different model, different trigger, throwaway output, skips the cache write.
5. **Output styles are the lightweight cousin.** A simple output-style setting (terse / formal / playful) is the low-effort end of the same spectrum; the voice file is the high-control end. Offer both.

The thesis: personality is the surface's *voice*, authored where the surface is reasoned about, kept separate from rules so each can be tuned, and assembled by the Context Engine into the prompt.

---

## Where this fits

Most of the interface layer is about *channels of output* — how text, buttons, and UI reach a surface. Personality is the **content of the voice** that flows through them: the consistent character a user experiences regardless of whether they're on a terminal or a chat app. That's why it's an interface concern — it's a property of the output surface, "what talking to this agent is like" — even though, mechanically, it's a file the Context Engine injects.

The clean way to hold this is a **three-way ownership split by verb**, because personality genuinely touches three layers and muddling them causes the usual problems:

| Verb | Owner | Why |
|---|---|---|
| **Authored** | Interface (this page) | It shapes the output surface; it's reasoned about as "the agent's voice" |
| **Stored** | [Memory](../../core/memory/) | It's a workspace instruction file alongside the rules file |
| **Injected** | [Context Engine](../../core/context-engine/) | It's assembled into the system prompt each turn |

This page claims only the *authored* verb — the framing that personality is a surface concern worth designing deliberately. The storage mechanics (a workspace instruction file, discovery, precedence) are Memory's; the assembly (where in the system prompt it lands, cache boundary) is the Context Engine's.

---

## Recommendation

### A voice/tone file, separate from the rules file

Keep two distinct workspace instruction files:

- **The voice/tone file** (`SOUL.md`-style) — *how the agent sounds*: tone, opinions, brevity, humor, boundaries, default level of bluntness.
- **The operating-rules file** (`AGENTS.md`-style) — *what the agent does*: procedures, conventions, project facts, tool-use rules.

The separation is the recommendation, and it's load-bearing for *tunability*. Voice and rules change for different reasons and at different cadences: you tweak tone after a reply felt "off"; you tweak rules after a procedure changed. Jammed into one file, a personality edit risks a rules regression and vice versa, and neither can be reasoned about cleanly. Two files, two concerns, two iteration loops.

Inject the voice file on **normal** sessions so it has real weight in shaping replies. (A purely mechanical sub-task — a one-shot extraction, a sub-agent doing a narrow job — may not need it; that's a Context-Engine assembly decision.)

### What belongs in it — and what doesn't

The file is *opinionated behavioral instruction*, not lore. It should change how the agent *feels to talk to*:

- **Belongs:** tone, opinions ("have a take"), brevity ("skip filler"), humor, boundaries, bluntness. Concrete and behavioral — "short beats long, sharp beats vague."
- **Doesn't belong:** a life story, a changelog, a security-policy dump, a giant wall of vibes with no behavioral effect.

Two disciplines make it work:

- **Short beats long.** A concise, sharp voice file has more behavioral effect than a long one; length dilutes. High-level behavior, tone, and a few examples in the high-priority instruction layer beat paragraphs of prose.
- **Iterate, pin, evaluate.** Treat it like a prompt you version and test, not magical text written once. Stable personality comes from concise, versioned instructions, not from volume.

This is also a safety boundary: keeping personality *behavioral and short* avoids the failure mode where a sprawling "vibes" file quietly overrides brevity or safety norms buried elsewhere.

### Ownership: authored here, injected and stored elsewhere

Spelled out, because the three-way split is the thing teams get wrong:

- **Authored as an interface concern.** Whoever designs the surface designs the voice — it's part of "what this product feels like." That's the framing this page owns.
- **Injected by the Context Engine.** The file is assembled into the system prompt like any instruction section, above the cache boundary so it doesn't churn the prompt cache ([Context Engine](../../core/context-engine/)). The interface doesn't inject it directly.
- **Stored as a workspace instruction file.** It lives alongside the rules file under the workspace, discovered and precedence-ordered by [Memory](../../core/memory/). The interface doesn't own a storage path.

The reason to be explicit: a team that treats personality as "just another memory file" loses the *authored-as-surface* framing and ends up with bland, hedged voice; a team that treats it as a hardcoded interface string loses the *stored-and-versioned* property and can't tune it per workspace. It's all three.

### The away-summary / idle-return recap

A high-value, low-cost affordance for any surface a user steps away from (a chat they background, a long-running session): when they return, greet them with a *recap* instead of a wall of scrollback.

The discipline that makes it good — and the reason it's **not** compaction:

- **A separate small-fast-model call**, over only the recent window (~last 30 messages) plus session memory — not the whole transcript.
- **Output is tiny and shaped:** 1–3 short sentences stating the high-level task and the concrete next step. Not a commit-style recap of everything done; a "here's where we are, here's what's next."
- **Different trigger** (user returns / session idle-then-active), **different model** (cheap/fast), **throwaway output** (it's a greeting, not history), and it **skips the cache write** so it never pollutes the prompt cache or the compaction state.

Folding this into the [compaction](../../core/context-engine/compaction.md) pipeline is the tempting mistake: compaction is triggered by context pressure, uses the working model, and produces durable summary state. The away-summary is triggered by *attention* (the user came back), wants a *cheap* model, and is *disposable*. Same "summarize recent activity" verb, completely different parameters — keep them separate.

### Output styles: the lightweight cousin

Not every deployment wants to author a voice file. A simple **output-style setting** — a small enum or short directive (terse, formal, playful, verbose) — is the low-effort end of the same spectrum: less control than a full voice file, but zero authoring. Offer both ends: an output style for "I just want it less chatty," a voice file for "I want a designed character." They compose — a voice file sets the character, an output style nudges verbosity for a session.

---

## Alternatives

### Personality folded into the operating-rules file

Put tone and voice in the same file as procedures and project rules.

**When this works:** a tiny project where there are barely any rules and the voice is an afterthought — one short file is less ceremony.

**Why not as the default:** voice and rules have different edit cadences and failure modes; co-locating them means a personality tweak risks a rules regression, and neither concern can be tuned in isolation. The separation is cheap and pays off the first time you iterate on one without wanting to touch the other.

### Personality hardcoded in the interface

Bake the voice into a system-prompt string in the surface code.

**When this works:** a single-product agent whose voice is fixed and central to the brand, never customized per workspace.

**Why not as the default:** it loses the *stored-and-versioned* property — you can't tune voice per workspace, can't diff it, can't let a user shape their own agent. A workspace file the Context Engine injects keeps the authored-as-surface framing *and* per-workspace customization.

### No personality layer

Rely on the base model's default voice.

**When this works:** a purely mechanical tool where character is irrelevant.

**Why not for anything conversational:** the default is the bland, hedged, "corporate sludge" voice users react against. A short, opinionated voice file is a high-leverage, low-cost upgrade to how the product feels.

---

## Anti-patterns

- **Mixing personality into the operating-rules file.** Different cadences, different failure modes; co-location makes both harder to tune and risks cross-regressions. Keep the voice file separate from the rules file.

- **A long, lore-heavy voice file.** Backstory, changelogs, and walls of vibes dilute behavioral effect and can quietly override brevity/safety norms. Keep it short, behavioral, and versioned.

- **Hardcoding personality in surface code.** Loses per-workspace tunability and versioning. Store it as a workspace instruction file the Context Engine injects.

- **Treating personality as just another memory file.** Loses the authored-as-surface framing and produces bland voice. It's authored as an interface concern, even though stored like memory.

- **Folding the away-summary into compaction.** Different model, different trigger, throwaway output. A compaction-pipeline recap uses the wrong (expensive) model, fires on the wrong trigger, and pollutes durable summary/cache state. Keep it a separate small-fast-model call that skips the cache write.

- **An away-summary that recaps everything.** A commit-style "here's all 40 things we did" defeats the purpose. 1–3 sentences: the task and the next step.

- **Injecting the voice file below the cache boundary.** Personality is stable per session; putting it in the churning part of the prompt wastes cache. Assemble it above the cache boundary like other stable instructions.

---

## Cross-references

- [Interface README](./README.md) — § Rec 10; personality and return affordances as interface concerns.
- [Memory](../../core/memory/) — where the voice/tone file is *stored* as a workspace instruction file (discovery, precedence) alongside the rules file.
- [Context Engine](../../core/context-engine/) — where the file is *injected* into the system prompt, above the cache boundary.
- [context-engine/compaction](../../core/context-engine/compaction.md) — the pipeline the away-summary is deliberately kept *out* of.
- [Model Pool](../../core/model-pool/) — the small/fast model the away-summary call routes to.
