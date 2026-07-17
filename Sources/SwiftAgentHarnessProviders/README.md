# SwiftAgentHarnessProviders

Foundational **code plugins** for the provider backend. Link this target alongside `SwiftAgentHarness` and call `registerDefaults()` once at app startup.

## Quick start

```swift
import SwiftAgentHarness
import SwiftAgentHarnessProviders

SwiftAgentHarnessProviders.registerDefaults(
    options: .init(
        inferenceRuntimes: [
            // Host-chosen id + adapter kind + endpoint + catalog overlays
            InferenceRuntimeConfig(
                providerID: "home-lab",
                label: "Home lab",
                adapterKind: .ollama,
                serverURL: URL(string: "http://127.0.0.1:11434")!,
                modelIDMap: [:]
            ),
        ]
    )
)

// Optional: load user configuration plugins from an app-chosen directory
try ConfigPluginLoader.loadAll(from: providerConfigDirectoryURL)
```

## What ships here

| Component | Description |
|---|---|
| `OpenAITextInferenceProvider`, `AnthropicTextInferenceProvider`, … | Built-in text-inference plugins |
| `GenericOpenAICompatProvider` | Configurable OpenAI-compat codec for local/remote endpoints |
| `manifests/*.manifest.json` | Canonical provider metadata (JSON source of truth) |
| `catalogs/*.catalog.json` | Bundled static model catalogs |
| `DefaultProviderAdapterFactories` | Factory registrations for configuration plugins |
| `Stub*Provider` | Demo slot fillers for non-text capability slots |

## Configuration plugins

Drop a `*.providerconfig.json` file into a directory and pass it to `ConfigPluginLoader.loadAll(from:)`. Example for a local OpenAI-compat server:

```json
{
  "schemaVersion": 1,
  "adapterKind": "openai-compat",
  "id": "llamacpp-local",
  "label": "llama.cpp (local)",
  "providerEndpoints": [{ "id": "default", "baseUrl": "http://127.0.0.1:8080/v1" }],
  "providerAuthChoices": [],
  "modelSupport": { "modelPrefixes": [] },
  "capabilitySlots": ["text-inference"]
}
```

The provider becomes **available** after loading. It participates in the Model Pool only after the user opts in (see provider lifecycle in the core Providers README).

## Testing

```swift
ProviderTestSupport.registerDefaultsForTesting()
let store = ProviderTestSupport.authStoreWithAllProvidersRegistered()
```
