# PromptConfig.json Reference

`PromptConfig.json` is the host-supplied configuration document for SwiftAgentHarness. **The entire file is optional**, and so is every key in it: the library ships a compiled-in locked-down baseline (`HarnessConfigurationSet.lockedDownBaseline`), and any key you omit falls back to the default listed below. Unknown top-level keys are not an error — they are collected and logged as a warning at parse time.

## How the harness receives configuration

Configuration is host data, resolved **once** and passed into the session — the library never re-reads it after construction.

```swift
// Option 1 — from ambient delivery (file/env/bundle chain below):
let config = HarnessConfigurationSet.resolveFromAmbient(logger: logger)

// Option 2 — from explicit bytes/URL:
let document = try PromptConfigDocument.parse(url: configURL, logger: logger)
let config = HarnessConfigurationSet.load(from: document, logger: logger)

// Option 3 — no JSON at all (typed Swift, starts from the locked-down baseline):
let config = HarnessConfigurationSet.Builder()
    .withToolPolicy(myToolPolicy)
    .withModeProfiles(myProfiles)
    .build()

let (session, services) = HarnessRuntimeSession.makeProduction(
    configuration: config,   // required — no default
    ...
)
```

`resolveFromAmbient` locates the file via `PromptConfigBundleResource`, first match wins:

1. Programmatic override — `PromptConfigBundleResource.configure(url:/bundle:/data:)`
2. `SAH_PROMPT_CONFIG` environment variable (absolute or `~`-prefixed file path)
3. `PromptConfig.json` in `Bundle.main`
4. Bundles registered via `registerBundle(_:)`

If nothing resolves (or the file fails to parse), the locked-down baseline is used and a warning is logged.

## Top-level sections

All thirteen recognized top-level keys, each optional:

