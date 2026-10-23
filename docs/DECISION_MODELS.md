# Decision Models

How to set up a decision model ("decider") in SwiftAgentHarness and use it to gate tool calls.

A **decider** answers closed questions about a piece of state and returns a calibrated probability for each answer: yes/no, a choice among options, a score on a scale, or a box in an image. It does not generate text. A typical call takes about 100 ms and is billed on input tokens only. The harness supports two wire dialects: **SystemOne** (the common hosted and local shape) and **OpenAI Decisions**.

The steps below take you from nothing to a working gatekeeper:

1. [Register a decider](#1-register-a-decider)
2. [Pin versions and declare aliases](#2-pin-versions-and-declare-aliases)
3. [Write a policy](#3-write-a-policy)
4. [Bind roles](#4-bind-roles)
5. [Build the dispatcher](#5-build-the-dispatcher)
6. [Enable the gatekeeper](#6-enable-the-gatekeeper)
7. [Other consumers](#7-other-consumers): memory gate, skill filter, guardrails, injection probe, router
8. [Route receipts on the event bus](#8-route-receipts-on-the-event-bus)

For design background, see [DECISION_MODELS_SPEC_NOTES.md](DECISION_MODELS_SPEC_NOTES.md) and the harness-template pages `backends/providers/decision-models.md` and `core/model-pool/model-classes.md`.

## Quick start

A hosted SystemOne decider gating tool calls. Each part is explained in the steps that follow.

```swift
import SwiftAgentHarness
import SwiftAgentHarnessProviders

// 1–2. Register the decider: the pinned version on the wire, the vendor alias as a lookup name.
let decider = DecisionRuntimeConfig(
    providerID: "typesafe",
    label: "TypeSafe SystemOne",
    surface: .systemOne,
    serverURL: URL(string: "https://api.typesafe.ai/v1")!,
    apiKeyEnvVars: ["TYPESAFE_API_KEY"],
    models: [
        DecisionModelConfig(endpointModelID: "jev-1.13.0", aliases: ["jev-latest"], roles: ["gatekeeper"]),
    ]
)
registerDefaults(options: DefaultProviderOptions(decisionRuntimes: [decider]))

// 3. Bands keyed by the pinned version. Act only at P(clear) >= 0.95.
let policy = DecisionPolicy(
    question: ToolApprovalClassifierConfiguration.questionID,
    bands: ["jev-1.13.0": .ranges(
        confirm: DecisionRange(0, 0.95, upperOpen: true),
        act: DecisionRange(0.95, 1)
    )]
)

// 4. Bind the gatekeeper role.
let roles = RoleBindingResolver(settings: [
    .gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide, pin: "jev-1.13.0"),
])

// 5. The dispatcher selects from the Model Pool registry.
let dispatcher = ModelPoolDecisionDispatcher(candidates: modelManager, roles: roles)

// 6. The gate, checked and warmed at startup, then handed to the session.
let gate = ToolApprovalClassifierGate(
    dispatcher: dispatcher,
    configuration: ToolApprovalClassifierConfiguration(policy: policy)
)
let (validation, _) = await gate.prepare()
if !validation.canAct {
    // The gate will ask on every call. Log validation.problems and decide whether to start without it.
}

let (session, services) = HarnessRuntimeSession.makeProduction(
    /* … your existing arguments … */
    toolApprovalClassifierGate: gate
)
```

`modelManager` is the `ModelManager` your host already creates. Export `TYPESAFE_API_KEY` before launch.

---

## 1. Register a decider

A decider is a provider registered in the `decision` slot. Describe it with `DecisionRuntimeConfig` and pass it to `registerDefaults`:

```swift
registerDefaults(options: DefaultProviderOptions(
    inferenceRuntimes: myInferenceRuntimes,
    decisionRuntimes: [decider]
))
```

### `DecisionRuntimeConfig`

| Field | Meaning |
|---|---|
| `providerID` | A registry id you choose. It must not collide with another provider (for example, don't reuse `openai`). |
| `label` | Display name. |
| `surface` | `.systemOne` (default) or `.openAIDecisions`. This picks the wire codec. |
| `serverURL` | The **API root**: `https://api.vendor.ai` or `https://api.vendor.ai/v1`. If you paste the full endpoint from vendor docs (`…/v1/systemone` or `…/v1/decisions`), the endpoint path is trimmed off. |
| `apiKeyEnvVars` | Environment variables the auth store reads the API key from (it also accepts entries from `auth-profiles.json`). Leave this empty for a local server with no auth. |
| `models` | One `DecisionModelConfig` per version you serve. |

### `DecisionModelConfig`

| Field | Meaning |
|---|---|
| `endpointModelID` | The server's own **versioned** id, for example `jev-1.13.0`. It always goes on the wire, and policy bands are keyed by it. |
| `aliases` | Vendor aliases for this version (`jev-latest`). See [step 2](#2-pin-versions-and-declare-aliases). |
| `roles` | Roles this model is catalogued for, such as `["gatekeeper"]`. Catalogued models rank first when a role has no pin. |
| `compatGroup` | Declares models that behave the same. Threshold-bearing roles fall back only within one group. |
| `prices` | Unit-typed prices, for example `[PriceComponent(unit: .inputToken, usd: 0.04, per: 1_000_000)]`. With no price, cost is reported as unknown, never as zero. |
| `profile` | Override the capability descriptor (question kinds, limits, server quirks). The default is the surface's reference descriptor. |
| `locality` | `.local`, `.vendor`, or `.vendorNoRetention`. The default is `.local` when no API key is configured, otherwise `.vendor`. Roles can require a locality. |
| `lifecycle` | `.active` by default. Retired models are never selected. Deprecated models are selected only when pinned. |

### Local decision servers

llama.cpp, vLLM, Ollama, and edge platforms often speak SystemOne with small differences. Leave `apiKeyEnvVars` empty, and describe the differences through the profile:

```swift
let local = DecisionRuntimeConfig(
    providerID: "local-decider",
    label: "Local decider",
    serverURL: URL(string: "http://127.0.0.1:8080")!,
    models: [DecisionModelConfig(
        endpointModelID: "my-decider-q8",
        profile: DecisionProfiles.systemOne(
            images: FeatureSupport(params: ["encoding": .string("images-array")]),
            extraFeatures: [
                DecisionFeatureKey.modelField: FeatureSupport(params: ["mode": .string("omit")]),
            ],
            limits: ContractLimits(contextTokens: 32_768, maxItemsPerCall: 64, maxOptions: 255, scoreLevels: 2...10)
        )
    )]
)
```

> **A local server needs a local auth profile.** The registry only lists a provider once its lifecycle is `registered`. For a provider with no API key, that requires a `.local` auth profile. Without one, `ModelManager` never lists the decider, and the role reports `noCandidates`. Pass the profile to the `AuthProfileStore` your `ModelManager` uses:
>
> ```swift
> let authStore = AuthProfileStore(seedProfiles: [
>     AuthProfile(id: "local-decider", providerID: "local-decider", authType: .local,
>                 baseURL: URL(string: "http://127.0.0.1:8080")!),
> ])
> let modelManager = ModelManager(authProfileStore: authStore)
> ```

Server quirks are binding config, not code. They are set through the profile's features and limits:

| Quirk | How to set it |
|---|---|
| Response wrapped in `{success, result: {…}}` | `DecisionFeatureKey.envelope: FeatureSupport(params: ["unwrap": .string("result")])` |
| Server ignores or rejects `model` | `DecisionFeatureKey.modelField: FeatureSupport(params: ["mode": .string("omit")])` |
| Images as a top-level `images` array | `images: FeatureSupport(params: ["encoding": .string("images-array")])` |
| Image feature behind an opt-in header | `images: FeatureSupport(params: ["optInHeader": .string("X-Vendor-Images")])` |
| Image size window (resized to fit before sending) | `images` params `edgePx: [280, 1568]`, `totalPixels: [78400, 2458624]` |
| Long-context opt-in header | `longContext: FeatureSupport(params: ["optInHeader": .string("X-Vendor-Long-Context")])` |
| Max questions per request (split automatically) | `limits.maxItemsPerCall` |
| Non-standard endpoint path | `DecisionFeatureKey.endpoint: FeatureSupport(params: ["path": .string("ai/run/decide")])` |
| gzip request bodies | `DecisionFeatureKey.compression: FeatureSupport(params: ["encoding": .string("gzip")])` |
| Languages the model is strong or weak in | `languages: FeatureSupport(params: ["strong": .array([.string("en")]), "weak": .array([.string("ja")])])` |

### OpenAI Decisions

Use `surface: .openAIDecisions` and `serverURL: https://api.openai.com/v1`. That dialect has no `box` question kind, so roles that need it never select an OpenAI binding. Pick a `providerID` other than `openai`, because the built-in OpenAI text provider already uses that id.

---

## 2. Pin versions and declare aliases

**Policy bands follow pinned versions, never aliases.** Vendors move an alias like `jev-latest` to new versions, and a threshold tuned on one version has an unknown error rate on the next.

- Set `endpointModelID` to the versioned id, and list the vendor's alias under `aliases`:

  ```swift
  DecisionModelConfig(endpointModelID: "jev-1.13.0", aliases: ["jev-latest"])
  ```

- An alias works as a pin or lookup name (`RoleBinding(pin: "jev-latest")` selects `jev-1.13.0`). The wire always carries `jev-1.13.0`, and the route receipt records `aliasResolved: jev-latest → jev-1.13.0`.
- Key policy bands by `jev-1.13.0`. Bands under `jev-latest` never match.

**If the server echoes an alias.** A response whose `model` is an alias doesn't say which version answered. The harness treats it as untuned, so the verdict is `onUnavailable` (never `act`), and logs a warning. It counts a name as an alias when you declared it, when the entry was configured with `aliasOf`, or when it matches `*-latest` / `*-preview`.

**Detecting drift.** `gate.prepare()`, or `dispatcher.warm(role:request:)`, sends one minimal request per declared alias and compares the reported version with your pin:

| Probe status | Meaning |
|---|---|
| `.matches` | The alias still serves your pinned version. |
| `.drifted(servedVersion:)` | The alias moved. A warning names both versions. Your pin keeps working until you choose to move it. |
| `.unverifiable` | The server echoed the alias, so the version behind it can't be confirmed. |
| `.unsupported` | The server ignores `model` (`modelField: omit`), so there is nothing to probe. |
| `.failed(_)` | The probe call itself failed. |

Probes are billed calls, one per alias. **Adopting a new version is a config change:** collect labeled examples, tune bands for the new version, add them to the policy, then move `endpointModelID` and the pin.

---

## 3. Write a policy

A `DecisionPolicy` turns one question's answer into a verdict: `act`, `confirm` (ask a human or gather more context), or `refuse`.

```swift
let policy = DecisionPolicy(
    question: "verdict",                 // the question id this policy reads
    on: .p,                              // test p (top-1 probability) or .margin (top-1 − top-2)
    bands: [
        "jev-1.13.0": .ranges(
            refuse: nil,
            confirm: DecisionRange(0, 0.95, upperOpen: true),
            act: DecisionRange(0.95, 1)
        ),
    ],
    onUnavailable: .confirm,             // untuned version, range gap, missing or invalid answer
    onRefusal: .confirm,                 // the model declined the question
    onError: .confirm,                   // timeout, 5xx, no candidate; there is no fail-open option
    escalate: nil
)
try policy.validate()                    // rejects overlapping or inverted ranges
```

How evaluation works:

- **Bands are keyed by the version that answered.** Include every version the role may use: the primary, each fallback, and the escalation target. An answer from a version with no bands is untuned and resolves to `onUnavailable`.
- **Order is conservative:** refuse, then confirm, then act. A value that falls in no range resolves to `onUnavailable`. A misconfigured policy can over-ask but never over-act.
- **Confidence is computed locally** from the probabilities. Vendor `confidence` fields are ignored, since vendors define them differently.
- **Uncalibrated answers** (from an LLM emulating a decider) are unavailable to policy. The exception is a policy that sets `acceptsUncalibrated: true` and has bands for that exact emulating version.
- **Score questions** use `.levels([.act, .confirm, .refuse])`, one verdict per rounded expected level.

**Choosing thresholds.** Calibration describes groups of answers: among answers at p = 0.8, about 80% are right. Record the probabilities of wrong answers on a sample of your own traffic, then pick the narrowest act band that excludes the errors you can't afford. Keep act bands narrow for destructive actions.

**One escalation stage.** Escalate ambiguous answers to a stronger decider:

```swift
var policy = basePolicy
policy.escalate = DecisionEscalation(to: "jev-xl-2.0", when: .pBetween(0.5, 0.95))
policy.bands["jev-xl-2.0"] = .ranges(confirm: DecisionRange(0, 0.9, upperOpen: true), act: DecisionRange(0.9, 1))
```

The whole request reruns on the target, and the stage-2 answer is final. Both stages are billed. Escalating to a chat model is allowed, but its answers are uncalibrated, so it can only move a decision toward confirm or refuse.

Deferral conditions: `.pBelow`, `.marginBelow`, `.pBetween`, `.spreadAbove` (score), `.refused`, `.unavailable`, combined with `.any([…])` or `.all([…])`. A missing signal counts as a match.

**Writing questions.** Put the evidence in `state` and the judgment in the questions. Prefer several atomic yes/no questions combined in code over one compound question. Never put arithmetic in a question; compute in code and ask about facts. Never put untrusted content, such as tool outputs or web pages, into the state of a gating question.

---

## 4. Bind roles

Internal callers ask for a **role**, never a model. Bind roles once with `RoleBindingResolver`:

```swift
let roles = RoleBindingResolver(
    settings: [
        .gatekeeper: RoleBinding(
            role: .gatekeeper,
            contract: .decide,
            minGuarantee: .calibratedDistribution,   // refuse emulated (uncalibrated) candidates
            pin: "jev-1.13.0",
            fallback: ["jev-1.12.0"],                 // availability errors only, same compatGroup
            priority: .background,
            locality: .any,                           // or .localOnly / .noVendorRetention
            budget: RoleBudget(maxUSDPerCall: 0.001)
        ),
    ],
    modePatches: [:],          // per-mode overrides
    conversationPatches: [:]   // per-conversation overrides
)
```

Resolution order, where later wins: built-in default, then `settings`, then the mode patch, then the conversation patch, then a per-call pin (`DecisionCallContext(pin:)`).

| Field | Notes |
|---|---|
| `pin` | A model id, slug, or declared alias. It must satisfy the contract and `minGuarantee`, or the call fails with `pinRejected`. |
| `fallback` | Ordered. Used only on transient, rate-limited, credential-exhausted, or model-not-found errors. Never used because of a low-quality answer. |
| `minGuarantee` | `.calibratedDistribution` excludes LLM emulation. Leave it unset to allow a named chat model as an emulated decider. |
| `locality` | A hard filter. A `.localOnly` role with no local candidate fails closed. |
| `cascade` | Only for roles without a policy. Otherwise escalation comes from `DecisionPolicy.escalate`. |

**Compat groups.** A `decide` role with a tuned policy falls back only to candidates in the primary's `compatGroup`, because a different model family would need different bands.

**Thinking** never applies to `decide` roles.

Well-known `decide` roles:

| Role | Consumer | Where |
|---|---|---|
| `gatekeeper` | Tool System classifier gate | [Step 6](#6-enable-the-gatekeeper) |
| `memoryGate` | Memory write gate | [Other consumers](#7-other-consumers) |
| `skillFilter` | Context Engine skill pre-filter | [Other consumers](#7-other-consumers) |
| `guardrail` (`"guard"`) | Guardrail battery and tool-output injection probe | [Other consumers](#7-other-consumers) |
| `router` | Per-turn model choice | [Other consumers](#7-other-consumers) |

An unbound `decide` role turns its consuming layer off.

### Mode and conversation overrides

Modes and conversations can patch a role without touching the host's settings. Later layers win: settings, then the mode, then the conversation, then a per-call pin.

In PromptConfig, under a mode profile's `model` slice:

```json
"modeProfiles": [
  {
    "id": "autonomous",
    "model": { "roles": { "gatekeeper": { "pin": "jev-xl-2.0", "minGuarantee": "calibrated-distribution" } } }
  }
]
```

Per conversation, with the REST PATCH:

```json
{ "routingModelOptions": { "roles": { "memory-gate": { "locality": "local-only" } } } }
```

Omitting `roles` leaves stored overrides unchanged, and `{}` clears them. Every consumer loads both layers per call. When calling the dispatcher directly, pass them yourself with `DecisionCallContext(rolePatches:)`.

---

## 5. Build the dispatcher

`ModelPoolDecisionDispatcher` runs the selection pipeline: resolve the role, hard-filter candidates, rank them, cascade at most once, fall back on availability errors, and emit a route receipt.

```swift
let receipts = InMemoryRouteReceiptRecorder(capacity: 500)
let dispatcher = ModelPoolDecisionDispatcher(
    candidates: modelManager,                       // or StaticContractCandidateSource(decider.registryEntries())
    providers: RegistryDecisionProviderResolver(),  // the default: the registered decision slot
    roles: roles,
    scheduler: callScheduler,                       // optional: shared concurrency caps
    budgetAccounting: costLedger,                   // optional: projected and settled spend
    budgetPolicy: budgetPolicy,
    receipts: receipts,                             // the default drops receipts
    cache: DecisionResponseCache(),                 // optional: caches (version, request), never aliases
    logger: logger                                  // the default is Logger(label: "SwiftAgentHarness.ModelPool.Decisions")
)
```

- **`candidates`**: use the host's `ModelManager`, so deciders share one registry with chat models. `StaticContractCandidateSource` works for tests or a decider-only setup.
- **`receipts`**: a route receipt records the version served, alias resolution, fallbacks, cascade, cost, request ids, and the verdict with its band. That answers "why was this approved?" The default `NoOpRouteReceiptRecorder` discards receipts.

Call it directly for your own gates:

```swift
let outcome = await dispatcher.decide(request, role: .memoryGate, policy: memoryPolicy,
                                      context: DecisionCallContext(conversationID: id, timeBudget: .seconds(1)))
switch outcome.verdict {
case .act?: writeMemory()
case .confirm?, .refuse?, nil: skip()          // decide never throws; failures come back conservative
}
```

---

## 6. Enable the gatekeeper

The gatekeeper sits **between the rules and the human**. It runs only after the rules have returned *ask*, so deny rules and the killswitch always win, and the most it can do is turn one *ask* into *allow-once*. It never creates a durable grant.

```swift
let gate = ToolApprovalClassifierGate(
    dispatcher: dispatcher,
    configuration: ToolApprovalClassifierConfiguration(
        policy: policy,                      // question: ToolApprovalClassifierConfiguration.questionID ("verdict")
        role: .gatekeeper,
        maxUserMessages: 3,
        maxCharactersPerMessage: 2_000,
        maxArgumentCharacters: 4_000,        // larger arguments go to the human; they are never truncated
        timeBudget: .seconds(2),             // the gate is on the latency path of every gated call
        allowElevatedTools: false,
        includeUnstampedUserMessages: false
    )
)

let (validation, aliasProbes) = await gate.prepare()
if !validation.canAct {
    logger.error("gatekeeper can never act: \(validation.problems)")
}

let (session, services) = HarnessRuntimeSession.makeProduction(
    /* … */
    toolApprovalClassifierGate: gate        // nil keeps the layer off
)
```

**What `prepare()` does.** It runs the binding check, which makes no network calls: are the policy's bands keyed by a version the bound candidates actually serve? It then pre-connects to the top candidate and probes each declared alias for drift. Call it at startup. If you skip it, the gate still runs the binding check on its first call, but the alias probes never run.

**What it sends.** One `choice` question, `verdict`, with options `clear` and `caution`. The state holds only the user's recent trusted messages and the pending call (tool name and arguments). Tool outputs are never included, because they are the prompt-injection channel.

**When it approves.** Only when all three hold: the answer is calibrated, the chosen option is `clear`, and the policy's verdict is `act`. Otherwise the call goes to the human with one of these reasons:

| `ToolApprovalClassifierAskReason` | Meaning |
|---|---|
| `notInActBand` | `clear`, but below the act threshold. |
| `caution` | The decider chose `caution`. |
| `untunedVersion` | The answering version has no bands, or answered as an alias. This is a configuration problem. |
| `uncalibrated` | An emulated (chat model) answer. |
| `failed` | Timeout, error, unbound role, or no candidate. |
| `noTrustedUserRequest` | No trusted user message to judge against; the decider is not called. |
| `argumentsTooLarge` | The arguments exceed `maxArgumentCharacters`. |
| `elevatedTool`, `excludedTool`, `parentRoute` | Elevated tools (unless allowed), excluded tools such as `exit_plan_mode`, and calls routed to a parent always go to the human. |

Approvals carry the reason `classifier: clear p=… model=… band=act receipt=…`, along with resolution kind and source `classifier`. `gate.records` holds the most recent requests and outcomes, so a misclassification can be traced back to the exact input.

---

## 7. Other consumers

Four more layers can use deciders. Each is off unless you pass it in `DecisionConsumers`, and each takes the spec's failure default when its role is bound but the call fails:

```swift
let consumers = DecisionConsumers(
    memoryWriteGate: MemoryWriteDecisionGate(dispatcher: dispatcher, configuration: MemoryWriteGateConfiguration(policy: durablePolicy)),
    skillFilter: SkillFilterDecisionGate(dispatcher: dispatcher, configuration: SkillFilterConfiguration(policy: appliesPolicy)),
    guardrails: GuardrailDecisionBattery(dispatcher: dispatcher, configuration: GuardrailConfiguration(
        inbound: [GuardrailCheck(id: "credential", instructions: "Does the text contain a password, API key, or token?")],
        outbound: [GuardrailCheck(id: "credential", instructions: "Does the text contain a password, API key, or token?")],
        policies: ["credential": credentialPolicy]
    )),
    injectionProbe: InjectionProbeDecisionGate(dispatcher: dispatcher, configuration: InjectionProbeConfiguration(policy: injectionPolicy)),
    modelRouter: ModelRouterDecisionGate(dispatcher: dispatcher, configuration: ModelRouterConfiguration(policy: routerPolicy))
)
let (session, services) = HarnessRuntimeSession.makeProduction(
    /* … */
    toolApprovalClassifierGate: gate,
    decisionConsumers: consumers
)
```

| Consumer | Question (policy `question`) | What `act` means | Otherwise | Failure default |
|---|---|---|---|---|
| `MemoryWriteDecisionGate` | `durable`: does the added text state a durable fact? | The memory write proceeds. | Declined, with a message to the model. | Don't write. |
| `SkillFilterDecisionGate` | `applies`: would a listed skill help? Plus a `skill` choice. | The top skills are injected as a `[Skill Shortlist]` note on the first model call. | Nothing added. | Load nothing extra. |
| `GuardrailDecisionBattery` | One yes/no per check id (`yes` = violation). | That check passes. | `refuse` blocks; `confirm` flags for review. | Review. |
| `InjectionProbeDecisionGate` | `injection`: does the content give instructions to an AI? | Nothing added. | A warning is prepended (stronger for `refuse`). | Warn. |
| `ModelRouterDecisionGate` | `model`: a choice over ranked candidate slugs. | The turn runs on the chosen model. | The conversation's model. | The conversation's model. |

Write policies with the polarity in mind. For the guardrail checks and the injection probe, P(yes) means a problem, so the act band sits at the **low** end:

```swift
let injectionPolicy = DecisionPolicy(question: InjectionProbeConfiguration.questionID, bands: ["jev-1.13.0": .ranges(
    refuse: DecisionRange(0.8, 1),
    confirm: DecisionRange(0.2, 0.8, upperOpen: true),
    act: DecisionRange(0, 0.2, upperOpen: true)
)])
```

Placement and caveats:

- **Memory gate:** checks `write_file` and `edit_file` inside the memory directory. Only the added text is judged. Dreaming promotions and `bash` writes are not gated.
- **Skill filter:** the frozen skills index in the system prompt is never changed, so prompt caching is unaffected. The shortlist steers the model; it doesn't shrink the prompt.
- **Guardrails:** inbound runs before the message is saved, and a block answers the turn without calling the model. Outbound runs on structured delivery through the message tool; streamed assistant text is not guarded. Sub-agent conversations are skipped.
- **Injection probe:** runs only on external content (results the envelope wraps), adds one decide call per such result, and never blocks or rewrites. The envelope still wraps the content.
- **Router:** the conversation's stored model doesn't change. Switching models loses the warm prompt cache, so keep the act band high.

## 8. Route receipts on the event bus

Publish receipts to the conversation's event stream so surfaces and observability can show which model answered and why:

```swift
let receipts = CompositeRouteReceiptRecorder([
    ConversationEventsRouteReceiptRecorder(publisher: communicationLayer),   // conversation/{id}/events
    InMemoryRouteReceiptRecorder(),                                          // local audit log
])
let dispatcher = ModelPoolDecisionDispatcher(candidates: modelManager, roles: roles, receipts: receipts)
```

Each call inside a conversation emits a transient `routeReceipt` event (`RouteReceiptWire`). Its `summary` reads like `gatekeeper answered by jev-1.13.0 via typesafe/jev-1.13.0 (fallback from a/primary: transient) → act`. Receipts carry no prompt or response content, and vendor request ids are hashed. Decode them with `ConversationTopicWireDecoding.decodeEvent(line:)`, which returns `.routeReceipt(wire, seq:, turnOrdinal:)`.

## Keeping connections warm

URLSession can't set a TCP keepalive, so run the keep-warm loop in a task you own:

```swift
let warmTask = Task { await dispatcher.keepWarm(role: .gatekeeper) }   // pings every 240 s
// at shutdown:
warmTask.cancel()
```

It calls only the decider's `v1/models` endpoint, never a billed decide call.

---

## Troubleshooting

| Log message | Cause | Fix |
|---|---|---|
| `decide role=gatekeeper will never act: policy is tuned for [X] but its candidates serve [Y]` | The band keys don't match any served version. | Key the bands by `Y`, the pinned `endpointModelID`. |
| `policy bands are keyed by moving alias jev-latest and will never match` | Bands are under the alias. | Re-key them by the pinned version. |
| `candidate is addressed by moving alias jev-latest` | `endpointModelID` is an alias. | Set it to the versioned id and move the alias into `aliases`. |
| `answered by jev-1.14.0; policy is tuned for [jev-1.13.0]` | A version without bands answered, for example a fallback or an alias you pinned by mistake. | Add bands for that version, or pin the version you tuned. |
| `was answered as alias jev-latest, so the version that answered is unknown` | The server echoed the alias in `model`. | Pin a versioned id. If the server always echoes, ask the vendor for versioned responses. |
| `alias jev-latest now serves jev-1.14.0 but … is pinned to jev-1.13.0` | The vendor moved the alias. | Nothing breaks. Re-tune for the new version when you are ready to adopt it. |
| `is bound but no registry entry can serve it` | No candidate. Usually a local server without a `.local` auth profile, or a missing API key env var. | See [Local decision servers](#local-decision-servers), or set the key. |
| `decide call failed on …: model-not-found` | A 404 response: the pinned version was retired, or the URL is wrong. | Check `endpointModelID` against the vendor's model list, and `serverURL` against the API root. |
| Gate always asks, no log lines | The dispatcher was built with a logger the host filters out, or the role is unbound. | Check `gate.validation?.problems` and `outcome.receipt.decision?.reason`. |

## Reference

| Type | File |
|---|---|
| `DecisionRuntimeConfig`, `DecisionModelConfig` | `Sources/SwiftAgentHarness/Backends/Providers/Decisions/DecisionRuntimeConfig.swift` |
| `DecisionRequest`, `DecisionQuestion`, `DecisionResult` | `Sources/SwiftAgentHarness/Backends/Providers/Decisions/DecisionTypes.swift` |
| `DecisionProfiles`, `DecisionFeatureKey` | `Sources/SwiftAgentHarness/Backends/Providers/Decisions/DecisionSurfaceOptions.swift` |
| `DecisionPolicy`, `DeferralCondition` | `Sources/SwiftAgentHarness/Core/ModelPool/Decisions/DecisionPolicy.swift` |
| `ModelPoolDecisionDispatcher` | `Sources/SwiftAgentHarness/Core/ModelPool/Decisions/ModelPoolDecisionDispatcher.swift` |
| `DecisionBindingValidation`, `DecisionAliasProbe` | `Sources/SwiftAgentHarness/Core/ModelPool/Decisions/DecisionBindingDiagnostics.swift` |
| `RoleBinding`, `RoleBindingResolver`, `ModelRole` | `Sources/SwiftAgentHarness/Core/ModelPool/ModelClasses/ModelRole.swift` |
| `RouteReceipt` | `Sources/SwiftAgentHarness/Core/ModelPool/ModelClasses/RouteReceipt.swift` |
| `ToolApprovalClassifierGate` | `Sources/SwiftAgentHarness/Core/ToolSystem/ToolApprovalClassifierGate.swift` |
