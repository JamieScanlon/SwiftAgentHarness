# Decision Models: Spec Notes

Implementation notes for `backends/providers/decision-models.md` and `core/model-pool/model-classes.md`. These cover interpretation calls, deviations, and spec gaps found while implementing, collected for review. For how to set up and use deciders, see [DECISION_MODELS.md](DECISION_MODELS.md).

## Source of the spec

- The two pages (and the related edits to `model-pool/README.md`, `providers/README.md`, `tool-system/permissions.md`, `tool-system/tool-use-summaries.md`, `context-engine/compaction.md`, `execution-environments/README.md`, plus `backends/computer-use/`) are synced into this repo's `harness-template/` copy from the upstream research template.
- The request asked for "JEV-like" models. That name does not appear in the spec. The implementation follows the spec's reference dialect, **SystemOne**, plus OpenAI Decisions.

## Interpretation calls

| Topic | Spec says | Implementation |
|---|---|---|
| `ImageAsset` | `{ mediaType, blobRef }` | Bytes inline (`data: Data`). The decide path has no blob-store resolver. Swap to `blobRef` once one exists. |
| Decide bindings' `ModelProtocol` | Not addressed. `ProviderBinding.modelProtocol` is a chat wire enum. | Decide-only bindings carry the placeholder `.openAIAPI`. It is never consulted, because non-`generate` rows are filtered out of every chat path (`ModelQuery`, slug index, `getAvailableModels`, `resolve`). |
| `parts` image encoding | "multipart/form-data when sending image parts" with `"part": "<name>"` | Multipart with a JSON part named `request` plus one part per asset key. The exact vendor layout is unspecified. |
| `images-array` encoding | "reference by index in state" | `images` ordered by sorted asset key. State strings exactly equal to an asset key are rewritten to that integer index. |
| Logprobs emulation rung | Read `top_logprobs` per constrained token | SwiftAgentKit's `LLMProtocol` has no logprobs API. The codec sends `logprobs` / `top_logprobs` in `additionalParameters` and reads `modelMetadata.top_logprobs` (`[{token, logprob}]`). No current adapter populates it, so the rung is selected only when a `generate` profile declares a `logprobs` feature. Otherwise the schema rung is used. |
| Stage-2 failure in a cascade | "stage-2 answer is final" (failure not covered) | The call fails conservatively with `onError`; the stage-1 answer is kept on `DecisionOutcome.firstStage` for audit only. |
| Compat-bound fallback with no `compatGroup` | Not covered | A primary with `compatGroup == nil` has no legal fallback. |
| Fallback on `auth-error` | Pool step 5 lists transient, rate-limited, credential-exhausted, model-not-found | Followed for `decide`. Note that `ProviderFailoverBridge.bindingDecision` (generate path) also rotates on `auth-error`, so the two paths differ. |
| `{ unavailable: true }` deferral | Matches unavailable signals | Also matches any uncalibrated result, consistent with "uncalibrated results are unavailable to policy by construction". |
| Language skew routing | "let the Pool route other languages to a different decider or to emulation" | Implemented as a rank preference (strong +, weak −, unlisted −), not a hard filter. Emulation is never chosen implicitly. |
| Silent emulation | Emulation is a fallback when no decider is bound | A `generate` model is used for `decide` only when named by pin, fallback, or escalation target. The Pool never emulates on an open query. |
| Unknown cost | "The budget policy decides whether unknown is allowed" | Unknown projections pass the role's `maxUSDPerCall` and reach `BudgetAccounting.authorize` as `nil`, so the existing `projectedCostFallback` decides. |

## Consumers, role patches, transport, and receipts

The decision-model follow-ups, implemented. Every consumer is off unless the host passes it in `DecisionConsumers` (`HarnessRuntimeSession.makeProduction(..., decisionConsumers:)`). An unbound role turns its layer off; a bound role whose call fails takes the spec's failure default.

