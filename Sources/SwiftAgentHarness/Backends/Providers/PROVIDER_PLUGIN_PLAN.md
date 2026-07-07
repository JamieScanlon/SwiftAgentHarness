# Provider Plugins — Execution Plan

Status: proposed · Scope: `SwiftAgentHarness` library + new `SwiftAgentHarnessProviders` target · Companion spec: `harness-template/backends/providers/README.md` (Provider lifecycle + Packaging sections)

---

## 0. Goal and framing

Today every provider is **bundled into core** and wired by a hardcoded
`ProviderRegistry.bootstrapBuiltInsIfNeeded()` that names concrete types
(`OpenAITextInferenceProvider`, `AnthropicTextInferenceProvider`, …) and stub
slot fillers. Core therefore *depends on* its providers, manifests live twice
(Swift literals in `ProviderManifests` **and** JSON in `manifests/*.json`), and
the catalog/manifest JSON is shipped as resources of the core target.

This plan turns providers into **plugins** in the only two senses that make
sense for a Swift library that ships inside someone else's notarized/sandboxed
app:

1. **Code plugins** — a provider is a value (`ProviderRegistration`) built from
   a concrete `TextInferenceProviding` (plus optional slot fillers) and a
   manifest. Code plugins are *compiled into the host app*: either the
   foundational set this library ships, or third-party providers an app
   developer writes / vendors as source. There is **no runtime native-code
   loading** (no `dlopen`, no dynamic bundles) — that path is closed on
   iOS/visionOS and fragile under macOS sandbox + notarization.

2. **Configuration plugins** — a *data file* (JSON manifest + instance config)
   that parameterizes a **generic** code plugin the host already ships. The
   canonical example: ship a generic OpenAI-compatible provider, then let an end
   user drop in a config that points it at `llama.cpp`, LM Studio, vLLM, a
   corporate proxy, Together/Groq, etc. The config carries endpoint, auth
   choices, model prefixes, and an optional catalog; it carries **no code**.

The boundary this library draws: **extensibility at compile time, plus a solid
foundational plugin set + a generic configurable provider.** Anything an end
user adds at runtime is *configuration over generic code*, never new code.

### Two "registrations" that must stay distinct

The word "register" is overloaded today. The plan separates them explicitly,
because conflating them is the root of most of the churn below.