| Key | Configures |
|---|---|
| [`options`](#options) | System-prompt assembly toggles |
| [`settings`](#settings) | Skills folder, thinking defaults, Model Pool preference/budget/failover |
| [`agentHarness`](#agentharness) | Agent-build loop behavior |
| [`toolPolicy`](#toolpolicy) | Tool approval / escalation / elevation / dispatch / execution-environment policy |
| [`subAgentHostingPolicy`](#subagenthostingpolicy) | Delegate-tool hosting and routing |
| [`modeProfiles`](#modeprofiles) | Interaction-mode profiles (tools, skills, context, runtime, model, sub-agents, hooks) |
| [`memory`](#memory) | Memory system (extraction, active memory, dreaming) |
| [`trustPolicy`](#trustpolicy) | Low-trust input gating/downgrading |
| [`conversationTransforms`](#conversationtransforms) | Compaction, slash commands, tool-result formatting, transform hooks |
| [`publishingGovernance`](#publishinggovernance) | Topic-publishing payload validation |
| [`skillWorkshop`](#skillworkshop) | Skill-proposal workshop |
| [`lineagePromptSections`](#lineagepromptsections) | Sub-agent self-awareness prompt template |
| [`subAgentCustomEndpoints`](#subagentcustomendpoints) | HTTP endpoint bindings for delegate tools |

---

## `options`

System-prompt assembly toggles (`PromptAssemblyConfiguration`).

| Key | Type | Default | Description |
|---|---|---|---|
| `includeCurrentDateTime` | Bool | `true` | Include the current date/time in the system prompt. |
| `includeAgentSkills` | Bool | `true` | Include the agent-skills section in the system prompt. |
| `systemPromptAssemblyCheckpoint` | object | — | Assembly-replay checkpoint capture. |
| `systemPromptAssemblyCheckpoint.mode` | String | `"digestOnly"` | `"off"`, `"digestOnly"`, or `"fullText"` (aliases: `"fulltext"`, `"full_text"`, `"full"`). Unrecognized values fall back to `digestOnly`. |
| `systemPromptAssemblyCheckpoint.maxFullTextBytes` | Int | library default | Full-text capture cap; floored at 1,024. |

## `settings`

Mixed bag: skills path, thinking defaults, and the three Model Pool sub-objects.

| Key | Type | Default | Description |
|---|---|---|---|
| `skillsFolderPath` | String | `nil` | Root folder for agent skills. Empty/whitespace → treated as unset. |
| `defaultThinkingConfig` | String or object | `"disabled"` | Session-default thinking. `"disabled"`, `"adaptive"`, or `{ "level": "off\|minimal\|low\|medium\|high\|xhigh", "budgetTokens": Int? }`. |
| `thinkingBudgets` | object | `{}` | Map of thinking level → token budget, e.g. `{ "high": 16000 }`. Negative values clamp to 0. Unknown level keys are ignored. |

### `settings.modelPoolProviderPreference`

| Key | Type | Default | Description |
|---|---|---|---|
| `order` | [String] | `["anthropic", "openai", "ollama", "lmstudio", "openrouter"]` | Provider preference order for pool resolution. Empty array → default. Providers not listed sort last. |

### `settings.modelPoolBudget`

Cost ceilings for hosted-model calls. Omitting the object gives the safe defaults below (budgeting **on**). Numeric values accept int, double, or numeric string.

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | Bool | `true` | Master switch for budget enforcement. |
| `maxUSDPerCall` | Double | `1.0` | Per-call ceiling. |
| `maxUSDPerConversation` | Double | `10.0` | Per-conversation ceiling. |
| `maxUSDGlobal` | Double | `100.0` | Process-lifetime ceiling. |
| `maxUSDPerAccount` | Double | `nil` | Per-account ceiling. When unset and tenancy requires authenticated owners, falls back to `maxUSDPerConversation`. |
| `denyWhenUnknownProjectedCost` | Bool | `true` | Deny calls whose projected cost cannot be computed. |

Environment overrides (applied after config): `SAH_MODEL_POOL_BUDGET_DISABLED`, `SAH_MODEL_POOL_MAX_USD_PER_CALL`, `SAH_MODEL_POOL_MAX_USD_PER_CONVERSATION`, `SAH_MODEL_POOL_MAX_USD_GLOBAL`, `SAH_MODEL_POOL_MAX_USD_PER_ACCOUNT`, `SAH_MODEL_POOL_DENY_WHEN_UNKNOWN_PROJECTED_COST`.

### `settings.modelPoolFailover`

| Key | Type | Default | Description |
|---|---|---|---|
| `maxRetries` | Int | `2` | Retry attempts on provider failure (min 0). |
| `baseDelaySeconds` | Double | `0.25` | Initial backoff delay (min 0). |
| `maxDelaySeconds` | Double | `5.0` | Backoff ceiling (min 0). |
| `jitterFraction` | Double | `0.25` | Backoff jitter, clamped 0…1. |
| `rotationStrategy` | String | `"fill_first"` | Auth-profile rotation: `"fill_first"`, `"round_robin"`, `"random"`, `"least_used"`. |
| `billingCooldownSeconds` | Double | `3600` | Cooldown after a billing failure. |
| `rateLimitCooldownSeconds` | Double | `900` | Cooldown after a rate-limit failure. |

## `agentHarness`

Agent-build loop behavior (`AgentHarnessConfiguration`). Integer keys are clamped to the listed ranges.

| Key | Type | Default | Range | Description |
|---|---|---|---|---|
| `strictAgentHarnessPrompts` | Bool | `true` | — | Stronger goal-directed wording in agent (build) mode prompts. |
| `maxTurnLoopContinuationRounds` | Int | unlimited | 1–500 | Cap on outer continuation rounds per `updateConversation`. |
| `planExcerptMaxCharacters` | Int | `6000` | 500–50,000 | `plan.md` bytes appended to continuation messages. |
| `watchdogEveryNContinuations` | Int | `0` | 0–100 | Every Nth continuation uses a watchdog nudge; `0` disables. |
| `maxConsecutiveChattyAssistantTurns` | Int | `4` | 1–50 | Stop after this many consecutive no-tool, non-trivial-text turns. |
| `repeatToolCallStreakThreshold` | Int | `5` | 2–50 | Stop when the same tool fingerprint repeats this many times. |
| `maxAgenticStepsPerUpdate` | Int | `nil` (unlimited) | 1–500 | Max LLM invocations per update; `<= 0` → unlimited. |
| `agentBuildToolInvocationPolicy` | String | `"automatic"` | — | `"automatic"`, `"required"`, or `"none"` (maps to provider `tool_choice`). |
| `rejectAssistantTurnWithNoToolCallsWhenToolsAvailable` | Bool | `false` | — | Reject and retry no-tool assistant turns when tools are available. |
| `maxCorrectionRetries` | Int | `0` | 0–20 | Correction retries for the rejection above. |
| `useAgentLoop` | Bool | `true` | — | Use `TurnLoop` (direct model stream + loop-owned tool dispatch). |
| `orchestratorPoolIdleTTLSeconds` | Int | `300` | 30–86,400 | Idle seconds before a pooled orchestrator is evictable. |
| `orchestratorPoolMaxEntries` | Int | `4` | 1–64 | Max resident orchestrator pool entries. |
| `legacyStreamedTextSurfaces` | [String] | `[]` | — | Deprecated; kept for backward compatibility, no effect. |

## `toolPolicy`

Tool-system policy. **Omitting `toolPolicy` entirely means no restriction** (all registered tools eligible, subject to mode profiles). Tool-name lists accept exact names, glob patterns (`mcp__github__*`), and group aliases.

| Key | Type | Default | Description |
|---|---|---|---|
| `sensitive` | [String] | `[]` | Tools flagged sensitive (diagnostic classification). |
| `requireApproval` (alias `approvalRequired`) | [String] | `[]` | Tools requiring explicit approval before dispatch. |
| `escalationRequired` | [String] | `[]` | Tools blocked unless the invocation is elevated. |
| `elevated` | [String] **or** object | `[]` | Shorthand array = statically elevated tools. Object form below. |
| `elevated.tools` | [String] | `[]` | Statically elevated tools. |
| `elevated.perCall` | [String] | `[]` | Elevated per-call (not statically gated; each call is judged). |
| `elevated.allowFrom` | object | `{ "cli": ["*"] }` | Map of surface → allowed requester IDs for elevation. An empty map falls back to the CLI default at evaluation time. |
| `elevatedExecutionPolicy` | String | `"privilegedDispatch"` | Only recognized value today. |
| `descriptorValidationMode` | String | `"warning"` | `"warning"` or `"strict"` tool-descriptor validation. |

### `toolPolicy.approval`

| Key | Type | Default | Description |
|---|---|---|---|
| `timeoutMs` | Int | `120000` | Approval wait timeout. Floored at 1,000. `0` or negative **disables** the timeout (waits indefinitely). |
| `timeoutBehavior` | String | `"autoDeny"` | `"autoDeny"` or `"autoApprove"` when a finite timeout elapses. |
| `severityDefault` | String | `"medium"` | Default severity label on approval requests. |
| `elevatedSeverityDefault` | String | `"high"` | Severity label for elevated approvals. |

### `toolPolicy.executionEnvironment`

Environment-kind values: `"local"`, `"docker"`, `"ssh"`, `"mcp"`, `"a2a"`, `"unknown"`.

| Key | Type | Default | Description |
|---|---|---|---|
| `disallow` | [String] | `[]` | Environment kinds whose tools are blocked. |
| `requireApproval` | [String] | `[]` | Kinds whose tools require approval. |
| `requireEscalation` | [String] | `[]` | Kinds whose tools require elevation. |
| `disallowAdapters` | [String] | `[]` | Same, keyed by adapter ID. |
| `requireApprovalAdapters` | [String] | `[]` | — |
| `requireEscalationAdapters` | [String] | `[]` | — |

### `toolPolicy.dispatch`

| Key | Type | Default | Description |
|---|---|---|---|
| `parallelEnabled` | Bool | `false` | Enable parallel tool dispatch. |
| `plannerMode` | String | `nil` | `"serial"`, `"mixedDeterministic"`, or legacy `"allParallel"` (parsed but remapped to `mixedDeterministic` with a warning). |
| `pendingToolTimeoutSeconds` | Double | `nil` (none) | Timeout for pending tool calls; `<= 0` → none. |

## `subAgentHostingPolicy`

Hosting/routing policy for delegate (sub-agent) tools.

| Key | Type | Default | Description |
|---|---|---|---|
| `defaults` | object | empty policy | Fallback policy for delegate tools without an entry. |
| `entries` | object | `{}` | Map of delegate tool name → policy object. |

Each policy object:

| Key | Type | Default | Description |
|---|---|---|---|
| `hostPersonaID` | String | `nil` | Persona identity the delegate runs as (also indexes the policy by persona). |
| `delegationAllowlist` | [String] | `[]` | Delegate tools this host may itself invoke. |
| `authScopeTags` | [String] | `[]` | Auth scopes granted to the delegate (e.g. `"repo:write"`). |
| `routingDomain` | String | `nil` | Routing domain label. |
| `tenantScope` | String | `nil` | Tenant scope label. |

## `modeProfiles`

Interaction-mode profiles. Accepts an **array** of profile objects, a single object, or `{ "profiles": [...] }`. Built-in profiles (`chat`, `plan`, `agent`, plus least-privilege machine profiles `subagent-minimal`, `memory-active-recall`, `memory-extraction`, `memory-pre-compaction-flush`, `trigger-delegate`) are always seeded first; config rows **overlay** them by `id` or extend them via `extends`.

### Profile row

| Key | Type | Required | Description |
|---|---|---|---|
| `id` | String | **yes** | Unique profile ID. Duplicate IDs are rejected with a diagnostic. |
| `extends` | String | no | Parent profile ID; the row overlays the parent's resolved slices. Cycles and unknown parents are rejected. |
| `interactionMode` | String | yes, unless `extends` or overlaying an existing id | `"chat"`, `"plan"`, or `"agent"`. |
| `assemblyKind` | String | same as above | `"chat"`, `"planCollaboration"`, or `"agentBuild"`. Must pair with the mode: chat↔chat, plan↔planCollaboration, agent↔agentBuild. |
| `allowsProactiveCompactionTriggers` | Bool | no | Inherited; built-ins: `false` for chat, `true` for plan/agent. |
| `appliesAgentBuildOrchestratorHarness` | Bool | no | Inherited; built-ins: `true` only for agent. |
| `allowsHostGrants` | Bool | no | Whether registration-time tool visibility grants (MCP servers etc.) can widen this profile. **Default derived**: `false` when the final merged `tools.allow` is an explicit `[]` (authored lockdown), otherwise `true`. Explicit value on the row wins over derivation and over inherited values; **always forced `false` for machine profiles** (a `true` here is ignored with a diagnostic). Operator project-directory overlays cannot set this field (stripped with a diagnostic). |
| `semanticLayerTags` | [String] | no | Forward-compat layered-mode tags. Default `[]`. |
| `label`, `description`, `symbol` | String | no | Picker/UI metadata. `label` defaults to the id. |

### `tools` slice

| Key | Type | Description |
|---|---|---|
| `allow` | [String] | **Replaces** the inherited allow list. `null`/omitted = inherit. `["*"]` = all tools. `[]` = none — an *authored lockdown* that also suppresses host visibility grants (see `allowsHostGrants`). Entries accept globs and group aliases. |
| `allow+` | [String] | **Appends** to the (possibly just-replaced) allow list. No-op when the effective list is open (`null` or contains `"*"`) — it never closes an open world. With `allow` on the same row, semantics are replace-then-append. |
| `deny` | [String] | Appends to the inherited deny list (append-only; a child can never remove a parent's denies). Deny always beats allow *and* host grants. |
| `deny+` | [String] | Alias of `deny` (also append-only). |
| `approvalPolicy` | String | `"never"`, `"side-effects"`, or `"all"` — mode-level approval posture. |

### `skills` slice

| Key | Type | Description |
|---|---|---|
| `allow` / `allow+` / `deny` / `deny+` | [String] | Same replace-then-append / append-only semantics as `tools`, applied to skill names. |

### `context` slice

| Key | Type | Description |
|---|---|---|
| `compactionLevel` | String | Compaction aggressiveness label for this mode. |
| `modeDirective` | String | Mode-specific directive text injected into the system prompt. |
| `sectionOverrides` | object | Map of prompt section name → replacement text (merged onto parent's overrides). |
| `suppressSections` | [String] | Prompt sections to omit (appended to parent's list). |
| `memoryInjection` | String | Memory-injection mode label. |
| `includeSkills` | Bool | Include the skills prompt section. |
| `includeToolGuidance` | Bool | Include the tool-guidance prompt section. |
| `omitWorkspaceConventions` | Bool | Omit workspace-conventions prompt section. |

### `runtime` slice

| Key | Type | Description |
|---|---|---|
| `maxIterations` | Int | Per-turn loop iteration cap (min 1; non-numeric value clears an inherited cap). Built-ins: plan = 8, chat/agent = uncapped. |
| `stopOnApprovalRequest` | Bool | Pause the loop when a tool requests approval. Built-ins: `true` for plan. |
| `termination.policy` | String | `"bare-message"` (turn ends on plain assistant text; built-in chat) or `"terminal-tool"` (turn ends only via a terminal tool; built-in plan/agent). |
| `termination.recovery.strategy` | String | `"forced-tool-choice"` or `"behavioral-fallback"`. |
| `termination.recovery.rollbackStalledTurn` | Bool | Roll back the stalled turn before retrying. |
| `termination.recovery.maxAttempts` | Int | Recovery attempts (min 1). |
| `termination.recovery.behavioralInjectAfterStalls` | Int | Inject behavioral nudge after N stalls (min 1). |
| `termination.recovery.behavioralRecoveryTemperature` | Double | Temperature for behavioral recovery calls. |
| `termination.recovery.reminder` | String | `"off"` or `"escalating"`. |

When `policy` is `"terminal-tool"` and no recovery is configured, a default recovery is applied (forced-tool-choice, rollback, 2 attempts, escalating reminders).

### `model` slice

| Key | Type | Description |
|---|---|---|
| `query` | String | Model Pool query for this mode (e.g. capability tags). |
| `fallback` | String | Fallback model reference. |
| `thinkingConfig` | String or object | `"disabled"`, `"adaptive"`, or `{ "level": ..., "budgetTokens": ... }`. Built-ins: chat = disabled, plan = high, agent = adaptive. |

### `subAgents` slice

| Key | Type | Description |
|---|---|---|
| `allow` | [String] or `"*"` | Sub-agent (delegate) allow list. `[]` = none. |
| `maxDepth` | Int | Max spawn depth (min 0). |
| `childModeOnSpawn` | String | Mode profile ID assigned to spawned children. |

### `hooks` slice

| Key | Type | Description |
|---|---|---|
| `onEnter` / `onExit` | [String] | Transition hook IDs. Built-ins: exit `invalidate_orchestrator`, enter `restore_skill_loader`. |

### Merge semantics summary

1. Built-ins seed the registry; config rows merge over them in topological `extends` order.
2. Slices merge key-by-key: an omitted slice or key inherits the parent value.
3. `allow` replaces; `allow+` appends (open-world no-op); `deny`/`deny+` only ever append.
4. `allowsHostGrants` resolves after the tools slice is final: machine pin → explicit on row → derived `false` from empty allow → inherited explicit → `true`.
5. An operator project config directory (per-workspace `*.json` mode profile files) merges last, with security-sensitive fields (`allowsHostGrants`, among others) stripped.

## `memory`

Memory system configuration. Integer clamps in parentheses.

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | Bool | `true` | Master switch for the memory system. |
| `managedInstructionsPath` | String | `nil` | Managed instructions file path. |
| `extractionEnabled` | Bool | `true` | Background memory extraction. |
| `extractionThrottleTurns` | Int | `1` (min 1) | Turns between extraction runs. |
| `extractionRecentMessageCount` | Int | `20` (min 1) | Recent messages given to extraction. |
| `activeMemoryEnabled` | Bool | `true` | Active-memory recall at turn start. |
| `activeMemoryTimeoutMs` | Int | `2500` (min 1) | Recall time budget (also legacy fallback for the situational lane). |
| `activeMemoryMaxSummaryChars` | Int | `220` (40–1,000) | Per-recall summary cap. |
| `activeMemoryModelRef` | String | `nil` | Model Pool pin (slug/UUID) for recall. Legacy alias: `activeMemoryModel`. |
| `activeMemoryOllamaServerURL` | String (URL) | `http://127.0.0.1:11434` | Legacy Ollama endpoint for the recall selector. |
| `activeMemoryAllowCrossProviderTrust` | Bool | `false` | Allow pool candidates above the session's provider trust tier. |
| `activeMemoryStandingEnabled` | Bool | `true` | Standing (long-TTL) recall lane. |
| `activeMemoryStandingTTLMs` | Int | `3600000` (min 1) | Standing lane TTL. |
| `activeMemoryStandingBudgetMs` | Int | `15000` (min 1) | Standing lane time budget. |
| `activeMemorySituationalEnabled` | Bool | `true` | Situational (per-turn) recall lane. |
| `activeMemorySituationalTimeoutMs` | Int | falls back to `activeMemoryTimeoutMs` | Situational lane timeout. |
| `activeMemorySituationalTTLMs` | Int | `60000` (min 1) | Situational lane TTL. |
| `activeMemoryQueryMode` | String | `"recent"` | `"message"`, `"recent"`, or `"full"` conversation window for recall queries. |
| `activeMemoryPromptStyle` | String | `"balanced"` | `"balanced"`, `"strict"`, `"contextual"`, `"recall-heavy"`, `"precision-heavy"`, `"preference-only"`. |
| `activeMemoryRecentUserTurns` | Int | `2` (0–4) | User turns in the recall window. |
| `activeMemoryRecentAssistantTurns` | Int | `1` (0–3) | Assistant turns in the recall window. |
| `activeMemoryRecentUserChars` | Int | `220` (40–1,000) | Per-user-turn char cap. |
| `activeMemoryRecentAssistantChars` | Int | `180` (40–1,000) | Per-assistant-turn char cap. |
| `activeMemoryLogging` | Bool | `true` | Structured `active-memory: start\|done` debug logs. |
| `activeMemoryRecallCacheMaxEntries` | Int | `1000` (1–100,000) | Per-conversation recall cache LRU bound (cannot be disabled). |
| `teamMemoryEnabled` | Bool | `true` | Team-scoped memory. |
| `preCompactionFlushEnabled` | Bool | `true` | Memory flush pass before compaction. |
| `preCompactionFlushTimeoutMs` | Int | `30000` (min 1) | Flush time budget. |
| `preCompactionFlushMaxIterations` | Int | `2` (min 1) | Flush sub-agent iteration cap. |
| `preCompactionFlushSystemPromptPath` | String | `nil` | Custom flush system prompt file. |
| `dreamingEnabled` | Bool | `false` | Deploy-time opt-in for autonomous dreaming sweeps. |
| `dreamingCron` | String | `"0 3 * * *"` | Dreaming schedule (cron). |
| `dreamingMinScore` | Double | `0.75` | Min score for promotion. |
| `dreamingMinRecallCount` | Int | `2` (min 1) | Min recalls for promotion. |
| `dreamingMinUniqueQueries` | Int | `2` (min 1) | Min unique queries for promotion. |
| `recallSelectorModel` | String | `"llama3.2:3b"` | Recall-selector model name. |
| `recallSelectorOllamaServerURL` | String (URL) | `http://127.0.0.1:11434` | Recall-selector endpoint. |
| `recallSelectorHeuristicMinScore` | Int | `4` (min 1) | Heuristic pre-filter threshold. |

## `trustPolicy`

Low-trust input handling. Omitted → disabled.

| Key | Type | Default | Description |
|---|---|---|---|
| `mode` | String | `"none"` | `"none"`, `"gateExecution"`, `"downgradeContext"`, `"gateAndDowngrade"`. Unknown values → `none` with a warning. |
| `safeDefaultClass` | String | `"low_trust"` | Trust class assumed for unclassified input: `"trusted"` or `"low_trust"`. |

## `conversationTransforms`

Transform hooks, compaction, slash commands, and tool-result formatting.

### Hook toggles

Top-level booleans set the baseline for all modes; per-mode objects (`chat`, `plan`, `agent`) override it.

| Key | Type | Default | Description |
|---|---|---|---|
| `enableContextTransform` | Bool | `true` | Context (compaction) transform hook. |
| `enableToolResultTransform` | Bool | `true` | Tool-result transform hook. |
| `enableTurnSummaryTransform` | Bool | `true` | Turn-summary transform hook. |
| `chat` / `plan` / `agent` | object | baseline | Per-mode overrides of the three keys above. |
| `transformTimeoutSeconds` | Double | `1800` (1–3,600) | Timeout for a transform pass. |

### `conversationTransforms.contextCompaction`

Context-window compaction. Clamps in parentheses.

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | Bool | `true` | Master switch. |
| `model` | String | `"gemma4:e4b"` | Compaction summarizer model. |
| `ollamaServerURL` | String (URL) | `http://localhost:11434` | Summarizer endpoint. |
| `optionalCompactionProviderSlot` | String | `nil` | Provider slot id (e.g. `"ollama"`, `"none"`); `nil` = default provider. |
| `optionalCompactionProviderFallbackToOllama` | Bool | `true` | Fall back to the Ollama chain on provider errors. |
| `fallbackContextLimitTokens` | Int | `131072` (1,024–8,388,608) | Context limit when the model's is unknown. |
| `compactionSummarizerContextLimitTokens` | Int | `131072` (1,024–8,388,608) | Summarizer LLM context size (floors the trigger threshold). |
| `charactersPerToken` | Double | `4` (1–32) | Token-estimation heuristic. |
| `proactiveSafetyBufferTokens` | Int | `13000` (0–8,388,608) | Headroom kept below the effective window before triggering. |
| `proactiveOutputReserveTokens` | Int | `20000` (0–8,388,608) | Tokens reserved for model output. |
| `softThresholdTokens` | Int | `8000` (0–min(100k, 2×safetyBuffer)) | Headroom for a flush-only soft pass; `0` disables. |
| `reactiveTriggerEnabled` | Bool | `true` | Context-window-exceeded errors force an in-turn compaction retry. |
| `reactiveErrorPatterns` | [String] | 6 built-in patterns | Case-insensitive substrings identifying context-window errors. |
| `maxCompactedMiddleMessages` | Int | `15` (3–200) | Cap on synthesized middle messages sent to the summarizer. |
| `middleMinCharactersForCompactionLLM` | Int | `0` (0–2,000,000) | Skip the LLM when the middle segment is smaller than this. |
| `compactionLLMCooldownSeconds` | Double | `0` (0–86,400) | Min seconds between compaction LLM calls per conversation. |
| `headMinMessageCount` | Int | `3` | Messages preserved at the head. |
| `tailMinMessageCount` | Int | `6` | Messages preserved at the tail. |
| `tailTokenBudgetFraction` | Double | `0.2` | Fraction of budget reserved for the tail. |
| `compactionToolResultPruneNames` | [String] | `[]` | Tool names whose results are cleared in the summarizer payload. |
| `maxRecentToolResults` | Int | `5` (0–1,000,000) | Recency cap for unlisted tool results. Alias: `max_recent_tool_results`. |
| `maxRecentPerNameToolResults` | Int | `5` (0–1,000,000) | Per-name recency cap for listed tools. Alias: `max_recent_per_name_tool_results`. |
| `toolResultPruneReplacementMode` | String | `"one_line_summary"` | `"blank"` (aliases `blankmarker`, `blank_marker`) or `"one_line_summary"` (alias `onelinesummary`). Alias key: `tool_result_prune_replacement_mode`. |
| `compactionSummaryBudgetTokens` | Int | `2000` (1–1,000,000) | Target `<summary>` size hint. |
| `compactionSummaryBudgetProportionalEnabled` | Bool | `true` | Proportional summary budgeting (12k ceiling). |
| `compactionSummarizerMaxOutputTokens` | Int | `20000` (min 1) | Summarizer `max_tokens`; effective value floors at the 20k reserve. |
| `compactionCustomInstructionsBlock` | String | `""` | Extra instructions appended to the compaction prompt. |
| `compactionIdentifierPreservationMode` | String | `"strict"` | `"strict"`, `"custom"`, or `"off"`. |
| `compactionIdentifierPreservationCustomInstructions` | String | `""` | Custom instructions when mode is `custom`. |
| `oversizeRetryMaxAttempts` | Int | `3` (1–20) | Summarizer oversize-retry attempts (includes the first). |
| `oversizeRetryDropFraction` | Double | `0.2` (0–0.95) | Oldest-groups fraction dropped per retry. |
| `oversizeRetryMarker` | String | `"[earlier conversation truncated for compaction retry]"` | Marker prepended on each shrink. |
| `manualToolEnabled` | Bool | `true` | Register the model-callable `compact_conversation` tool. |
| `manualToolMinUtilization` | Double | `0.5` (0–1) | Min utilization fraction before the tool may compact. |
| `manualSlashEnabled` | Bool | `true` | Intercept `/compact`. |
| `manualRESTEnabled` | Bool | `true` | Register `POST /api/conversations/:id/compact`. |
| `defaultSummarizationStrategy` | String | `"default"` | Optional strategy (`turn_prefix`, `branch_aware`, …). |
| `focusedCompactionQuery` | String | `""` | Persistent focus query; empty = none. |
| `cacheAwarePruningEnabled` | Bool | `false` | Deterministic cache-aware pruning before summarization. |
| `cacheStablePrefixMessageCount` | Int | `4` (0–200) | Leading messages kept for cache-prefix reuse. |
| `cachePruningTTLSeconds` | Double | `nil` (0–2,592,000) | TTL for middle messages; `null`/`<= 0` disables. |
| `contextPruningMode` | String | `nil` | `"off"` or `"cacheTTL"`; unset derives from `cacheAwarePruningEnabled`. |
| `contextPruningKeepRecentToolResults` | Int | `5` (0–200) | Recent tool results kept by TTL pruning. Alias: snake_case. |
| `contextPruningTargetTools` | [String] | `nil` (all) | Tool-name filter for TTL pruning. Alias: snake_case. |
| `cacheExpiryInferenceThresholdSeconds` | Double | `nil` (→ 9,000s) | Idle gap before inferring a dead prompt cache. |
| `deterministicToolResultPruningEnabled` | Bool | `true` | Deterministic tool-result pruning stage. |
| `deterministicAttachmentDocumentHygieneEnabled` | Bool | `false` | Attachment/image/document hygiene stage. |
| `deterministicMaxImagesPerMessage` | Int | `3` (0–20) | Per-message image cap under hygiene. |
| `deterministicDocumentCharacterThreshold` | Int | `12000` (0–2,000,000) | Document-like payload threshold. |
| `deterministicDocumentPlaceholder` | String | `"[Document content cleared for context compaction]"` | — |
| `deterministicDocumentPreviewMaxBytes` | Int | `2048` (0–1,000,000) | Preview bytes in hygiene receipts. |
| `deterministicImagePlaceholder` | String | `"[Image attachment omitted for context compaction]"` | — |
| `preCompactionMemoryFlushEnabled` | Bool | `true` | Memory flush stage before summarization. |
| `preCompactionMemoryFlushMaxEntries` | Int | `64` (1–500) | Entries per flush snapshot. |
| `sessionMemorySwapBeforeCompactionEnabled` | Bool | `true` | Session-memory swap before compaction. |
| `compactionReinjectionEnabled` | Bool | `true` | Post-compaction re-injection of recent files/skills. |
| `reinjectionRecentFileCount` | Int | `5` | Recent files considered. (snake_case aliases accepted for all re-injection keys.) |
| `reinjectionPerFileTokenBudget` | Int | `5000` | Per-file token budget. |
| `reinjectionTotalFileTokenBudget` | Int | `50000` | Total file token budget. |
| `reinjectionPerSkillTokenBudget` | Int | `5000` | Per-skill token budget. |
| `reinjectionTotalSkillTokenBudget` | Int | `25000` | Total skill token budget. |
| `reinjectFileContentEnabled` | Bool | `true` | Re-inject truncated file content (false = path-only list). |
| `reinjectionInstructionSectionsEnabled` | Bool | `true` | Re-inject named instruction-file sections. |
| `reinjectionInstructionSectionNames` | [String] | `["Session Startup", "Red Lines"]` | H2/H3 section names to extract. |
| `reinjectionInstructionSectionMaxCharacters` | Int | `3000` | Total char budget for re-injected sections. |
| `compactionCircuitBreakerMaxFailures` | Int | `3` | Consecutive failures before the circuit opens. |
| `compactionMinPromptTokenSavingsFraction` | Double | `0.03` | Min fractional savings to persist a checkpoint; `0` disables. |
| `useSessionTreeProjection` | Bool | `true` | Use session-tree projection for compaction. |

### `conversationTransforms.slashCommands`

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | Bool | `true` | Global slash processing; `false` treats all `/...` input as plain text. |
| `allowUnknownPassthrough` | Bool | `true` | Unknown commands pass through to the model as text. |
| `compactEnabled` | Bool | `true` | `/compact` handling. |
| `skillSlashEnabled` | Bool | `true` | `/skill:…` invocations. |
| `directivesEnabled` | Bool | `true` | Turn-tuning directives (`/think`, `/model`, …). |
| `inlineShortcutsEnabled` | Bool | `true` | Inline shortcuts (`/help` + prose). |
| `ownerOnlyDirectiveNames` | [String] | `["model"]` | Directives requiring owner authorization (lowercased, no `/`). |
| `staticSkillNamesExcludedFromSkillColon` | [String] | `[]` | Skill names excluded from `/skill:` autocomplete. |
| `toolDispatchCommands` | [object] | `[]` | Static slash rows dispatching to named tools (below). |

Each `toolDispatchCommands` row: `command` (String, **required**), `toolName` (String, **required**), `argMode` (`"raw"` default, or `"parsed"`), `description` (default generated), `argumentHint` (String, optional), `hiddenKeywords` (String, default `""`), `aliases` ([String], default `[]`), `ownerOnly` (Bool, default `false`), `bypassTier` (`"always"`, `"connecting"`, `"immediateUI"`, `"sideEffectFree"`, `"queued"` — default `"queued"`), `enabled` (Bool, default `true`).

### `conversationTransforms.toolResultFormatting`

Size caps clamp to 0–2,000,000 (characters) or 0–8,000,000 (bytes) unless noted.

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | Bool | `true` | Master switch. |
| `spillEnabled` | Bool | on when on-disk v2 persistence is configured | Spill oversized results to disk with a preview. |
| `spillPreviewMaxBytes` | Int | `2048` | Preview size for spilled results. |
| `defaultMaxResultSizeBeforeSpill` | Int | `480000` | Spill threshold. |
| `runtimeMaxCharacters` | Int | `120000` | Char cap in the live model context. |
| `persistenceMaxCharacters` | Int | `300000` | Char cap for stored results. |
| `compactionMaxCharacters` | Int | `40000` | Char cap in compaction payloads. |
| `runtimeMaxBytes` / `persistenceMaxBytes` / `compactionMaxBytes` | Int | `480000` / `1200000` / `160000` | Byte caps per stage. |
| `runtimeMetadataMaxBytes` / `persistenceMetadataMaxBytes` / `compactionMetadataMaxBytes` | Int | `96000` / `256000` / `64000` | Metadata byte caps per stage. |
| `maxLines` | Int | `800` (0–20,000) | Line cap. |
| `sanitizeInlineImagePayloads` | Bool | `true` | Strip/limit inline image payloads. |
| `maxInlineImagePixelDimension` | Int | `1200` (0–16,384) | Max image dimension. |
| `maxInlineImageBytes` | Int | `5000000` (0–32,000,000) | Max image bytes. |
| `imagePayloadPlaceholder` | String | `"[inline image payload omitted]"` | — |
| `compactionImagePayloadPlaceholder` | String | `"[old image payload replaced for compaction]"` | — |
| `metadataPlaceholder` | String | `"[tool metadata omitted]"` | — |
| `compactionMetadataPlaceholder` | String | `"[old tool metadata replaced for compaction]"` | — |
| `truncationMarker` | String | `"[tool result truncated]"` | — |
| `compactionTruncationMarker` | String | `"[old tool payload replaced for compaction]"` | Constant marker (prompt-cache stability). |

## `publishingGovernance`

| Key | Type | Default | Description |
|---|---|---|---|
| `mode` | String | `"strict"` | `"strict"` rejects invalid topic payloads; `"soft"` logs only. Unknown → strict with a warning. |
| `diagnosticsEnabled` | Bool | `false` | Extra publishing diagnostics. |

## `skillWorkshop`

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | Bool | `false` | Skill-proposal workshop. |
| `maxProposalsPerWorkspace` | Int | `50` (1–500) | Proposal cap per workspace. |

## `lineagePromptSections`

| Key | Type | Default | Description |
|---|---|---|---|
| `subAgent` | String | built-in template | Sub-agent self-awareness prompt. Placeholders: `{{subAgentDepth}}`, `{{subAgentRootConversationID}}`, `{{subAgentConversationID}}`, `{{subAgentParentConversationID}}`. Empty/whitespace → default. |

## `subAgentCustomEndpoints`

Map of delegate tool name → HTTP endpoint binding. Entries with an invalid `url` are skipped with a warning.

| Key | Type | Required | Default | Description |
|---|---|---|---|---|
| `url` | String (URL) | **yes** | — | Endpoint URL. |
| `method` | String | no | `"POST"` | HTTP method (uppercased). |
| `authHeaderName` | String | no | `nil` | Auth header name. |
| `authHeaderValue` | String | no | `nil` | Auth header value. Alternative: `authHeaderValueEnv` names an environment variable to read the value from. |
| `timeoutSeconds` | Number | no | `120` | Request timeout. |

---

## Interaction with host-registered tools (MCP)

Mode `tools.allow` lists are closed-world: a profile that enumerates tools will not see newly registered ones. Two mechanisms avoid hand-editing every profile when adding an MCP server:

- **Glob entries** in `allow`/`allow+`, e.g. `"mcp__github__*"`.
- **Registration-time visibility grants**: `setMCPManager(_:visibilityGrant:)` defaults to `.grant(modes: .allUserFacing)`, making the server's tools visible in every profile with `allowsHostGrants == true` — no config edits. Mode `deny` still wins; machine profiles never receive grants; a profile with `tools.allow: []` is an authored lockdown that suppresses grants unless it sets `allowsHostGrants: true` explicitly. Host tool providers default to `.inheritModeLists` (config lists govern).

## Minimal example

```json
{
  "options": { "includeCurrentDateTime": true },
  "toolPolicy": {
    "requireApproval": ["bash"],
    "elevated": { "perCall": ["bash"] }
  },
  "modeProfiles": [
    {
      "id": "agent",
      "tools": { "allow+": ["mcp__github__*"] }
    }
  ],
  "memory": { "dreamingEnabled": false }
}
```

This overlays the built-in `agent` profile (keeping its open `"*"` allow — the `allow+` is a no-op there, shown for shape), requires approval for `bash`, and elevates it per-call.
