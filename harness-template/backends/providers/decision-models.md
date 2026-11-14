# Decision Models — Wire Protocol, Adapters, and Policy

> Sibling page of [providers/README.md](./README.md). It specifies the provider-side half of the `decide` contract defined in [model-pool/model-classes.md](../../core/model-pool/model-classes.md): the normalized request and result types, the wire codecs for the two dialects in use, the LLM-emulation fallback, transport rules, and the policy layer that turns probabilities into harness decisions.

## TL;DR

A **decision model** answers closed questions about a piece of state and returns a **calibrated probability distribution per question**. It does not generate text and it does not stream. A typical call is ~50–500 ms. Only input tokens are billed, so at the cheapest hosted price a thousand short calls cost about a cent; cost scales with state size. The category took off in 2026 around a hosted classifier whose request shape (`state` plus a map of typed questions) became a de facto standard, usually called **SystemOne**. That shape is now served by a cloud edge platform, a model directory's decisions route, local inference servers (vLLM and Ollama; llama.cpp support was reported but may still be pre-release), and most gateways. OpenAI shipped a second dialect (`/v1/decisions`) with the same semantics and different field names.

The prescriptive shape:

1. **A separate contract, not a chat variant.** Decision offerings register under the `decide` contract with their own codec. Chat endpoints reject these models, and a chat adapter cannot carry their output.
2. **One normalized schema**, close to SystemOne: `state` (string | object | array, plus optional image assets) and an ordered map of typed questions (`yes-no`, `choice`, `score`, `box`). Typed answers always keep the full distribution and add an explicit `refusal` / `unavailable` case.
3. **Three codecs.** SystemOne (reference dialect plus per-server quirks), OpenAI Decisions, and an **LLM-emulation** codec over the `generate` contract that is always flagged `calibrated: false`.
4. **The harness computes confidence itself** from `probabilities`. Vendor `confidence` fields use incompatible definitions.
5. **Thresholds belong to a pinned model version.** Act / confirm / refuse bands are per question and keyed to the version that answered. A moving alias never carries tuned thresholds.
6. **At most one escalation stage.** A conditional rerun on a stronger decider or on the main LLM, triggered by a low computed probability or margin, an ambiguous probability band, a refusal, or an unavailable signal. Only a calibrated target can upgrade an answer to *act*.
7. **Never the only gate on untrusted content.** Decision models are measurably steerable by injected text in the state. They pre-filter and route. They do not replace rules, sandboxes, or human approval for high-risk actions.

---

## How this fits the architecture

