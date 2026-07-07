# Webhook Ingest — Recommended Architecture

## TL;DR

Treat the inbound HTTP webhook receiver as a thin **validate-then-normalize** layer that ends by emitting a [`Trigger`](./triggers.md#the-normalized-trigger-object) — never as a place to run agent logic. Each request clears a fixed gate before anything else happens: **body-size limit → signature validation → idempotency → rate limit**. A route is defined by a **secret** (required; no-secret routes refuse to start outside an explicit dev escape), a **prompt template** rendered against the JSON payload, a **trust level** (`known-party` for authenticated, `unknown-party` for anonymous), and a **delivery target**. Support both **static routes** (config-file, restart to change) and **dynamic routes** (agent- or CLI-registered, hot-reloaded). Offer a **direct-delivery fast path** (`deliver_only`) that renders the template and forwards it to a messaging target with no LLM run — the cheap "Supabase fires → Telegram message" case. Always **envelope-wrap** the payload before it reaches the model: an authenticated transport means the *transport* is trusted, not the *content*.

This page is the HTTP-server deep dive under the architecture-level recommendation in [triggers.md](./triggers.md). This is the HTTP-server deep dive under the architecture-level recommendation in [triggers.md](./triggers.md).

---

## Why this belongs in the harness

A webhook receiver is what turns an agent from "responds when addressed" into "responds when the world changes." A PR opens, a payment clears, an alert fires, a database row mutates — and the agent runs without anyone typing. It's also the most exposed trigger surface: a webhook URL is, by construction, reachable by anything that learns the URL, and its payloads are attacker-controllable in fields that look benign (a PR title, a commit message, a customer-name field). That makes the receiver simultaneously the most useful trigger for real automation and the one with the largest blast radius if the validation gate is sloppy. The receiver's whole job is to be paranoid at the edge so the rest of the pipeline can operate on a clean, normalized, trust-tagged `Trigger`.

---

## Recommendation

### The route definition

A route is a named, persisted configuration object:

```ts
type WebhookRoute = {
  name: string                     // path segment: POST /webhook/<name>
  secret: string                   // required; HMAC key or shared token
  signatureScheme: "github-sha256" | "gitlab-token" | "generic-hmac"
  promptTemplate: string           // {dot.notation} against payload; {__raw__} dumps full body
  trust: "known-party" | "unknown-party"
  delivery: "agent" | "log" | DeliveryTarget   // "agent" ⇒ run; else fast-path or log
  deliverOnly?: boolean            // true ⇒ no agent run, render-and-forward
  deliverExtra?: Record<string, string>        // adapter config (chat_id, repo, …), itself templated
  rateLimitPerMin?: number         // default 30
  maxBodyBytes?: number            // default 1 MiB
  source: "static" | "dynamic"     // config-file vs registered-at-runtime
}
```

### The validation gate (order matters)

Every request runs the same ordered checks, and the order is chosen to reject the cheapest-to-reject and most-dangerous cases first:

1. **Body-size limit.** Reject with `413` *before* reading the body. Default 1 MiB; per-route override for legitimately large payloads (Stripe occasionally exceeds it). Reading an unbounded body is a trivial memory-exhaustion vector.
2. **Signature validation.** Three header conventions cover the ecosystem:
   - GitHub: `X-Hub-Signature-256`, HMAC-SHA256 hex, `sha256=` prefix.
   - GitLab: `X-Gitlab-Token`, a *plain shared-token string match* — not an HMAC.
   - Generic: `X-Webhook-Signature`, raw HMAC-SHA256 hex.
   A request to a route with a configured secret but no recognized signature header is rejected. Compare in constant time so signature checking isn't itself a timing oracle. 
3. **Idempotency.** Cache the delivery id — `X-GitHub-Delivery`, `X-Request-ID`, or a timestamp fallback — for ~1 hour and return `200` with `status=duplicate` on a repeat. Upstream services retry on transient 5xx; without dedup, every retry is a second agent run. TTL cache, not an unbounded set.
4. **Rate limit.** Per-route fixed window, default 30 req/min. Self-registered routes additionally share a more aggressive *global* cap so a runaway agent-created route can't outrun the per-route budget by registering many routes.

Only after all four pass does the route render its template and emit a `Trigger`. A failure at any stage is logged and returns the appropriate status; the agent never sees the request.

### Secret is required

A route with no secret cannot start. The receiver refuses to bind a route that has no signature configured, with a single explicit dev-only escape (`INSECURE_NO_AUTH` or equivalent) that's loud in logs. An unauthenticated public webhook URL that triggers agent runs is an open invitation to burn the user's API budget and inject prompts. "We'll add the secret later" is how unauthenticated routes reach production.

### Prompt template rendering

The route turns a JSON payload into a prompt with `{dot.notation}` substitution: `{pull_request.title}` resolves `payload["pull_request"]["title"]`. Recommended rules:

- **`{__raw__}`** dumps the entire payload as indented JSON, truncated (4000 chars) — the escape hatch for "I don't know the shape, give me everything."
- **Missing keys** leave the literal `{key}` string rather than throwing, so a template that references an occasionally-absent field degrades instead of failing the request.
- **Nested/object values** are JSON-serialized and truncated (2000 chars) so a template can't be made to dump an unbounded structure.
- **The same syntax works in `deliverExtra`**, so a route can compute its own delivery `chat_id` from the payload.

Templating happens *after* validation and *before* envelope-wrapping — the rendered prompt is still untrusted content and is wrapped per its trust level.

### Static vs dynamic routes

Ship both:

- **Static routes** live in the config file (`platforms.webhook.extra.routes`), require a restart to change, and are the right home for production-critical integrations you don't want the agent mutating.
- **Dynamic routes** are registered at runtime — via a CLI (`<harness> webhook subscribe`) or by the agent itself through a skill — persist to a separate JSON store (e.g. `~/.<harness>/webhook_subscriptions.json`), and hot-reload on every request with no restart.

When a static and dynamic route share a name, **static wins** — config is authoritative over runtime registration, so the agent can't shadow a production route by registering one with the same name.

### Direct-delivery fast path

For pure passthrough — "Supabase row changed → post to Telegram," "Datadog alert → Discord," inter-agent pings — there's no reason to run the LLM. A `deliver_only: true` mode short-circuits: the rendered template *is* the message body, dispatched to the configured target, returning `200` on delivery success and `502` on target failure so upstream can retry intelligently.

Treat this as a first-class mode, not a flag, because its cost and policy profile differ: it **bypasses the cost-ceiling stage** (no LLM spend) but **still clears HMAC, idempotency, and rate limit** (it can still be abused to spam a Telegram channel). `deliver_only` requires `delivery` to be a real target, not `log`.

### Cross-platform delivery routing

A GitHub webhook can deliver its agent response (or its passthrough body) to Telegram, Slack, Discord, email — any messaging adapter the harness has. The `delivery` field names the target adapter; `deliverExtra` carries adapter-specific, template-rendered config (`chat_id`, `message_thread_id`, `repo`, `pr_number`). Share one vocabulary for source and target enums so both directions are consistent.

### Trust and envelope-wrapping

The trust level for an authenticated webhook is **`known-party`**, never `user-direct`. The payload is attacker-controllable in fields that pass through authentication untouched — a PR title, an issue body, a commit message, a Slack message text stored in some upstream DB. So the receiver tags the `Trigger` with the route's trust level, and the prompt builder envelope-wraps the rendered payload per [input-provenance.md](./input-provenance.md). Anonymous routes (no per-sender authentication beyond a shared secret on a public URL) are `unknown-party` and get the full envelope with the warning preamble. **The recommendation is to wrap** — an acknowledgment-without-mechanism is insufficient.

### Self-registered webhooks

The agent can register its own routes — A webhook-subscriptions skill runs a `webhook subscribe` tool, auto-generates an HMAC secret, and returns it to the user to configure on the upstream service. Two constraints:

- Every self-registered route inherits the **global rate limit and budget cap** automatically; the agent cannot raise its own limits.
- The agent **cannot set `system` trust** on a route. System-level routes, like system-level cron, are installer-only. A self-registered route is `known-party` at most.

This keeps self-registration on the same validation rails as user registration — there is no privileged path that skips signature, rate, or trust rules.

### Health endpoint

Expose `GET /health` → `{"status":"ok","platform":"webhook"}`. It costs nothing and forecloses an entire class of "is the webhook even reaching us?" debugging by giving the user (and the upstream service's test button) a reachability check that doesn't fire the agent.

### Outbound delivery (the inverse direction)

When a route — or a scheduled job ([scheduling.md](./scheduling.md)) — delivers to an arbitrary URL, the agent-to-external direction must run the **same SSRF prevention as `web_fetch`**: block private/loopback/link-local ranges, resolve-then-validate to defeat DNS rebinding, cap redirects. A `normalizeHttpWebhookUrl` utility plus a `network_guard` are the right primitives. Inbound and outbound share one URL-validation module; an outbound webhook target is just as capable of pointing at `169.254.169.254` as a `web_fetch` argument.

---

## Alternatives

### File-event indirection (vs an HTTP server in the harness)

An alternative: run no inbound HTTP server. The agent writes a small program that handles the webhook and drops a JSON event file into `workspace/events/`, which the harness fs-watches. The trust boundary moves to the program-authoring step — the agent vouches for its own adapter — and the harness stays out of the HTTP-server business entirely. Coherent for a single-user assistant where the agent owns its integrations; it does *not* generalize to a public, HMAC-validated, multi-source webhook URL, because the indirection program has no access to the harness's route config, secrets, or rate budget. Useful even if you run a real server: have the validated HTTP route *also* drop a file under `workspace/events/` so the inbound queue is inspectable (`ls workspace/events/`) and each delivery becomes a replayable artifact. See [file-event-triggers.md](./file-event-triggers.md).

### Webhook-only listener for chat platforms (vs persistent socket)

For platforms that natively use HTTP callbacks (Slack Events API, WhatsApp Cloud), the channel listener *is* a webhook receiver — connection management collapses to "verify the route is registered." This overlaps with the channel-trigger pipeline; the validation gate here applies, but the normalization target is a channel `MessageEvent`, not a generic payload. See [channel-triggers.md § Webhook-only listener](./channel-triggers.md). Use it when the host can't hold outbound persistent connections; accept the route-registration burden and the loss of sub-second delivery.

### Polling instead of webhooks

A polling trigger source polls rather than receiving callbacks. Polling needs no inbound URL, no HMAC, no public surface — attractive in locked-down networks where you can't expose an endpoint. The costs are latency (poll interval) and API-quota burn against the polled service. Prefer webhooks when you can expose an endpoint and want low latency; fall back to polling when inbound connectivity is impossible. Either way the result normalizes to the same `Trigger`.

---

## Anti-patterns

- **No secret, or a secret that's optional.** An unauthenticated public webhook that triggers agent runs is an open budget-burn and prompt-injection endpoint. Refuse to start a no-secret route outside an explicit, loud dev escape.
- **Validating signature but not deduping.** A signed-but-replayed payload is still a second agent run. HMAC proves origin, not freshness; idempotency is a separate, required check.
- **Reading the body before the size check.** Unbounded body reads are a memory-exhaustion DoS. Reject `413` on `Content-Length` / streamed size before buffering.
- **Treating a webhook payload as `user-direct`.** The transport is authenticated; the content is not. A PR title is attacker-controllable. Tag `known-party` (or `unknown-party`) and envelope-wrap.
- **Running the LLM for pure passthrough.** "Database changed → notify Telegram" needs no model. Use `deliver_only`; paying for an agent turn on every passthrough is pure waste and adds latency.
- **Letting `deliver_only` skip HMAC or rate limits because "it's just forwarding."** A passthrough route can still be abused to spam a channel. It bypasses *cost ceiling* only; signature, idempotency, and rate limit still apply.
- **Self-registered routes that escape the global cap or set their own trust.** If the agent can register a route at `system` trust or above the global rate limit, self-registration becomes a privilege-escalation path. Inherit limits; cap trust at `known-party`.
- **One URL-validation path for `web_fetch` and a different (weaker) one for outbound webhook delivery.** Both can point at internal metadata endpoints. Share one SSRF guard across every agent-controlled outbound URL.
- **Dynamic routes silently overriding static ones.** Config must win. If a registered route can shadow a production static route by name, the agent (or a compromised registration path) can hijack production traffic.

---
