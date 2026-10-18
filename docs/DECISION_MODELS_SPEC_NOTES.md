# Decision Models: Spec Notes

Implementation notes for `backends/providers/decision-models.md` and `core/model-pool/model-classes.md`. These cover interpretation calls, deviations, and spec gaps found while implementing, collected for review.

## Source of the spec

- The two pages are not in this repo's `harness-template/` copy yet. They were read from the upstream research template, which also has edits to `model-pool/README.md`, `providers/README.md`, `tool-system/permissions.md`, `tool-system/tool-use-summaries.md`, `context-engine/compaction.md`, `execution-environments/README.md`, and a new `backends/computer-use/`. The local copy was left untouched because it is treated as locked; syncing it is a separate decision.
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

## Not implemented (follow-ups)

- **Other consumers.** The skill pre-filter, memory-write gate, guardrails, injection probe, and Pool router role are not wired to `ModelPoolDecisionDispatcher` yet. The gatekeeper is (see below).
- **Mode and conversation role patches.** `RoleBindingResolver` accepts mode and conversation patches, but `ModeProfile.model` and conversation routing do not produce them yet.
- **Other contracts.** `embed`, `rerank`, `render`, `transcribe`, `session`, and `parse` have profile types and well-known roles but no slots, codecs, or job/session state machines. The providers README names `embedding` and `rerank` slots; only `decision` was added.
- **Transport details.** URLSession does not expose a keepalive interval, so the "240 s keepalive" is approximated by a dedicated, reused session plus `warm(role:request:)`. A 413 is classified `permanent` with no re-encode or drop-assets retry. A token-limit 400 retries once by splitting questions; there is no state trimming.
- **Emulation cost.** Emulated calls settle on input tokens only, like real deciders, so a chat model's output tokens go unbilled in the decide path.
- **Route receipt export.** Receipts go to a `RouteReceiptRecording` sink (in-memory recorder provided). Observability export and surface rendering are not wired.

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

## Pre-existing test flake (unrelated)

`LeastPrivilegeModeProfileTests` ("bundled PromptConfig registers least-privilege machine profiles", "trigger-host profile …") fails when run alone, on the base branch as well. `trigger-host` exists only in the test target's `Resources/PromptConfig.json`, so the suite passes only when an earlier test has pointed config loading at that resource. This is shared state between tests.