| Concern | Owner | Why |
|---|---|---|
| Which decider answers, fallback, cascade, budget, receipt | [Model Pool](../../core/model-pool/model-classes.md#the-selection-pipeline) | Selection policy is a Pool concern for every contract |
| Wire encoding, dialect quirks, error classification | Provider plugin (`decide` slot) | Same split as text inference: the provider classifies, the Pool decides |
| Question authoring, thresholds, bands, what to do with the answer | The consuming layer (Tool System gate, Context Engine, Memory, Interface) | Only the consumer knows the cost of a false positive versus a false negative |
| Shared policy helpers (`band()`, `confidence()`, escalation conditions) | A small `decision-policy` library next to the Pool | Consumers must not each re-derive calibration math |

A decision offering is registered exactly like a text one, through a provider plugin whose manifest declares the `decision` slot and whose catalog rows carry a `decide` contract profile. A single vendor can ship both: a general LLM can be served through `generate` and also through a decisions endpoint. That is one `ModelEntry` with two contract profiles.

---

## Recommendation

### Normalized request and result

```ts
type DecisionRequest = {
  state: JsonValue                          // string | object | array; keep evidence here, judgments in questions
  assets?: Record<string, ImageAsset>       // referenced by key from state / instructions / criteria
  questions: OrderedMap<string, Question>   // ids are the caller's; codecs keep order and ids stable
}

type Question =
  | { kind: "yes-no"; instructions: Entry; criteria?: { yes?: Entry; no?: Entry } }
  | { kind: "choice"; instructions: Entry; options: OrderedMap<string, Entry | null> }   // 2..255
  | { kind: "score";  instructions: Entry; levels: Entry[] }                            // 2..10, ordered low→high
  | { kind: "box";    instructions: Entry }                                             // locate in an image asset

type Entry = string | JsonObject | JsonValue[]  // structured instructions are allowed and encouraged

type ImageAsset = { mediaType: "image/png" | "image/jpeg"; blobRef: string }

type DecisionResult = {
  modelVersion: string                      // the versioned id that answered, never the alias
  calibrated: boolean                       // false for LLM-emulated answers
  answers: Record<string, Answer>
  usage: NormalizedUsage                    // input tokens; output tokens are informational
  requestId?: string                        // vendor request id for support and audit
}

type Answer =
  | { kind: "yes-no"; pYes: number }
  | { kind: "choice"; choice: string; probabilities: Record<string, number> }
  | { kind: "score";  expected: number; probabilities: number[] }       // expected = Σ i·p_i
  | { kind: "box";    box: { top: number; left: number; bottom: number; right: number }; peak?: number }
  | { kind: "refusal"; reason?: string }                                 // model declined this question
  | { kind: "unavailable"; reason: "emulated-no-probability" | "missing-in-response" | "invalid-distribution" }
```

Design notes:

- **Question ids are not sent to the model** in the reference dialect. They are the caller's keys. Use descriptive ids for logs anyway. Codecs for dialects that need a `name` echo the id there.
- **Keep content in `state` and judgments in `questions`.** One state, many atomic questions, combined in code. That is how the models are trained and how they batch for nearly free: questions are scored in parallel against the same state, and adding questions or options barely moves latency. Prefer five atomic yes/no questions combined by a formula over one compound question. Published tests show large accuracy gains from that change.
- **There is no extraction or generation question kind.** For "find the span," generate candidates in code (regex, parse) and ask a `choice` over them. For multi-label, ask one `yes-no` per label.
- **Every requested id gets an answer.** A request either returns an answer for every question or fails as a whole. A per-question `refusal`, which one dialect emits, *is* an answer. A response that omits a requested id is a codec error. The codec maps it to `unavailable("missing-in-response")` rather than dropping it, so policy sees it and takes the conservative branch.
- **Validate distributions.** Require finite values in [0, 1] that sum to 1 within ±0.01, with the chosen option equal to the argmax. Local servers in particular can violate this. A violation becomes `unavailable("invalid-distribution")`, never a silently renormalized answer.

### Codec 1: SystemOne (the reference dialect)

```
POST {base}/v1/systemone
Authorization: Bearer <key>
Content-Type: application/json            (multipart/form-data when sending image parts)
Content-Encoding: gzip | zstd             (optional; one layer)

{ "model": "<versioned-id>",
  "state": <string | object | array>,
  "questions": {
    "<id>": { "type": "noul",   "instructions": <Entry>, "criteria": { "true": <Entry>, "false": <Entry> } },
    "<id>": { "type": "choice", "instructions": <Entry>, "criteria": { "<option>": <Entry|null>, ... } },
    "<id>": { "type": "score",  "instructions": <Entry>, "criteria": [ <Entry>, ... ] },
    "<id>": { "type": "box",    "instructions": <Entry> } },
  "assets": { "<ref>": { "type": "image", "format": "png|jpg", "data_base64": "..." | "part": "<name>" } } }

→ 200 { "model": "<versioned-id>",
        "answers": {
          "<id>": { "type": "noul",   "noul": 0.95 },
          "<id>": { "type": "choice", "choice": "billing", "probabilities": { "billing": 0.88, ... }, "confidence": 0.81 },
          "<id>": { "type": "score",  "score": 1.05, "legend": { "0": "...", ... }, "probabilities": { "0": 0.0, ... }, "confidence": 0.92 },
          "<id>": { "type": "box",    "box": { "top": 0.1, "bottom": 0.4, "left": 0.2, "right": 0.6 }, "confidence": 0.7 } },
        "usage": { "input_tokens": 318, "output_tokens": 34 } }
```

Mapping: `noul` ↔ `yes-no` (`noul` is P(yes)), `criteria` map ↔ `options`, `criteria` array ↔ `levels`, response `score` ↔ `expected`, string-keyed level probabilities ↔ array. Drop the vendor `confidence` (see [§ Confidence](#confidence-is-computed-not-trusted)).

At the reference vendor, the `box` kind and any image asset need a model version that supports them (currently the newest release, not the stable alias) and the images opt-in header on the request. The codec adds both when the request contains a `box` question or assets. When the binding's version lacks image support, the Pool's hard filter rejects the binding.

**Per-server quirks the codec must absorb.** Encode them as binding config, not code branches:

| Quirk | Seen in | Codec handling |
|---|---|---|
| Response wrapped in a platform envelope `{success, errors, result:{...}}` | an edge-platform REST route (its in-worker binding returns the bare payload) | `unwrap: "result"` |
| `model` must be the server's own name; vendor aliases rejected | edge platform | `endpointModelId` from the binding, never the alias |
| `model` optional; only selects a model when the server hosts several | llama.cpp server | Send the binding's id when routing, otherwise omit |
| Images as a top-level `images` array (data URLs) instead of `assets` | llama.cpp, vLLM, Ollama, edge platform | `imagesEncoding: "images-array"`; reference by index in `state` |
| Image feature behind an opt-in header | reference vendor (`…-Danger-Zone-Images: true`), also a long-context opt-in header | `headers` from feature params; set only when the request uses the feature |
| Max questions per request | 64 on the edge platform, Ollama and vLLM; no stated limit at the reference vendor | `limits.maxItemsPerCall`; the codec splits and merges, since answers are independent |
| Context limits per request and per question | 64k / 32k tokens at the reference vendor | `limits.contextTokens`; a `max_tokens_exceeded` 400 → `context-overflow` |
| Image limits (PNG/JPEG, 280–1568 px per edge, 78,400–2,458,624 total pixels; out-of-range is rejected, not resized) | reference vendor | Resize in the codec into the declared window before sending |
| `output_tokens` always 0, or a billing artifact rather than decoded tokens | most | Bill input only; keep output as informational usage |
| Different `confidence` definition | vLLM serving rule: the chosen option's probability | Ignored; computed locally |

### Codec 2: OpenAI Decisions

```
POST https://api.openai.com/v1/decisions
{ "model": "...",
  "input": "<string>" | [ { "role": "user", "content": [ {"type":"input_text","text":"..."},
                                                         {"type":"input_image","image_url":"data:..."} ] } ],
  "questions": [
    { "type": "predicate", "name": "<id>", "instructions": "..." },
    { "type": "choice",    "name": "<id>", "instructions": "...", "choices": [ { "value": "...", "description": "..." } ] },
    { "type": "score",     "name": "<id>", "instructions": "...", "levels":  [ { "label": "...", "description": "..." } ] } ] }

→ { "model": "...", "answers": [ { "type": "predicate", "name": "<id>", "probability": 0.93 },
                                 { "type": "choice", "name": "<id>", "choice": "...", "confidence": 0.7,
                                   "probabilities": [ { "value": "...", "probability": 0.8 } ] },
                                 { "type": "refusal", "name": "<id>" } ],
    "usage": { "input_tokens": ..., "output_tokens": ..., "total_tokens": ...,
               "input_tokens_details": { "cached_tokens": ... } } }
```

Mapping rules:

- **Containers.** Map ↔ array via `name`; answers come back in question order and carry the `name`.
- **Yes/no.** `predicate` ↔ `yes-no`, and `probability` ↔ `pYes`. `predicate` has no criteria field, so the codec folds normalized `criteria.yes` / `criteria.no` into `instructions` as a structured suffix ("Answer yes if …; answer no if …").
- **Choice.** Each option becomes `{value: <option id>, description: <Entry serialized to text>}`. A `null` Entry omits `description`. The dialect treats the string `"true"` and the boolean `true` as different values, so the codec only ever sends **string** values and rejects an options map that would need a boolean. Response `probabilities: [{value, probability}]` → `Record<optionId, number>`.
- **Score.** Each level becomes `{label, description?}`. The label is the level's text when the Entry is a short string. Otherwise it is a synthesized `L0…Ln` with the serialized Entry as `description`. Response `probabilities: [{label, value, probability}]` → `number[]`, ordered by `value` (the zero-based level index). `score` → `expected`.
- **State.** Serialized to text: objects become stable, pretty-printed JSON, and images become `input_image` parts (inline data URLs only).
- **Refusal.** A per-question `refusal` maps through unchanged.
- **No `box`.** The dialect has no `box` kind, so declare `questionTypes` without it.

### Codec 3: LLM emulation (fallback over `generate`)

When no decision offering is bound, or for a question kind or language the bound decider handles poorly, the harness can emulate `decide` with a chat model. Emulation is **always tagged `calibrated: false`** and exposes which guarantee rung produced it:

1. **Logprobs rung.** One constrained-token answer per question (`A`/`B`/`C…` for choices, `Y`/`N` for yes-no), with `top_logprobs` read and renormalized over the legal tokens. This gives a usable distribution, but it is not calibrated.
2. **Schema rung.** A strict JSON schema with an enum per question. The model returns a label and no probability. The codec emits `{kind: "unavailable", reason: "emulated-no-probability"}` and attaches the label as advisory metadata. It never emits a synthetic distribution like `{label: 1}`, because that would read as maximal confidence.

Emulation exists so the harness keeps working without a decider. It is not a reason to skip binding one. **Uncalibrated results are `unavailable` to policy by construction:** `signals()` returns `unavailable` whenever `result.calibrated` is false. The one exception is a policy that carries bands tuned for that exact emulating model version and sets `acceptsUncalibrated` (see [§ Policy](#policy-thresholds-bands-escalation)).

### Capability descriptor

The `decide` contract profile on a binding carries:

```ts
features: {
  questionTypes: { supported: true, params: { kinds: ["yes-no", "choice", "score", "box"] } },
  questionSet:   { supported: true, params: { mode: "open" } },     // "fixed" = vendor-defined categories (moderation)
  images:        { supported: true, params: { encoding: "assets" | "images-array" | "parts", optInHeader?: string,
                                              formats: ["png", "jpeg"], edgePx: [280, 1568],
                                              totalPixels: [78400, 2458624] } },
  longContext:   { supported: true, params: { optInHeader: "...", contextTokens: 262144 } },
  calibration:   { supported: true, params: { method: "vendor-trained", vendorConfidence: "chance-normalized" | "p-max" | "opaque" } },
  languages:     { supported: true, params: { strong: ["en"], weak: ["zh", "ja", "ko"] } }
}
limits: { contextTokens: 65536, maxItemsPerCall: 64, maxOptions: 255, scoreLevels: [2, 10] }
```

The Pool's hard filter (step 2 of the [selection pipeline](../../core/model-pool/model-classes.md#the-selection-pipeline)) rejects a binding that cannot answer every question kind in the request or that would exceed `maxOptions`. Splitting by `maxItemsPerCall` is the codec's job, not the caller's.

### Transport

- **No streaming.** The whole result arrives at once. Use the `unary` state machine.
- **Retries:** 408, 429, 529 ("overloaded"), and 5xx, with jittered exponential backoff (≈0.25–5 s). Honor `retry-after` and `retry-after-ms`. Use a **total** time budget across attempts rather than a per-attempt timeout, because a gate stuck in retries is worse than a gate that fails conservatively. Calls are stateless reads, so retrying is safe with no idempotency key.
- **Keep connections warm.** On ~100 ms calls, a cold TLS handshake is a large share of the latency. Pre-connect at startup (a cheap `GET /v1/models` works) and keep the keepalive below the vendor's idle-close window. The reference vendor closes idle connections after about 5 minutes, so a 240 s keepalive is a common choice. HTTP/2 helps at low-to-moderate concurrency. At very high request rates, a pool of HTTP/1.1 connections is what the vendor SDK defaults to.
- **Compression.** Compress bodies above ~1 KiB when the server accepts it. States are often large JSON.
- **Audit.** Capture the vendor request id header and the response's versioned `model` in the route receipt.
- **Error classification** (provider → Pool):
  - 401/403 → `auth-error`.
  - 400 with a token-limit code → `context-overflow`. The codec may split the questions across requests, or trim the state, and retry once.
  - 413 (body over the size cap, almost always image assets) → `permanent`, unless the codec can re-encode or drop assets and retry once.
  - 415/422 → `permanent`. This is a codec bug; log it with the field named in the body.
  - 429 → `rate-limited`.
  - 408/529/5xx/timeout → `transient`.
- **Billing.** Settle on input tokens. Most deciders price output at zero. Where a vendor reports output tokens as a billing artifact, record them as informational usage only.

### Confidence is computed, not trusted

Vendors disagree on what `confidence` means:

- At the reference vendor it is chance-normalized peakedness, `(p_max − 1/n) / (1 − 1/n)`. Choice distributions (0.6, 0.3, 0.1) and (0.6, 0.2, 0.2) both score 0.4.
- A popular local serving recipe uses the chosen option's probability.
- OpenAI publishes no formula.

None of these is "probability of being right." The policy library therefore derives its own signals from the distribution:

```ts
type Signals =
  | { p: number; margin: number }                     // yes-no: p = P(yes); choice: p = top-1 probability
  | { expected: number; spread: number }              // score
  | { unavailable: true }

function signals(a: Answer, result: DecisionResult, policy: DecisionPolicy): Signals {
  // Uncalibrated answers carry no usable probability unless this policy was tuned on this exact emulator.
  if (!result.calibrated && !(policy.acceptsUncalibrated && policy.bands[result.modelVersion]))
    return { unavailable: true }
  switch (a.kind) {
    case "yes-no": return { p: a.pYes, margin: Math.abs(2 * a.pYes - 1) }
    case "choice": { const ps = Object.values(a.probabilities).sort((x, y) => y - x)
                     return { p: ps[0], margin: ps[0] - (ps[1] ?? 0) } }       // top-1 vs top-2
    case "score":  { const e = a.expected                                       // spread over the level distribution
                     return { expected: e, spread: Math.sqrt(a.probabilities.reduce((s, p, i) => s + p * (i - e) ** 2, 0)) } }
    default:       return { unavailable: true }                                 // refusal, unavailable, box
  }
}
```

**Calibration is a property of groups of predictions.** Among answers given p = 0.8, about 80% should be right. It is not a guarantee about any one answer. Thresholds are therefore set from labeled examples: record the probabilities of incorrect answers on a sample of your own traffic, then pick the narrowest band that catches the errors worth paying for.

### Policy: thresholds, bands, escalation

```ts
type Bands =
  | { refuse?: Range; confirm?: Range; act?: Range }                // on p (yes-no / choice) or margin, per `on`
  | { levels: ("act" | "confirm" | "refuse")[] }                    // score: verdict per rounded expected level

type DecisionPolicy = {
  question: string                            // question id
  on?: "p" | "margin"                         // which signal the ranges test (default "p")
  bands: Record<string, Bands>                // keyed by modelVersion: primary, escalation target, AND every fallback
  acceptsUncalibrated?: boolean               // only meaningful with bands tuned for that exact emulating version
  onUnavailable: "confirm" | "refuse"         // NEVER "act"; also used for untuned versions and range gaps
  onRefusal: "confirm" | "refuse"
  onError: "confirm" | "refuse"               // there is deliberately no fail-open value; gates fail closed
  escalate?: { to: string; when: DeferralCondition }   // one stage; this is the ONLY place escalation is declared
}

type DeferralCondition =
  | { pBelow: number; question?: string }                          // computed signals, never vendor confidence
  | { marginBelow: number; question?: string }
  | { pBetween: [number, number]; question?: string }              // ambiguous band for yes-no
  | { spreadAbove: number; question?: string }                     // score
  | { refused: true } | { unavailable: true }
  | { any: DeferralCondition[] } | { all: DeferralCondition[] }
```

- **Three bands, scaled to risk.** *Act* automatically, *confirm* (ask a human, gather more context, or escalate), or *refuse*. Destructive or irreversible actions get a narrow act band, and a reasonable default is to never act on them from a decision alone.
- **Evaluation order is conservative.** Test *refuse*, then *confirm*, then *act*. Validate at load time that the ranges are disjoint. A value that falls in no range, a gap, gets `onUnavailable`. A misconfigured policy can therefore over-ask but never over-act.
- **Escalation is one stage, declared once.** The consuming policy declares `escalate`. For `decide` roles the Pool executes it as the role's cascade, and `RoleBinding.cascade` is derived from the policy rather than set separately. The whole request reruns on the escalation target. Answers are not merged, and the stage-2 answer is final. A missing or non-finite signal counts as a match for escalation, the conservative reading. Both stages are billed and their latencies add, so record that in the receipt.
- **Bands are keyed by the version that answered.** The policy must carry bands for the primary version, the escalation target, and every fallback the role may use. An answer from a version with no bands is "untuned" and resolves to `onUnavailable`, which by construction is never `act`. Consequences:
  - **Escalate to a stronger *calibrated* decider** if stage 2 should be able to act.
  - **Escalating to a chat LLM** (an uncalibrated emulation) can only move a decision toward confirm or refuse. That is still useful for an explained refusal, but it never upgrades to *act*.
  - **When the role's pinned version changes,** the old bands no longer match, and the policy operates conservatively until it is re-tuned.

### Where the harness uses deciders

| Integration | Layer | Question shape | Failure default |
|---|---|---|---|
| **Classifier-assisted permission gate.** It sits between rules and the human and can only turn `ask` into `allow-once`. | [Tool System](../../core/tool-system/permissions.md#classifier-assisted-gating-optional-layer) | `choice` over `{clear, caution}` on tool name + arguments + the user's request. **No tool outputs in the state.** | `ask` |
| **Skill / tool pre-filter.** Narrow 100+ skills to a few before the main call. | [Context Engine](../../core/context-engine/system-prompt-composition.md) | One `choice` over skill names + `yes-no` gates ("does any skill apply?") | Load nothing extra |
| **Memory-write gate.** "Does this state a durable fact?" | [Memory](../../core/memory/memory.md) | `yes-no` per candidate | Don't write |
| **Model router.** Pick a policy or tier for the turn. | [Model Pool](../../core/model-pool/model-classes.md#the-selection-pipeline) | `choice` over policy ids | Role default |
| **Guardrail battery.** Inbound and outbound. | Conversation Manager / Interface | Several `yes-no` checks + a severity `score` in one call | Review |
| **Tool-output injection probe** | [Input provenance](../../surfaces/triggers/input-provenance.md) | `yes-no` on tool output | **Warn, don't block.** The probe itself reads untrusted text. |
| **Voice turn decisions** (voicemail detection, UI intent) | [Interface voice](../../surfaces/interface/voice.md) | `choice` per transcript segment | Continue listening |
| **Computer-use action intent check** (`guard` role) | [Computer use](../computer-use/README.md#safety-is-layered-not-a-single-gate) | `yes-no`: "is this action consistent with the user's task?" The state holds the task, a text history of prior actions, and the proposed action described by **harness-derived identifiers only** (action kind, app bundle id or domain, element role). It never includes screen text or on-screen labels. | Confirm |

Common rules across these: background priority unless the user is blocked on the answer; thinking never applies (deciders have none, and emulated deciders resolve thinking to disabled); all questions about one state in one request; and the decision, its version, and the band it fell in recorded in the route receipt so an approval can always be explained.

### Known weaknesses that shape the design

- **Injection-sensitive.** In published tests a single injected instruction in the state changed 12–22% of answers. Keep untrusted content (tool outputs, web pages, screen text) out of the state for *gating* questions. When it must be in the state, as in the injection probe, the answer can only *add* caution, never remove it.
- **Literal and shallow.** These models are weak at counting, arithmetic, date math, and indirection, and accuracy drops with large irrelevant state. Do numbers and policy in code, and ask the model only about facts.
- **Position effects.** Option order matters, but sources disagree on the direction. The reference vendor reports a bias toward the first option. One black-box study found end-of-list placement most accurate, and found that adding an irrelevant option shifts the probabilities of the others. Freeze option order per policy, and shuffle only when calibrating.
- **Language skew.** Accuracy is lower outside the primary training language. Declare `languages` on the binding and let the Pool route other languages to a different decider or to emulation.
- **No explanations.** If a human needs a reason, the reason is the question, the band, and the probability, not prose from the model.

---

## Alternatives

### Chat model with a JSON schema as the classifier

Ask the main or a small chat model to return `{"label": ...}` under a strict schema.

**When this works:** prototypes, rare one-off classifications, and question kinds or languages no available decider covers.

**Why not as default:** there is no probability, so no thresholds, no bands, and no meaningful cascade. Each question also costs a full generation call: output tokens, and thinking unless disabled. A decider answers a whole battery of questions in one input-priced call. Keep the chat model as the emulation codec's last rung, flagged uncalibrated.

### Encoder classifiers and zero-shot NER models

Small encoder models (hundreds of millions of parameters) run in milliseconds on CPU.

**When this works:** a fixed, narrow label set you can fine-tune on, such as a prompt-injection detector or a language-ID or toxicity filter.

**Why not as default:** they are trained or fine-tuned for one label set and do not take arbitrary instructions and criteria per question. In one 2026 comparison of decision models, the small encoder-class entries scored far below the decoder-based deciders on open policy-style questions. They are a good fit for one tuned job each, not for a general `decide` contract. Register them as `decide` offerings with `questionSet: "fixed"`, behind a mapping layer if their native API is label-based.

### A vendor-SDK-per-dialect integration

Use each vendor's client library directly in the consuming layer.

**When this works:** a single integration (one gate, one vendor) in a harness with no Model Pool.

**Why not as default:** thresholds, budget, receipts, and fallback end up scattered across consumers. The two dialects are small enough that two codecs plus a normalized type cost less than living with the drift.

---

## Anti-patterns

- **Trusting the vendor `confidence` field across vendors.** It means different things at different vendors. Compute signals from `probabilities`.
- **Tuning thresholds on an alias.** `*-latest` moves. Pin a version and record the served version on every result.
- **A decision model as the sole gate on untrusted input.** It reads the same injected text the main model does. It can tighten a gate, never open one on its own for high-risk actions.
- **Feeding tool outputs into the permission classifier's state.** That is the direct injection path into the gate. Give the gate the user's request and the proposed action only.
- **Compound questions.** "Is this safe and in scope and not destructive?" scores worse than three yes-no questions combined in code, and the combination rule should be visible policy anyway.
- **Arithmetic in the question.** "Is the total over $500?" Compute the total in code and ask about facts.
- **Silently renormalizing a broken distribution.** A local server that returns probabilities summing to 1.3 has a bug. Return `unavailable` so policy goes conservative.
- **One request per question.** That wastes the near-free batching and multiplies connection overhead. Fan out every question you might need about a state in one call.
- **Fail-open defaults on gates.** A timeout or 5xx on a permission gate means *ask*, not *allow*.

---

## Cross-references

- [model-pool/model-classes.md](../../core/model-pool/model-classes.md): the `decide` contract, output-guarantee ladder, roles (`gatekeeper`, `guard`, `router`, `skill-filter`, `memory-gate`), selection pipeline, route receipts.
- [providers/README.md](./README.md): plugin shape, manifest slots, failover classification. Decision codecs follow the same runtime contract.
- [tool-system/permissions.md](../../core/tool-system/permissions.md): classifier-assisted gating, where the `gatekeeper` answer lands.
- [surfaces/triggers/input-provenance.md](../../surfaces/triggers/input-provenance.md): the optional classifier-based injection layer.
- [backends/computer-use](../computer-use/): per-action intent checks.
