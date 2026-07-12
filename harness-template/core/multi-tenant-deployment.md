# Multi-Tenant Deployment

> Everything else in this template assumes a **single-user (or single-trusted-org) Gateway**: one identity, one budget, one memory store, one trust perimeter. This page covers what changes when that assumption falls — when mutually untrusting tenants share a deployment — and why the recommended answer is usually to *not* let them share a process.

## TL;DR

Distinguish **multi-user within one trusted org** (an authorization problem — user identity, private conversations, shared registries) from **true multi-tenancy** (an isolation problem — mutually untrusting parties whose data, budget, side-effects, and prompts must never touch). For the second, the default recommendation is **instance-per-tenant**: keep the harness single-tenant exactly as this template describes it, and put a thin control plane in front that provisions and routes to per-tenant instances. Isolation then holds *by construction* — the [library-vs-server work](./library-vs-server-boundary.md) already made instances cheap. Shared-process multi-tenancy is a density optimization with a long, sharp bill: the tenant id must become part of every resource *address* (never a filter applied afterward), the prompt/response cache and the Memory layer become per-tenant partitions, sandboxes and workspaces must never be shared, server-scoped bus topics must be re-scoped, and in-process plugins become untenable. Every one of those is an inner-ring change; get any one wrong and the failure mode is a cross-tenant data breach, not a bug.

## First, decide which problem you have

The word "multi-tenant" covers three situations with very different costs:

| Situation | Trust model | What it actually needs |
|---|---|---|
| **Multi-user, one org** | Users trust the operator and (broadly) each other; they want privacy, not isolation | Identity on the connection, per-user conversation ownership, per-topic authorization, per-user budgets. No inner-ring changes — the Comm Layer's existing authz hooks carry it. |
| **Multi-tenant, hosted** | Tenants trust the operator; tenants are mutually untrusting | Everything above *plus* hard partitions on data, memory, cache, sandboxes, and cost — the subject of this page. |
| **Multi-tenant, adversarial** | Tenants actively probe the boundary (public SaaS, free tier) | Everything above *plus* the assumption that a tenant will weaponize the model, the tools, and the sandbox against the boundary. Instance-per-tenant with OS/VM-level isolation is the only defensible posture. |

Most teams that say "multi-tenant" have the first problem, and should stop there: the per-channel-peer DM scoping already specified in [persistence](../backends/persistence/README.md) and [channels](../surfaces/interface/channels.md), plus connection auth and per-topic authorization on the [Communication Layer](./communication-layer/README.md), cover multi-user without touching the inner ring. The rest of this page is about the second and third rows.

## The recommendation: instance-per-tenant, shared control plane

Keep the harness single-tenant. Add a **tenancy control plane** in front — not a ninth inner-ring layer, but a separate service that owns:

- **Provisioning** — create / suspend / destroy a harness instance per tenant (process, container, or VM, escalating with the trust model).
- **Routing** — terminate tenant authentication, map tenant → instance, proxy the wire protocol through unchanged. The instance still sees a single-org world.
- **Fleet concerns** — per-tenant resource ceilings at the OS level, instance health, upgrades, backup of per-tenant state.
- **Aggregate metering** — roll up each instance's usage reporting (the Model Pool's computed-per-call cost, per [observability](../cross-cutting/observability/README.md)) into tenant billing.

Why this is the default and not the fallback:

1. **Isolation by construction beats isolation by discipline.** In a shared process, every query, every cache lookup, every memory recall, every bus publish is one missing predicate away from a cross-tenant leak — and the codebase must maintain that discipline forever, across every contributor and every new feature. With instance-per-tenant, the boundary is the process (or VM), enforced by the OS, and a whole class of bug becomes structurally impossible.
2. **The template's own architecture made instances cheap.** Embedded mode, the single-process Gateway, SQLite-backed persistence, in-memory transport — the single-tenant harness boots fast and runs light. The density argument for shared-process tenancy is much weaker than it is for a heavyweight server.
3. **The blast radius argument.** A crashed instance, a poisoned memory store, a runaway sub-agent fan-out, a compromised plugin — each is one tenant's incident, not everyone's.
4. **Per-tenant configuration is free.** Tenants inevitably diverge: different model allowlists, different plugins, different provider credentials (BYO keys), different data-residency requirements. Per-instance, that's config; shared-process, each one is a new partitioning dimension.

The costs are real but operational, not architectural: more processes to run, a fleet to manage, cold-start latency for idle tenants (mitigate with suspend/resume — the persistence layer already makes conversations survive process death), and a per-instance memory floor. Pay them.

## If you must share a process: the per-layer isolation bill

Sometimes density wins (thousands of small free-tier tenants) or the platform dictates it. Then tenancy stops being a deployment question and becomes an inner-ring property. The governing invariant:

> **The tenant id is part of the resource address, not a filter on a shared namespace.** A conversation is `(tenant, conversationId)`; a memory is `(tenant, memoryId)`; a topic is `tenant/{t}/conversation/{id}/events`. APIs scoped this way *cannot express* cross-tenant access — the wrong query doesn't return the wrong rows, it doesn't typecheck. Filter-based isolation (`WHERE tenant_id = ?` sprinkled at query sites) is the version that fails silently.

What each layer owes under that invariant:

| Layer | Isolation obligations |
|---|---|
| **Model Pool** | Per-tenant budget scope added to the existing per-call / per-conversation / global ladder; fair-share scheduling so one tenant's sub-agent fan-out can't starve the queue (noisy neighbor); credential isolation when tenants bring their own provider keys; **prompt and response caches partitioned by tenant** — a shared response cache is a direct data leak, and shared prompt-cache prefixes leak timing signals about other tenants' prompts. |
| **Sub-Agent Pool** | Delegates inherit the spawning conversation's tenant, unconditionally — budget, permissions, memory scope, workspace all flow down. Remote transports carry the tenant claim across the wire and the remote end enforces it. Fan-out limits are per-tenant, because delegation is the cheapest way for one tenant to multiply load. |
| **Tool System** | Registry becomes per-tenant-visible: a tenant's MCP servers and plugin-contributed tools must not appear in — or be invokable from — another tenant's conversations. Permission policy is per-tenant config. Approval requests route only to the owning tenant's attached clients. |
| **Context Engine** | Least affected — it's per-conversation by construction. The one trap is cache-aware assembly: shared static prefixes (the template system prompt) may share provider cache entries; anything tenant-derived (memory injection, project files, attachments) must key its cache breakpoints within the tenant partition. |
| **Memory** | The sharpest boundary in the system, because memory is *designed* to cross conversations. Tenant is the hard outer wall of recall: search, injection, and consolidation never cross it. Vector stores get a namespace (or database) per tenant; consolidation/dreaming pipelines run per tenant; cross-project transfer (per [memory](./memory/README.md)) operates strictly within a tenant. |
| **Agent Runtime** | Stateless, so nearly untouched — but concurrent-run ceilings become per-tenant, enforced where runs are admitted. |
| **Conversation Manager** | Tenant on the catalog row as part of the primary address; list / search / branch / attach all take the tenant from the authenticated context, never from client input. |
| **Communication Layer** | Connection auth yields a tenant claim; every topic name is tenant-prefixed and authorization checks the prefix against the claim. The **server-scoped topics stop being server-scoped**: `tools/registry`, `skills/registry`, `models/registry` become per-tenant views; `pool/health` either becomes per-tenant (showing only your own queue depth) or operator-only — aggregate health leaks other tenants' usage patterns. Replay buffers and backpressure budgets are sized per tenant so one tenant's lag can't evict another's window. |

And the tiers around the ring:

- **Persistence** — pick the partition depth to match the trust model: row-scoped (tenant column, weakest, acceptable only for the multi-user case), schema-per-tenant, or database/file-per-tenant (strongest, and what instance-per-tenant gives you for free). Backup, restore, export, and *deletion* — tenant offboarding is a compliance event — must all operate on a tenant unit. A per-tenant catalog file makes "delete tenant" `rm -rf`; a shared database makes it a distributed garbage-collection project.
- **Execution environments** — non-negotiable: no shared sandboxes, no shared workspace filesystem, per-tenant network policy. A sandbox is where tenant-authored instructions run tenant-influenced code; sharing one across tenants is sharing a shell. Workspace canonicality (per [execution-environments](../backends/execution-environments/README.md)) gets a tenant segment in the canonical path.
- **Extensibility** — the hardest case, and often the deciding argument for instance-per-tenant. In-process plugins run with the process's authority; there is no per-tenant permission boundary inside a shared process that a plugin must respect. Options, in descending order of preference: per-tenant plugins only in per-tenant instances; out-of-process plugin execution (MCP-style, where the transport enforces the tenant scope); or a shared process restricted to an operator-curated global plugin set. "Tenant-uploaded code in the shared process" is not on the list.
- **Observability** — every span, log line, and usage event carries the tenant attribute from birth (the trace context already crosses the three Pools; the tenant rides with it). Two views: the operator sees across tenants; a tenant's own debugging surface is filtered to their partition by the same address-scoping rule as everything else. Redaction-at-emit matters more here — logs are where cross-tenant leaks go to hide.

## Alternatives

### Shared process, row-level scoping

Tenant column on every table, tenant check in every handler, one process for everyone.

