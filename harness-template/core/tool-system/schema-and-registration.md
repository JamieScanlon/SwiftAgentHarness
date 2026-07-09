# Tool Schema & Registration

> Sibling page of [tool-system/README.md](./README.md). This is the shape of a registry entry, the API that creates one, the canonical schema format and its provider-aware normalization, and what "versioning a tool" actually means. The policies that *consume* the entry are on [permissions](./permissions.md); the plugin machinery that *delivers* entries from bundles and MCP servers is on [extensibility](../../cross-cutting/extensibility/README.md).

## TL;DR

A tool is a **typed record, not a class** — id, model-facing description, JSON-Schema parameters, capability metadata, permission binding, transport binding — created through one canonical `registerTool(...)` surface and completed by a **builder that fills fail-closed defaults** (not concurrency-safe, not read-only, empty classifier input) so forgetting a field can only make a tool *safer*. Capability metadata is **predicates of the input, not static booleans**: a shell tool is read-only under `ls` and destructive under `rm -rf`, so `isReadOnly(input)` is a function or it is a lie. **JSON Schema is the canonical parameter format**, whatever typed authoring layer produced it, and provider quirks are handled by **one central normalization seam** — strict-variant transforms, per-provider keyword stripping, sanitization of malformed third-party schemas — never by fixes scattered through provider plugins. Versioning is done with **names, not version numbers**: aliases and a legacy-name map keep renamed tools resolvable by old permission rules, hooks, and persisted transcripts, and the description is treated as change-controlled prompt text.

---

## Recommendation

### The registry entry: a typed record with fail-closed defaults

The entry shape that recurs, mirroring the Model Pool and Sub-Agent Pool registries:

- **Identity** — `name` (normalized; see the [rule grammar](./permissions.md)), optional `aliases` for renames, a `searchHint` phrase for deferred-tool keyword lookup.
- **Model-facing text** — the description. It may be *context-dependent* (a function of session state, permission mode, active tool set) rather than a static string; the richest implementations compute it per turn.
- **Parameters** — JSON Schema (canonical form; below), plus an optional structured output schema.
- **Capability metadata as input predicates** — `isReadOnly(input)`, `isConcurrencySafe(input)`, `isDestructive(input)`, `isOpenWorld(input)`. These feed the parallelism policy, the permission gate's severity defaults, and UI collapse rules. They take the *arguments* because tool danger is argument-dependent — the same insight that shapes the [permission rule grammar](./permissions.md).
- **Permission binding** — an optional `checkPermissions` for content-specific rules, defaulting to "defer to the general gate."
- **Operational bounds** — a max result size before disk-spill, an interrupt behavior (`cancel` vs `block` when the user sends a new message mid-run), deferred-loading flags (`shouldDefer` / `alwaysLoad`) for harnesses that lazy-load tool schemas.
- **Transport binding** — in-process function, MCP server+tool (with the unnormalized origin names retained), shell adapter, HTTP.

Route every entry through a **builder that completes partial definitions with fail-closed defaults**: enabled, *not* concurrency-safe, *not* read-only, not destructive, permissions deferred, classifier input empty (so security-relevant tools must opt in to auto-approval). The point of the builder is that defaults live in one place and an omitted field degrades toward safety — an author who forgets `isConcurrencySafe` gets serialization, not races.

### One canonical registration surface

Expose a single typed `registerTool(toolOrFactory, opts?)`. Two details earn their keep:

- **Factory form with trusted context injection.** A registration can be a factory receiving a trusted context — workspace dir, agent id, session key, whether the sender is the owner, whether the session is sandboxed — and returning the tool (or several, or none for "not applicable here"). Tools close over *runtime-supplied* facts instead of trusting model-supplied arguments for identity or paths; this is the registration-time face of the input-provenance rule ([triggers](../../surfaces/triggers/input-provenance.md)).
- **`optional: true`** — registered but dormant until config allows it, so plugins can ship tools that don't expand every agent's tool block by default.

Alongside the canonical surface, keep **per-capability helpers** (`registerWebSearchProvider`, `registerImageGenerationProvider`, ...) for tools with stronger contracts than "function with JSON schema" — the helper enforces the richer interface, then registers through the same path. Declarative authoring sugar (decorators deriving schema from function signatures, as the graph-framework ecosystem does) is fine as an *authoring layer*, provided it compiles into the same record — the registry should not know how the entry was written.

### JSON Schema is canonical; normalization is centralized

Author schemas in whatever typed layer you like (runtime validator libraries give you parsing for free); the *registry* form is JSON Schema, because that is what every provider, MCP, and grammar backend consumes. Then face the real problem: **providers disagree about JSON Schema**, and the disagreements are load-bearing:

- Strict-mode tool calling on one major provider family rejects `anyOf`/`oneOf`/`allOf`, array-valued `type`, and objects without `additionalProperties: false`, and wants `required` filled explicitly.
- Another family needs its own cleaning pass (unsupported keywords stripped per a model-compat table).
- Grammar-constrained local backends reject shapes cloud providers silently accept: bare `{"type": "object"}` with no `properties`, schema values that are strings instead of objects, nullable type arrays.
- Third-party MCP servers ship *malformed* schemas (e.g. `additionalProperties: "object"`), which must be repaired, not trusted.