| Term | Meaning | Trigger | State it produces |
|---|---|---|---|
| **Plugin registration** (code-level) | A `ProviderRegistration` enters `ProviderRegistry` | App startup calls `registerDefaults(into:)` / a config-plugin loader instantiates a generic provider | provider is **available** |
| **Provider registration** (user-level, the handover's "opt-in") | User activates a provider by creating ≥1 active `AuthProfile` | User adds an API key / OAuth, or confirms a local base-URL profile | provider is **registered** (participates in the Pool) |

A provider that is *available* but has no active `AuthProfile` contributes
**nothing** to the Model Pool — no catalog discovery, no registry entries, no
`ProviderBinding` candidates. This is the handover's core rule and it is the one
behavioral change with the widest blast radius (see Phase 5).

---

## 1. Current-state map (what couples core to providers)

Grounded in the present tree under `Sources/SwiftAgentHarness/Backends/Providers/`
and `Core/ModelPool/`:

| Coupling point | File | Problem |
|---|---|---|
| Hardcoded built-in list | `ProviderRegistry.bootstrapBuiltInsIfNeeded()` | Core references concrete provider + stub types by name |
| Manifest literals | `ProviderManifest.swift` → `enum ProviderManifests` | Enumerates the 5 providers inside core; referenced from `ModelManager.lazyResolveSlug` |
| Lazy self-bootstrap | `ModelManager` (×2), `StandardModelLLMFactory`, `ProviderRuntimeHooks` (×7) call `bootstrapBuiltInsIfNeeded()` | Core assumes it can conjure providers on demand |
| No lifecycle gate | `ModelManager.syncRegistryFromDiscovery()` iterates `allTextInferenceProviders()` unconditionally | Every available provider discovers models regardless of opt-in |
| Concrete providers in core | `TextInference/TextInferenceProviders.swift` | The 5 wire codecs live in the core target |
| Stub slot fillers in core | `Slots/ProviderCapabilitySlotProtocols.swift` (`StubSpeechProvider`, …) | Demo/stub code in core |
| Bundled resources | `Package.swift` `resources:` → `Providers/manifests`, `Providers/catalogs` | Manifest + catalog JSON ship in the *core* bundle |
| Dual manifest source | `manifests/*.json` **and** `ProviderManifests.*` | Two sources of truth that can drift |

What is **already in good shape** and should be *kept as the contract* (it
moves, but does not get rewritten):

- `TextInferenceProviding` (the runtime contract) and the per-slot `…Providing`
  protocols in `Slots/`.
- `ProviderRegistration` (the capability-typed record) and `ProviderRegistry`'s
  index/lookup API.
- `ProviderManifest` + `ProviderManifestValidation` (static validation) +
  `ProviderManifestLoader` (JSON decode).
- `AuthProfile` + `AuthProfileStore` + `AuthProfileSelector` + cooldown.
- `ProviderCapabilitySlot`, catalog types, `ProviderRuntimeHooks`.

These types are the **plugin SDK** for this library. Because the chosen target
shape is "one providers target" (not a separate SDK target), the SDK simply
*is* the public surface of the core `SwiftAgentHarness` module.

---

## 2. Target architecture (end state)

```
SwiftAgentHarness            (library, provider-AGNOSTIC)
├─ Backends/Providers/       contracts + machinery only:
│   TextInferenceProviding, slot protocols, ProviderRegistration,
│   ProviderRegistry, ProviderManifest(+Validation+Loader),
│   AuthProfile*, ProviderCapabilitySlot, catalog types,
│   ProviderRuntimeHooks, ProviderLifecycle (NEW),
│   ProviderAdapterFactory (NEW), ConfigPluginLoader (NEW)
└─ (no concrete providers, no manifest/catalog resources,
    no ProviderManifests literals)

SwiftAgentHarnessProviders   (NEW target, depends on SwiftAgentHarness
│                             + OllamaKit + SwiftAgentKit codecs)
├─ OpenAITextInferenceProvider, AnthropicTextInferenceProvider,
│   OllamaTextInferenceProvider, LMStudioTextInferenceProvider,
│   OpenRouterTextInferenceProvider
├─ GenericOpenAICompatProvider (NEW — the configurable default)
├─ Stub*Provider slot fillers (moved out of core)
├─ manifests/*.json, catalogs/*.json (+ overrides)  ← RESOURCES MOVE HERE
├─ ProviderManifests (the literal index, if kept — see Phase 6)
├─ DefaultProviderAdapterFactories (registers factory closures into core)
└─ public func registerDefaults(into: ProviderRegistry, options:)  ← entry point
```

Dependency direction inverts: **providers → core**, never core → providers. The
app links `SwiftAgentHarnessProviders` and calls `registerDefaults` once at
startup. An app that wants a leaner binary can link core + only the providers it
hand-registers.

### Why a factory seam (`ProviderAdapterFactory`)

The configuration-plugin path needs to turn *data* into a running provider, but
core must not know about `GenericOpenAICompatProvider`. Resolve this with a tiny
indirection that lives in core and is populated by the providers target:

```swift
// CORE
public protocol ProviderAdapterFactory: Sendable {
    /// Stable id a config file references, e.g. "openai-compat", "anthropic".
    var adapterKind: String { get }
    /// Build a registration from a (possibly user-supplied) manifest + config.
    func makeRegistration(manifest: ProviderManifest,
                          config: ProviderInstanceConfig) throws -> ProviderRegistration
}

public enum ProviderAdapterFactoryRegistry {
    public static func register(_ factory: any ProviderAdapterFactory)
    public static func factory(for adapterKind: String) -> (any ProviderAdapterFactory)?
}
```

The providers target registers a factory for each `adapterKind` it ships
(`openai-compat`, `anthropic`, `ollama`, `lmstudio`, `openrouter`). A config
file says `"adapterKind": "openai-compat"`; the core `ConfigPluginLoader` looks
up the factory and builds a `ProviderRegistration` with a fresh provider id
(`llamacpp-local`, `corp-proxy`, …) bound to the generic codec. This is the
whole "remote/config plugin" mechanism — no code crosses the boundary, only the
`adapterKind` string and the manifest data.

---

## 3. Phased plan

Phases are ordered so the tree compiles after each one (no long red-build
window). Phases 1–3 are pure refactor/mechanics; 4–6 add capability; 7–8 are
migration + docs.

### Phase 1 — Carve the contract, invert the dependency

**Objective:** core stops naming concrete providers; bootstrap becomes an
injected closure, not a hardcoded list.

1. Replace `ProviderRegistry.bootstrapBuiltInsIfNeeded()`'s hardcoded body with
   an **installable bootstrap hook**:
   ```swift
   public enum ProviderRegistry {
       private nonisolated(unsafe) static var bootstrapHook: (@Sendable () -> Void)?
       public static func installBootstrap(_ hook: @escaping @Sendable () -> Void)
       public static func ensureBootstrapped()   // runs hook once; no-op if none
   }
   ```
   Rename the 10 call sites (`ModelManager` ×2, `StandardModelLLMFactory` ×1,
   `ProviderRuntimeHooks` ×7) from `bootstrapBuiltInsIfNeeded()` →
   `ensureBootstrapped()`. Behavior with no hook installed: registry is empty →
   Pool sees no providers (correct for the new opt-in world).
2. Add a **deprecation shim** so call sites elsewhere don't break in the same
   commit: keep `bootstrapBuiltInsIfNeeded()` as `@available(*, deprecated)`
   calling `ensureBootstrapped()`.
3. Keep `ProviderManifests` literals *temporarily* in core to avoid breaking
   `ModelManager.lazyResolveSlug` (it calls
   `ProviderManifests.manifest(for:)`). Phase 6 removes this; Phase 1 only needs
   the registry decoupled. (Interim: `lazyResolveSlug` should prefer
   `ProviderRegistry.manifest(for:)` over the literal — a one-line change that
   removes the literal dependency early.)

**Acceptance:** core builds with the concrete provider files *deleted from the
build* (temporarily exclude them) and an empty registry; existing tests that
need providers fail loudly (expected — fixed in Phase 3/7).

**Risk:** the global mutable `ProviderRegistry` is `NSLock`-guarded static
state. The bootstrap hook keeps that model; if the project later wants
instance-scoped registries (per the orchestrator-pool work), this hook is the
natural place to thread an instance. Flag, don't solve here.

### Phase 2 — Create the `SwiftAgentHarnessProviders` target

**Objective:** a home for concrete plugins, before moving anything.

1. `Package.swift`: add
   ```swift
   .target(
       name: "SwiftAgentHarnessProviders",
       dependencies: [
           "SwiftAgentHarness",
           .product(name: "OllamaKit", package: "OllamaKit"),
           .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
       ],
       resources: [
           .process("manifests"),
           .process("catalogs"),
       ]
   )
   ```
   and add a `.library(name: "SwiftAgentHarnessProviders", …)` product so apps
   can depend on it directly.
2. Add `SwiftAgentHarnessProvidersTests` test target (or fold provider tests
   into the existing test target with a dependency on both — decide in Phase 7).

**Acceptance:** empty new target builds and links against core.

### Phase 3 — Move the concrete providers + resources

**Objective:** physically relocate provider code/data; wire `registerDefaults`.

1. Move `TextInference/TextInferenceProviders.swift` → providers target. It
   already only depends on the contract types + `OllamaKit` + SwiftAgentKit
   codecs — all available there.
2. Move the stub slot fillers from `Slots/ProviderCapabilitySlotProtocols.swift`:
   **split the file** — the *protocols* (`SpeechProviding`, `CLIInferenceBackendProviding`,
   …) stay in core (they're contract); the `Stub*Provider` structs move to the
   providers target (they're demo implementations).
3. Move `manifests/*.json`, `catalogs/*.json`, `catalogs/overrides/*.json`,
   `catalogs/README.md` out of core's `resources:` and into the providers
   target. Update `Package.swift` core `resources:` to drop the two provider
   entries (keep `ExecutionEnvironments/manifests`). Update
   `ProviderManifestLoader` / `ProviderCatalogLoader` to read from
   `Bundle.module` of the **providers** target.
4. Author `registerDefaults`:
   ```swift
   // SwiftAgentHarnessProviders
   public func registerDefaults(
       into registry: ProviderRegistry.Type = ProviderRegistry.self,
       options: DefaultProviderOptions = .init()
   ) {
       DefaultProviderAdapterFactories.installAll()      // factories for config plugins
       try? registry.register(openAIRegistration())
       try? registry.register(anthropicRegistration())
       try? registry.register(ollamaRegistration())
       try? registry.register(lmStudioRegistration())
       try? registry.register(openRouterRegistration())
       // GenericOpenAICompat is registered per-config, not as a singleton.
   }
   ```
   And install it as the bootstrap hook so existing lazy paths keep working:
   `ProviderRegistry.installBootstrap { registerDefaults() }` — called by the
   app, or by a `SwiftAgentHarnessProviders.bootstrap()` convenience.
5. Move the `ProviderManifests` literal index into the providers target (or
   regenerate from JSON — Phase 6). For now, relocate as-is so
   `lazyResolveSlug`'s remaining reference is satisfied via
   `ProviderRegistry.manifest(for:)` (changed in Phase 1).

**Acceptance:** app calling `registerDefaults()` reproduces today's behavior;
core target no longer contains provider code or provider resources.

### Phase 4 — Generic configurable provider + config-plugin loader

**Objective:** ship the configurable default and the runtime config path.

1. `GenericOpenAICompatProvider` in the providers target: a
   `TextInferenceProviding` whose `manifest`, endpoint, model prefixes and
   catalog come from an injected `ProviderInstanceConfig` (not hardcoded). Its
   `makeAdapter` builds `OpenAILLM` against the configured `baseURL` — the same
   codec `OpenRouterTextInferenceProvider` already uses. `discoverEntries`
   optionally probes `GET /v1/models` (OpenAI-compat) so `llama.cpp`/LM
   Studio/vLLM self-describe; `staticCatalogEntries` returns the config's
   embedded catalog if present.
2. Define the **configuration-plugin file format** (core type
   `ProviderInstanceConfig`, decoded from JSON):
   ```jsonc
   {
     "schemaVersion": 1,
     "adapterKind": "openai-compat",      // which generic factory to bind
     "id": "llamacpp-local",              // becomes the provider id
     "label": "llama.cpp (local)",
     "providerEndpoints": [{ "id": "default", "baseUrl": "http://127.0.0.1:8080/v1" }],
     "providerAuthChoices": [             // empty ⇒ local/no-credential
       { "id": "api-key", "authType": "api-key", "envVars": ["LLAMACPP_API_KEY"] }
     ],
     "modelSupport": { "modelPrefixes": [] },
     "capabilitySlots": ["text-inference"],
     "default": false,
     "catalog": [ /* optional embedded ProviderCatalogEntry rows */ ]
   }
   ```
   This reuses `ProviderManifest`'s shape; the only new keys are `schemaVersion`,
   `adapterKind`, and the optional inline `catalog`. Validate via
   `ProviderManifestValidation` plus an `adapterKind`-known check.
3. `ConfigPluginLoader` (core): given a directory the **app** designates (the
   library never picks filesystem locations — the app passes a URL, keeping this
   sandbox-friendly), decode each `*.providerconfig.json`, look up the factory
   via `ProviderAdapterFactoryRegistry`, build a `ProviderRegistration`, and
   `register` it (making it *available*). Surface decode/validation failures as
   structured errors, never crashes.
4. Ship a default `openai-compat` config example in the providers target docs
   (not auto-loaded) so app developers have a copy-paste starting point.

**Acceptance:** dropping a `llamacpp-local.providerconfig.json` into the
app-provided directory makes `llamacpp-local/<model>` resolvable once an
`AuthProfile` exists for it (or, being credential-less, once its local profile
is confirmed — Phase 5).

**Risk:** id collisions between a config plugin and a default provider. The
loader must reject a config whose `id` already exists in the registry (reuse
`ProviderRegistry`'s existing duplicate-registration guard, but return an error
instead of `fatalError` — see Phase 7 hardening).

### Phase 5 — Provider lifecycle (available / registered / disabled)

**Objective:** implement the handover's opt-in rule and gate the Pool on it.

1. Add to core:
   ```swift
   public enum ProviderLifecycleState: String, Sendable, Codable {
       case available    // plugin present; excluded from Pool
       case registered   // ≥1 active AuthProfile; participates in Pool
       case disabled      // was registered, explicitly deactivated; config retained
   }
   ```
2. Derive state from `AuthProfileStore` + an explicit disable set:
   - **Credential-requiring** providers (`anthropic`, `openai`, `openrouter`,
     and any config plugin with non-empty `providerAuthChoices`): `registered`
     iff ≥1 `AuthProfile` exists that is not `disabled` (presence of a profile =
     opt-in; `isDispatchReady` is a *separate, runtime* concern handled by
     `MissingAuthCredentialLLM`).
   - **Local / credential-less** providers (`ollama`, `lmstudio`, and config
     plugins with empty `providerAuthChoices`): `registered` requires an
     **explicit local profile**. Extend `AuthProfileType` with `case local`
     (base-URL-only, no key); a `local` profile is the user's confirmation
     gesture. Adjust `AuthProfile.isDispatchReady`: `.local` is dispatch-ready
     when it has a `baseURL` (or inherits the manifest default).
   - **`disabled`**: a provider-level flag in config (separate from per-profile
     status) so "registered but turned off" is expressible (resolves handover
     open question #2 in the affirmative — disabled ≠ unregistered).
3. **Gate the Pool.** In `ModelManager.syncRegistryFromDiscovery()`, iterate
   only providers whose lifecycle is `registered`:
   ```swift
   for provider in ProviderRegistry.registeredTextInferenceProviders(authStore: …) { … }
   ```
   Add `ProviderRegistry.registeredTextInferenceProviders(...)` filtering
   `allTextInferenceProviders()` by lifecycle. Same gate applies to
   `lazyResolveSlug` (don't resolve a slug for an unregistered provider).
4. Add `manifest.default: Bool` (handover: UI-surfacing only, no lifecycle
   effect) to `ProviderManifest` + JSON. First-run/setup UIs read it to
   prominently offer the foundational set; the activation requirement is
   identical regardless.

**Acceptance:** with no `AuthProfile`s configured, the model registry is empty.
Adding an Anthropic key makes `anthropic/*` resolvable; confirming an Ollama
local profile makes `ollama/*` discoverable; neither leaks into the Pool before
its opt-in.

**Risk (biggest behavioral change):** anything today relying on all-five
providers being present without auth (tests, demos, discovery) breaks. This is
intended per the handover, but every such site must be migrated to register an
`AuthProfile` (or a `local` profile) first. Enumerate them in Phase 7.

### Phase 6 — Single manifest source of truth

**Objective:** kill the literal-vs-JSON drift.

Recommendation: **JSON manifests are canonical**; the providers target loads
them via `ProviderManifestLoader` and exposes typed accessors. Remove the
`ProviderManifests.*` literals; if compile-time constants are still wanted for
the foundational set, **generate** them from JSON in a build plugin or a checked
‑in generated file, with a test asserting `decoded(json) == literal`. Either
way, the config-plugin path already forces JSON to be a first-class source, so
defaults should not be a second mechanism.

**Acceptance:** there is exactly one place a provider's static metadata is
authored (its `*.manifest.json`); a drift test guards it if generated literals
are kept.

### Phase 7 — Call-site migration + hardening + tests

1. **Bootstrap migration:** every `ensureBootstrapped()` site works once the app
   installs the hook. The existing test target must call `registerDefaults()` /
   install the hook in setup. Audit the 10 sites; confirm none assume a *specific*
   provider is present without an `AuthProfile`.
2. **`fatalError` → throwing:** `ProviderRegistry.registerUnlocked` currently
   `fatalError`s on duplicate id, and `resolvedBearerToken()` in
   `TextInferenceProviders.swift` `fatalError`s when dispatched without a
   credential. With user-supplied config plugins, both become reachable from
   data: convert duplicate-registration to a thrown `ProviderRegistryError`, and
   ensure the lifecycle gate (Phase 5) makes the credential `fatalError`
   unreachable for unregistered providers (keep it only as a true invariant
   guard behind the gate, or downgrade to a thrown error surfaced via the Pool's
   `MissingAuthCredentialLLM`).
3. **Tests:**
   - Unit: lifecycle derivation (each category → expected state), config-plugin
     decode/validate (happy + malformed + duplicate-id + unknown-adapterKind),
     generic provider `/v1/models` discovery (mocked), factory lookup.
   - Migration: move provider-specific tests into the providers test target.
   - Regression: a test asserting an empty `AuthProfileStore` yields an empty
     model registry (the opt-in invariant).
   - Drift: manifest JSON ↔ literal (if Phase 6 keeps literals).

### Phase 8 — Documentation

1. **In-repo:** update `Sources/SwiftAgentHarness/Backends/Providers/README.md`
   and `catalogs/README.md` to describe the two plugin flavors, the lifecycle,
   the `registerDefaults` entry point, and the config-plugin file format. These
   *may* name SwiftAgentHarness / OllamaKit (they're internal).
2. **Template (generic):** the companion edits to
   `harness-template/backends/providers/README.md` — a **Provider lifecycle**
   section and a **Packaging: code plugins vs configuration plugins** section —
   are delivered alongside this plan. Per the template's no-harness-names rule,
   those are written generically (no `SwiftAgentHarness`, no `OllamaKit`, no
   Swift specifics).

---

## 4. Public API surface (end state)

What an **app developer** touches:

```swift
import SwiftAgentHarness
import SwiftAgentHarnessProviders

// 1. Make the foundational plugins AVAILABLE (code plugins).
SwiftAgentHarnessProviders.registerDefaults()

// 2. Optionally load CONFIGURATION plugins from an app-chosen directory.
try ConfigPluginLoader.loadAll(from: appSupportProviderConfigsURL)

// 3. The user opts in (provider registration) by adding credentials:
authProfileStore.add(AuthProfile(id: "work", providerID: "anthropic",
                                 authType: .apiKey, apiKey: key))
// …or confirms a local provider:
authProfileStore.add(AuthProfile(id: "local", providerID: "ollama",
                                 authType: .local, baseURL: ollamaURL))
```

What a **third-party code-plugin author** ships (compiled into the app):

```swift
struct MyProvider: TextInferenceProviding { /* manifest, makeAdapter, … */ }

public func registerMyProvider() throws {
    try ProviderRegistry.register(ProviderRegistration(
        manifest: myManifest, textInference: MyProvider()))
}
```

What an **end user** ships (data only, no code): a
`*.providerconfig.json` parameterizing a generic `adapterKind`.

---

## 5. Sequencing, risk, and effort

```
Phase 1 ─► Phase 2 ─► Phase 3 ─► Phase 4
                          └─► Phase 5 ─► Phase 6 ─► Phase 7 ─► Phase 8
```
Phases 4 and 5 both depend on 3 and can proceed in parallel; 6/7 fold them back
together.

| Phase | Effort | Primary risk | Mitigation |
|---|---|---|---|
| 1 Invert dependency | M | hidden bootstrap callers | deprecation shim; keep tree green |
| 2 New target | S | SwiftPM resource bundling per platform | verify `Bundle.module` on iOS/visionOS early |
| 3 Move providers | M | resource path breakage | move + re-point loaders in one commit |
| 4 Config plugins | M | id collision, malformed data crashing | throwing loader, validation, app-supplied dir |
| 5 Lifecycle gate | **L** | empty-registry behavior change | enumerate every auth-less assumption; the regression test is the canary |
| 6 Manifest SoT | S | literal/JSON drift | generate + drift test |
| 7 Migration | M | reachable `fatalError`s | convert to thrown errors |
| 8 Docs | S | template no-names rule | generic wording, reviewed against memory rule |

## 6. Open questions carried from the handover

1. **First-run UX** — does the app present a checklist of `default: true`
   providers to register, or defer to settings? *Out of library scope* — the
   library exposes `manifest.default` + lifecycle; the app decides UX.
2. **"Register but disable"** — resolved **yes**: `disabled` is a first-class
   lifecycle state retaining config (Phase 5).
3. **Local-provider confirmation** — resolved via an explicit `AuthProfileType.local`
   profile; localhost autodiscovery is *not* sufficient for opt-in (an explicit
   confirmation gesture is required, matching the handover's intent).