| Topic | Spec says | Implementation |
|---|---|---|
| Memory-write gate | `yes-no` per candidate; failure default: don't write | `MemoryWriteDecisionGate`, called from `write_file` / `edit_file` for paths inside a memory directory (after the content scanner and the pre-compaction guard). Only the added text is judged. Anything short of `act`, or a failed call, declines the write with a message to the model. Dreaming promotions write through `AgentMemoryStore` directly and are not gated (they are deterministic and already contamination-guarded), and `bash` can still write into the memory directory. |
| Skill pre-filter | One `choice` over skill names + a `yes-no` gate; failure default: load nothing extra | `SkillFilterDecisionGate`. Candidates are the skills the mode and routing policy allow. On `act`, the most likely skills (above a minimum share, at most three) are injected as a `[Skill Shortlist]` note on the turn's first model call. The frozen skills index in the cached prompt prefix is never rewritten, so this routes the model rather than shrinking the prompt; narrowing the index itself would break prompt caching. |
| Guardrail battery | Several `yes-no` checks + an optional severity score in one call; failure default: review | `GuardrailDecisionBattery` with host-defined checks and a policy per check. Combined in code: any `refuse` blocks, any other non-`act` (or a check with no policy) flags for review, all `act` passes. Inbound runs before the message is saved; a block answers the turn without calling the model. Outbound runs on structured delivery (the message tool); a block withholds delivery. Review is logged and kept in `records`. The final assistant text is streamed as it is generated, so it is not guarded; only structured delivery is. Child (sub-agent) conversations are skipped. |
| Tool-output injection probe | `yes-no` on tool output; warn, don't block | `InjectionProbeDecisionGate` as tool-result middleware at order 150, only for results the external-content envelope will wrap. `confirm` prepends a warning, `refuse` a stronger one, and a failed call also warns (the failure default). It never blocks or rewrites, and the envelope at order 200 still wraps the content. It adds one decide call per external tool result. |
| Model router | Pool rank stage, step 3: a `choice` over candidates, folded with cost, latency, and cache warmth; failure default: role default | Owned by the Pool; callers never invoke it. `ModelPoolTurnSelector` serves the runtime's per-turn request for the `main` model: it hard-filters to the current model's tools and vision, takes the Pool's static ranking (cost and latency), and lets the router choose. It switches only on a calibrated `act` for a different model, and a warm conversation (one with turns on the current model) also requires the pick to beat the current model by `warmCacheMargin`. In `ModelPoolDecisionDispatcher` the router can move one candidate to the front of a `decide` role's ranking, skipped for pinned roles, for the router's own calls, and when fewer than two candidates survive the hard filter. Receipts record `routerPick`. The conversation's stored model is never changed. Other `generate` roles (`compactor`, `background-small`, `subagent`) are not routed, because this codebase does not resolve them through role bindings. Cache warmth is approximated by "has history on the current model"; the Pool has no per-model cache telemetry. |
| Role patches | Built-in → settings → mode patch → conversation patch → per-call pin | `ModeProfileModelSlice.roles` (PromptConfig `modeProfiles[].model.roles`) and `ConversationRoutingModelOptions.roles` (persisted with routing prefs; PATCH `routingModelOptions.roles`, where omitting leaves them and `{}` clears them). Consumers load both per call and pass them as `DecisionCallContext.rolePatches`; the dispatcher overlays them on its settings resolver, the conversation patch winning. |
| Token-limit retry | "split the questions across requests, or trim the state, and retry once" | Several questions split in two. A single question trims the longest string in the state (head and tail kept around a visible `characters trimmed` marker). One retry either way. |
| 413 | "permanent, unless the codec can re-encode or drop assets and retry once" | Image assets are re-encoded at half size (never below the binding's image window; JPEG also at lower quality) and retried once. Assets are never dropped, because a gating question would lose its evidence. |
| Keepalive | "a 240 s keepalive is a common choice" | URLSession does not expose a TCP keepalive interval. `ModelPoolDecisionDispatcher.keepWarm(role:interval:)` pings the top candidate's `v1/models` every 240 s until cancelled, in a task the host owns. It never bills a decide call. |
| Emulation cost | — | Emulated calls settle input tokens plus output tokens at the chat model's output price (`DecisionCostEstimator.settleEmulated`). Unknown when the chat model has no output price. |
| Receipt export | Receipts are what observability exports and surfaces render as "answered by X (fallback from Y)" | `RouteReceiptWire` on `conversation/{id}/events` as a transient `routeReceipt` event (`ConversationEventsRouteReceiptRecorder`; combine with others via `CompositeRouteReceiptRecorder`). Redacted at emit: no request or response content, and vendor request ids are SHA-256 hashed. `summary` is the "answered by X" line. Schema: `openapi/schemas/ws/route-receipt-wire.schema.json`. The generated Python enum was updated by hand to match, since regenerating needs a network install. Receipts are not yet rendered by the bundled TUI. |

## Streamed assistant text: not guarded by a decider (decision)

The spec lists the guardrail battery as "inbound and outbound" but doesn't say how to guard text that streams to surfaces as it's generated. We decided not to run the `guard` battery on streamed assistant text. Outbound guardrails stay on structured delivery only.

**Why.** The orchestrator's reply goes wrong mainly when something earlier in the conversation told it to, so the effort belongs where untrusted content enters: the external-content envelope, the injection probe, permission rules, and the gatekeeper. A decider check on every streamed reply would cost a call per reply (or per chunk), and mostly check clean text. It would also have to either delay display (buffering) or retract text a user may already have seen, and some surfaces (Slack, Telegram, email) can't take a message back.

**What we do instead.** One attack still gets past every input-side defense: a reply that leaks data the moment it is displayed. An example is a markdown image whose URL carries a secret, which the surface fetches with no click and no tool call. Plain code closes that hole (`UntrustedLinkSanitizer`, wired in `TurnLoop`). While the model call's context holds wrapped external content:

- remote images (markdown, HTML `<img>`, and remote reference definitions) are not loaded;
- links, autolinks, and bare URLs whose URL carries data (a query, fragment, user info, a path segment of 40+ characters, or a host label of 32+ characters) are shown as inert code with an "unverified link" note;
- code spans and fenced code blocks are left alone.

The streamed text and the saved message are rewritten identically. Text that could still become a link or image is held back only until it resolves. It is on by default, and PromptConfig `agentHarness.untrustedLinkSanitizer` / `untrustedLinkTrustedHosts` turn it off or exempt hosts.

**Known limits.**
- "External content" means the envelope marker appears in the call's assembled context or in the saved transcript. That includes file reads, `bash`, and memory search, since those results are wrapped too, so in practice most agentic turns qualify.
- Structured delivery through the message tool is not rewritten. It is still covered by outbound guardrails when they are configured.
- Reasoning text is not rewritten.
- A fuller defense on the input side, the quarantine ("dual LLM") pattern where the orchestrator only ever sees constrained results derived from untrusted text, is a separate design question.

## Out of scope

This work covers decision models only. `embed`, `rerank`, `render`, `transcribe`, `session`, and `parse` have profile types and well-known roles but no slots, codecs, or job/session state machines, and are not planned here.

## Gatekeeper (classifier-assisted permission gating)

Implements `tool-system/permissions.md` § Classifier-assisted gating and the gatekeeper row of decision-models § "Where the harness uses deciders". The code is `ToolApprovalClassifierGate`, hooked into the agent loop's `dispatchFn` right after the rules return *ask*.

| Topic | Spec says | Implementation |
|---|---|---|
| Which option the bands apply to | Gate is a `choice` over `{clear, caution}`; bands test `p` (top-1) | Choice bands don't name the option, so a confident `caution` (p = 0.98) also lands in the act band. The gate allows only when the result is calibrated **and** the chosen option is `clear` **and** the verdict is `act`. This is a gap in `DecisionPolicy` for choice questions; a per-option axis (`on: "p(option)"`) would close it. |
| "the user's messages" | Read the user's messages, never tool outputs | Only user-role messages whose trust resolves to `trusted` (`direct_user_entry`). Unstamped messages are low trust per `MessageInputTrustCodec.safePolicyClass`, so they are excluded unless the host sets `includeUnstampedUserMessages`. Harness-injected and automation messages are always excluded, as are assistant text and tool outputs. With no trusted request the gate asks without calling the decider. |
| "tight token budget" | On the latency path of every gated call | The last 3 trusted user messages, 2,000 characters each, and a 2 s total time budget. Arguments over 4,000 serialized characters go to the human; they are never truncated, because a truncated tail could hide the risky part. |
| Elevated tools, parent route, plan exit | Not addressed | Elevated tools ask by default (opt-in via `allowElevatedTools`). The `.parent` route always asks, since the classifier sits between the rules and the *human*. `exit_plan_mode` always asks, since it is a human review of the plan. |
| "transcript is dumpable" | Debuggable misclassification | `ToolApprovalClassifierGate.records`: a bounded log of the exact request sent and the outcome. The `RouteReceipt` id is also embedded in the approval reason. |
| Coverage | All gated calls | Model tool calls in the agent loop, in both wait-for-human and park (`stopOnApprovalRequest`) modes. Approval-gated calls always take the serial path, so batch dispatch is covered too. Slash-command approvals and sub-agent transport permission prompts are not routed through the gate. |
| Wire contract | — | `approvalResolutionKind` gains `classifier` (WS schema plus the generated Python binding); `approvalSource` is `classifier` and the lifecycle `source` is `runtime.approvalClassifier`. |

## Aliases and pinned versions

Addresses a field report: a hosted decider configured as its vendor documents it (`jev-latest` at `…/v1/systemone`) left the gatekeeper silently unable to act. The spec's rule is that roles with tuned thresholds pin versions, and that moving aliases resolve to a versioned id at dispatch (`model-classes.md` § Lifecycle and aliases; `decision-models.md` principle 5).

| Topic | Spec says | Implementation |
|---|---|---|
| Configuring an alias | Resolve moving aliases to a versioned id at dispatch | `DecisionModelConfig.aliases` (stored on `ModelLifecycle.aliases`). An alias works as a pin or lookup name; the wire always carries `endpointModelID`, and the receipt records `aliasResolved = alias → pinned version`. Bands never follow an alias. |
| Response echoes an alias | `modelVersion` is "the versioned id that answered, never the alias" | Treated as untuned: the verdict is forced to `onUnavailable` even when bands exist under that name, with a warning that the answering version is unknown. A name counts as an alias when it is declared, when the entry is configured with `aliasOf`, or when it matches `*-latest` / `*-preview`. A versioned id that happens to end in `-preview` would be misread; pin a different name if that comes up. |
| Detecting drift | An alias move is an explicit config change with a re-tuning step | `ModelPoolDecisionDispatcher.warm(role:request:)` (and `ToolApprovalClassifierGate.prepare()`) sends one minimal request per declared alias and compares the reported `model` with the pinned version: `matches`, `drifted`, `unverifiable` (the server echoed the alias), `failed`, or `unsupported` (the server ignores `model`). Drift is logged and returned; the pin never changes on its own. Probes are billed calls. |
| Load-time check | Fallbacks and escalation targets must carry bands | `validateBinding(role:policy:)` compares `policy.tunedVersions` with the versions the role's candidates (including the escalation target) serve, with no network calls. No overlap logs an error that the role will never act. Bands keyed by an alias, alias-shaped endpoint ids, and candidates without bands log warnings. The gate runs it once on first use. |
| Naming the cause | — | `ToolApprovalClassifierAskReason.untunedVersion` replaces `notInActBand` when the verdict came from an untuned version. The dispatcher warns once per `(role, version)`. Its logger now defaults to `Logger(label: "SwiftAgentHarness.ModelPool.Decisions")`, so these warnings are emitted even when a host passes none. |
| `serverURL` | — | Documented as the API root. A URL ending in the surface's own endpoint path (`/v1/systemone`, `/v1/decisions`) is trimmed at config time (logged at debug), and `DecisionEndpoint.url` leaves a base that already ends in the path unchanged. This fixes both the decide call and the `v1/models` warm-up. |

The report's vendor facts (the alias maps to `jev-1.13.0`, and responses carry the versioned id) come from the vendor's docs and were not checked against a live response. The behavior above is correct whichever way the server answers.