**When this works:** the multi-user-one-org case — where a leak is an embarrassment and a bug report, not a breach and a lawsuit. It's also acceptable as a stepping stone while tenant count is small and all tenants are design partners you'd trust with a shared Slack channel.

**Why not for real tenancy:** discipline-based isolation degrades monotonically as the codebase grows. Every new feature is a new set of query sites to audit. The failure is silent — nothing crashes when the filter is missing.

### Tenancy at the model-routing service only

Put a multi-tenant LLM router (the LiteLLM / OpenRouter shape, per [model-pool § alternatives](./model-pool/README.md)) behind single-tenant harnesses, and call the system multi-tenant.

**When this works:** as a *component* of either posture — shared credential vault, shared budget enforcement, shared provider-adapter maintenance at the routing tier are all fine things to centralize.

**Why it isn't the answer alone:** model calls are one of five things that need isolation. Memory, persistence, sandboxes, and the event bus are untouched by a router. This alternative is really "instance-per-tenant plus a shared Model Pool backend," which is a fine shape — just don't mistake the router for the tenancy boundary.

### Namespace-per-tenant on shared infrastructure

One process pool, but every stateful backend partitioned by namespace: database schema per tenant, vector-store namespace per tenant, sandbox pool per tenant, topic prefix per tenant. The middle posture.

**When this works:** high tenant counts with low per-tenant activity, a mature team, and a trust model where tenants don't actively attack the boundary. This is the honest version of shared-process tenancy — it accepts the full per-layer bill above and pays it deliberately.

**What to watch:** the compute plane is still shared even when the data plane is partitioned. Scheduler fairness, plugin authority, and in-process cache partitioning remain live risks that namespaces don't fix.

## Anti-patterns

- **Tenant as a WHERE clause.** Isolation enforced by remembering to filter, at N query sites, forever. The address-space rule exists because this fails silently and is found by the breached tenant, not by tests.
- **Shared response or prompt cache across tenants.** A response cache hit across tenants returns one tenant's model output to another — a breach with no exploit required beyond asking a similar question. Partition by tenant before any other cache key component.
- **Memory recall without a tenant wall.** Embedding search over a shared vector namespace will happily return the nearest neighbor regardless of who wrote it. Cross-conversation is memory's job; cross-tenant is a breach. The namespace, not the ranking, is the boundary.
- **Server-scoped topics in a tenant-scoped world.** `tools/registry` listing another tenant's MCP tools, `pool/health` exposing aggregate queue depth that reveals a competitor's usage curve. Every topic gets re-audited when tenancy arrives; "it's just metadata" is how this one slips through.
- **Trusting client-supplied tenant ids.** The tenant comes from the authenticated connection's claim, resolved server-side — never from a request body, a topic string the client composed, or a header the proxy forgot to strip.
- **Shared sandboxes or workspace roots.** Two tenants' tool executions in one filesystem is one path-traversal away from cross-tenant file access — and the agent *generates paths* as part of normal operation. Per-tenant execution environments, no exceptions.
- **Tenant-uploaded plugins in the shared process.** In-process extension code has the process's authority; no registry policy can confine it to its tenant. Out-of-process or per-instance, only.
- **Billing from the provider invoice.** The invoice arrives monthly and aggregated; disputes need per-call attribution. Meter at the Model Pool's per-call usage event (computed once, per [observability](../cross-cutting/observability/README.md)), tagged with tenant, from day one.
- **Retrofitting tenancy through the inner ring under deadline.** The shared-process bill above is a multi-quarter project touching every layer. Teams that need tenancy *this quarter* should run instance-per-tenant now and revisit density later — the control-plane-in-front posture requires no inner-ring changes at all.

## References

- [core/README.md](./README.md) — the single-user Gateway assumption this page relaxes
- [library-vs-server-boundary.md](./library-vs-server-boundary.md) — the contract work that makes per-tenant instances cheap
- [communication-layer/README.md](./communication-layer/README.md) — connection auth, per-topic authorization, the server-scoped topic taxonomy re-scoped here
- [model-pool/README.md](./model-pool/README.md) — budget scopes, scheduler, prompt/response cache, and the multi-tenant router alternative
- [memory/README.md](./memory/README.md) — the recall and consolidation machinery that tenant walls must contain
- [backends/persistence/README.md](../backends/persistence/README.md) — partition depths; `dmScope` as the existing multi-user isolation precedent
- [backends/execution-environments/README.md](../backends/execution-environments/README.md) — sandbox boundaries and workspace canonicality
- [cross-cutting/extensibility/README.md](../cross-cutting/extensibility/README.md) — plugin authority, the deciding constraint against shared-process tenancy
- [cross-cutting/observability/README.md](../cross-cutting/observability/README.md) — tenant-tagged signals, per-call usage metering, operator-vs-tenant views
