import Foundation
import SwiftAgentHarness
import SwiftAgentKit

/// Former `Constants` Ollama/LM Studio catalog maps — test-only host fixtures.
enum InferenceRuntimeCatalogFixtures {
    static let ollamaServerURL = URL(string: "http://localhost:11434")!
    static let lmStudioServerURL = URL(string: "http://localhost:1234")!

    static let ollamaModelIDMap: [String: ModelConfig] = [
        "gpt-oss:latest": ModelConfig(
            uuid: UUID(uuidString: "b071a111-cba1-41d0-a4e7-e7b73295bb0e")!,
            modelProtocol: .openAIAPI,
            hardcodedCost: ModelCatalogCostPresets.budget
        ),
        "gemma3:27b": ModelConfig(
            uuid: UUID(uuidString: "d32412a4-c3fe-4a49-a7a6-e41c97218cae")!,
            modelProtocol: .ollama,
            hardcodedCost: ModelCatalogCostPresets.budget
        ),
        "qwq:32b": ModelConfig(
            uuid: UUID(uuidString: "d6be9ecc-d3dd-4de5-bbc7-6ad1c4a0b070")!,
            modelProtocol: .ollama,
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "llama3.3:latest": ModelConfig(
            uuid: UUID(uuidString: "1a58c4ee-a676-43bb-9c7f-dd54b9d2f210")!,
            modelProtocol: .ollama,
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "deepseek-r1:70b": ModelConfig(
            uuid: UUID(uuidString: "06cde022-d5de-4a05-a7eb-61c52bbc23b1")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.reasoningRequired, .tools],
            hardcodedRequestFeatures: ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text],
                parallelToolCalls: .unsupported,
                reasoningEfforts: []
            ),
            hardcodedCost: ModelCatalogCostPresets.premium
        ),
        "deepseek-r1:latest": ModelConfig(
            uuid: UUID(uuidString: "dd0ef2c3-60a6-431a-be0a-a02e688bb517")!,
            modelProtocol: .ollama,
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "llama4:scout": ModelConfig(
            uuid: UUID(uuidString: "e508c1c6-54d4-42da-b6b4-831155be4fa3")!,
            modelProtocol: .ollama,
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "qwen3:30b-a3b": ModelConfig(
            uuid: UUID(uuidString: "aa3d0a83-0799-40e5-b9bb-218f9539bb6c")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.thinking, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "qwen3-vl:32b": ModelConfig(
            uuid: UUID(uuidString: "beddad55-22f6-4e01-ac11-7be586532944")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "qwen3.5:35b": ModelConfig(
            uuid: UUID(uuidString: "f0399013-8a04-45bd-860f-34fc92bf3865")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "gemma4:e4b": ModelConfig(
            uuid: UUID(uuidString: "9023cd6b-54f5-439f-bf59-833d41926d27")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .audio, .thinking, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "gemma4:31b": ModelConfig(
            uuid: UUID(uuidString: "a74e8c24-07d9-4e9a-9bde-74e11aa3d7f5")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .audio, .thinking, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "qwen3.6:35b": ModelConfig(
            uuid: UUID(uuidString: "7ed01fa2-59dc-4e83-ba95-75b2f36c7b30")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "qwen3.6:27b": ModelConfig(
            uuid: UUID(uuidString: "06717736-12fd-4755-9570-648f30f77bd7")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
    ]

    static let lmStudioModelIDMap: [String: ModelConfig] = [
        "minimax/minimax-m2": ModelConfig(
            uuid: UUID(uuidString: "d7933034-a066-4b62-b3f2-ace1a910196b")!,
            modelProtocol: .lmStudio,
            hardcodedCapabilities: [.thinking, .tools],
            hardcodedRequestFeatures: ModelRequestFeatures(
                streaming: false,
                responseFormats: [],
                parallelToolCalls: .unsupported,
                reasoningEfforts: [.low, .medium, .high]
            ),
            hardcodedCost: ModelCatalogCostPresets.premium
        ),
        "minimax/minimax-m2.5": ModelConfig(
            uuid: UUID(uuidString: "4b14da4b-5fad-4094-ae4f-7fdba5465155")!,
            modelProtocol: .lmStudio,
            hardcodedCapabilities: [.thinking, .tools],
            hardcodedRequestFeatures: ModelRequestFeatures(
                streaming: false,
                responseFormats: [],
                parallelToolCalls: .unsupported,
                reasoningEfforts: [.low, .medium, .high]
            ),
            hardcodedCost: ModelCatalogCostPresets.premium
        ),
        "qwen/qwen3-vl-30b": ModelConfig(
            uuid: UUID(uuidString: "36456ae3-8d80-43c5-b769-4537b70925eb")!,
            modelProtocol: .lmStudio,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "qwen/qwen3.6-27b": ModelConfig(
            uuid: UUID(uuidString: "df9cfe25-cbb2-4d5f-9060-9c83d95f6f53")!,
            modelProtocol: .lmStudio,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "mistralai/devstral-small-2507": ModelConfig(
            uuid: UUID(uuidString: "1d368b05-d961-4bad-a7cf-5a6a506542ae")!,
            modelProtocol: .lmStudio,
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "qwen/qwen3-coder-30b": ModelConfig(
            uuid: UUID(uuidString: "f1075c75-ab6f-42b1-9375-252018ffdc80")!,
            modelProtocol: .lmStudio,
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "openai/gpt-oss-20b": ModelConfig(
            uuid: UUID(uuidString: "72ff17c7-1a9f-4f51-833c-d5b1251ef054")!,
            modelProtocol: .lmStudio,
            hardcodedRequestFeatures: ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text, .jsonObject, .jsonSchema],
                parallelToolCalls: .uncapped,
                reasoningEfforts: []
            ),
            hardcodedCost: ModelCatalogCostPresets.budget
        ),
        "qwen/qwen3-235b-a22b": ModelConfig(
            uuid: UUID(uuidString: "1362ae62-b029-4b37-a454-a92d67364b52")!,
            modelProtocol: .lmStudio,
            hardcodedCapabilities: [.thinking, .tools],
            hardcodedRequestFeatures: ModelRequestFeatures(
                streaming: false,
                responseFormats: [],
                parallelToolCalls: .unsupported,
                reasoningEfforts: [.low, .medium, .high]
            ),
            hardcodedCost: ModelCatalogCostPresets.default
        ),
        "lmstudio-community/Qwen3.5-397B-A17B-MLX-8bit": ModelConfig(
            uuid: UUID(uuidString: "45e02e09-6bfd-4c0b-960d-611381173d5c")!,
            modelProtocol: .lmStudio,
            hardcodedCapabilities: [.vision, .tools],
            hardcodedCost: ModelCatalogCostPresets.default
        ),
    ]

    /// Default API-server runtimes for tests that previously relied on auto-registered ollama/lmstudio.
    static var defaultTestInferenceRuntimes: [InferenceRuntimeConfig] {
        [
            InferenceRuntimeConfig(
                providerID: "ollama",
                label: "Ollama",
                adapterKind: .ollama,
                serverURL: ollamaServerURL,
                modelIDMap: ollamaModelIDMap
            ),
            InferenceRuntimeConfig(
                providerID: "lmstudio",
                label: "LM Studio",
                adapterKind: .lmStudio,
                serverURL: lmStudioServerURL,
                modelIDMap: lmStudioModelIDMap
            ),
        ]
    }
}