Handle all of it at **one seam, at registration or prompt-assembly time — never inside provider plugins**. The seam: normalize into a *deep copy* (registry entries stay pristine), apply the provider/model-specific transform chosen from a compat table, and emit **diagnostics that name the tool and the violation** when a schema can't be made compatible — a tool that silently vanishes for one provider is a debugging nightmare; a startup line reading `tool[web_search].parameters: anyOf unsupported in strict mode` is a fix. Degrading lossy transforms deserve care: collapsing an `anyOf` of constants into an `enum` preserves semantics; dropping a variant does not.

### Versioning: names are the API

No studied harness versions tool schemas with version numbers, and the template doesn't prescribe them. What actually needs versioning:

- **The name.** Renames happen. Keep `aliases` on the entry *and* a global legacy→canonical map applied wherever names enter the system — permission rules, hook filters, persisted transcripts, wire formats — so a rule written against the old name still binds ([permissions](./permissions.md) matches on normalized names for the same reason). Never reuse a retired name for different semantics; old transcripts and rules re-bind to the wrong tool.
- **The parameters.** Evolve additively: new parameters optional with defaults; never repurpose an existing field's meaning. If semantics must change incompatibly, that's a *new tool name* with the old one aliased or retired.
- **The description.** It is prompt text: editing it changes model behavior with no code diff and no test failure. Treat description changes as change-controlled (reviewed like a prompt change, noted in the changelog), not as doc polish. SwiftAgentHarness documents the operational process in [`docs/process/tool-description-change-control.md`](../../../docs/process/tool-description-change-control.md).
- **MCP passthrough.** Schemas arriving from MCP servers are already JSON Schema — take them as-is (plus sanitization), tag the entry with its unnormalized origin names, and prefix the registry name (`mcp__server__tool`) so third-party names can't collide with core tools.

### Registration-time validation and ordering

Validate when the entry is created, not when the model first calls it: normalized-name uniqueness (collision policy: core tools win, plugins get namespaced), schema compiles and survives normalization for every enabled provider (or the tool is marked unavailable there, with a diagnostic), aliases don't shadow another tool's canonical name. And **sort the final catalog deterministically** before it reaches the model — registration order is load order, load order isn't stable, and an unstable tool block invalidates the prompt-cache prefix on every run (same rule as the MCP catalog sort on [extensibility](../../cross-cutting/extensibility/README.md)).

---

## Alternatives

### Bare schema dicts plus a sanitizer pass

One studied harness hand-writes OpenAI-format tool dicts and runs a sanitizer over the final list. Honest and debuggable at small scale, and its sanitizer is the best catalog of hostile-schema shapes in the corpus. But without capability metadata there is nothing for parallelism or permission-severity policy to query, and every consumer re-derives "is this read-only" from the name. Fine for a dozen tools; the typed record pays for itself at three dozen.

### Signature-derived tools as the only API

Deriving schema from function signatures is excellent DX and terrible as the *sole* surface: the schema is coupled to the host language's type system, the description hides in a docstring (invisible as the prompt text it is), and capability metadata has nowhere to live. Keep it as sugar over the record.

### A `Tool` base class

Inheritance for what should be data. The argument against ABCs on [extensibility](../../cross-cutting/extensibility/README.md) (partial capability is inexpressible; the base class accretes) applies with full force; the studied implementations that scale are records + a builder, not class hierarchies.

---

## Anti-patterns

- **Schema fixes inside provider plugins.** N providers × M quirks maintained in N places, drifting independently. One normalization seam, driven by a compat table.
- **Static capability booleans on polymorphic tools.** `readonly: true` on a shell tool is false for `rm`; the parallelism policy then races destructive calls. Predicates of input, fail-closed defaults.
- **Trusting arguments for identity, paths, or authority.** "The model passed `sender_is_owner: true`" is not a fact, it's an attack. Runtime facts arrive by context injection at registration; arguments carry only the task.
- **Mutating registry entries during normalization.** The per-provider transform must write a copy; otherwise the first provider's quirks leak into the canonical entry and every later consumer inherits them.
- **Renaming without aliasing.** Persisted permission rules, hook filters, and old transcripts all hold the former name; a rename without a legacy map silently unbinds a security decision.
- **Description edits as doc polish.** The description is behavioral surface. A one-word change can flip when the model reaches for the tool; review it like the prompt change it is.
- **Nondeterministic catalog order.** Cache-thrash on every run, invisible in any functional test.

---

## Cross-references

- [permissions](./permissions.md) — normalized names and the `tool(pattern)` rule grammar; capability predicates feeding severity defaults.
- [extensibility](../../cross-cutting/extensibility/README.md) — capability-typed plugin records, MCP client/server integration, deterministic catalog sort, manifest-first validation.
- [providers](../../backends/providers/README.md) — the model-compat tables the normalization seam reads; provider registration shape.
- [tool-system README](./README.md) — the registry-entry overview bullet this page expands; parallelism policy (pending sibling page) as the consumer of `isConcurrencySafe`.
