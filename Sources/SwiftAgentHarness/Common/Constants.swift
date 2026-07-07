import Foundation
import SwiftAgentKit

/// USD pricing scaffold used by the Model Pool catalog (spec: `ModelEntry.cost`).
///
/// All fields are optional; `combinedPer1MUSD` only resolves when both input and output are populated.
/// Today the catalog leaves every field nil — the "populate cost catalog" task fills these and exposes them on the wire.
public struct ModelCostBudget: Sendable, Hashable, Codable {
    public var inputPer1MUSD: Double?
    public var outputPer1MUSD: Double?
    public var cachedInputPer1MUSD: Double?

    public init(
        inputPer1MUSD: Double? = nil,
        outputPer1MUSD: Double? = nil,
        cachedInputPer1MUSD: Double? = nil
    ) {
        self.inputPer1MUSD = inputPer1MUSD
        self.outputPer1MUSD = outputPer1MUSD
        self.cachedInputPer1MUSD = cachedInputPer1MUSD
    }

    /// Sum of input + output prices when both are present; nil otherwise.
    public var combinedPer1MUSD: Double? {
        guard let i = inputPer1MUSD, let o = outputPer1MUSD else { return nil }
        return i + o
    }
}

/// Rolling observed performance telemetry attached to registry entries.
public struct ModelObservedPerformance: Sendable, Hashable, Codable {
    public var p50LatencyMs: Double?
    public var tokensPerSecond: Double?

    public init(p50LatencyMs: Double? = nil, tokensPerSecond: Double? = nil) {
        self.p50LatencyMs = p50LatencyMs
        self.tokensPerSecond = tokensPerSecond
    }
}

/// Optional model routing hints mirrored from registry rows.
public struct ModelRoutingMetadata: Sendable, Hashable, Codable {
    public var rateLimit: ModelRateLimitMetadata?

    public init(rateLimit: ModelRateLimitMetadata? = nil) {
        self.rateLimit = rateLimit
    }
}

/// Registry metadata describing nominal per-model rate limit windows.
public struct ModelRateLimitMetadata: Sendable, Hashable, Codable {
    public var requests: Int
    public var tokens: Int
    public var windowMs: Int

    public init(requests: Int, tokens: Int, windowMs: Int) {
        self.requests = requests
        self.tokens = tokens
        self.windowMs = windowMs
    }
}

public struct ModelConfig: Sendable {
    public var uuid: UUID
    public var modelProtocol: ModelProtocol
    /// Adding capabilities here makes sure they are attached to the model. This is a woraround for the API's not providing complete capabilities
    public var hardcodedCapabilities: [LLMCapability] = []
    /// Optional request-feature overlay merged with the protocol baseline during discovery.
    public var hardcodedRequestFeatures: ModelRequestFeatures?
    /// Optional cost overlay attached to discovered registry entries. Currently nil for every row;
    /// the net-new task populates real values once a pricing catalog exists.
    public var hardcodedCost: ModelCostBudget?
    /// Optional routing metadata overlay attached to discovered registry entries.
    public var hardcodedRouting: ModelRoutingMetadata?
    /// Stable logical-model identity for cross-provider binding merge.
    public var canonicalModelKey: String?
    /// Coarse model family for ranking (e.g. `claude-sonnet`), distinct from ``canonicalModelKey``.
    public var modelFamily: String?

    public init(
        uuid: UUID,
        modelProtocol: ModelProtocol,
        hardcodedCapabilities: [LLMCapability] = [],
        hardcodedRequestFeatures: ModelRequestFeatures? = nil,
        hardcodedCost: ModelCostBudget? = nil,
        hardcodedRouting: ModelRoutingMetadata? = nil,
        canonicalModelKey: String? = nil,
        modelFamily: String? = nil
    ) {
        self.uuid = uuid
        self.modelProtocol = modelProtocol
        self.hardcodedCapabilities = hardcodedCapabilities
        self.hardcodedRequestFeatures = hardcodedRequestFeatures
        self.hardcodedCost = hardcodedCost
        self.hardcodedRouting = hardcodedRouting
        self.canonicalModelKey = canonicalModelKey
        self.modelFamily = modelFamily
    }
}

public struct Constants {
    /// Local catalog pricing baseline used by Model Pool ranking/budget projection for self-hosted runtimes.
    /// These values are internal routing heuristics (not upstream provider billing rates).
    private static let defaultCatalogCost = ModelCostBudget(
        inputPer1MUSD: 0.10,
        outputPer1MUSD: 0.30,
        cachedInputPer1MUSD: 0.02
    )
    private static let budgetCatalogCost = ModelCostBudget(
        inputPer1MUSD: 0.04,
        outputPer1MUSD: 0.12,
        cachedInputPer1MUSD: 0.01
    )
    private static let premiumCatalogCost = ModelCostBudget(
        inputPer1MUSD: 0.80,
        outputPer1MUSD: 1.60,
        cachedInputPer1MUSD: 0.10
    )

    public static let ollamaServerURL = URL(string: "http://localhost:11434")!
    public static let ollamaModelIDMap: [String: ModelConfig] = [
        "gpt-oss:latest": ModelConfig(
            uuid: UUID(uuidString: "b071a111-cba1-41d0-a4e7-e7b73295bb0e")!,
            modelProtocol: .openAIAPI,
            hardcodedCost: budgetCatalogCost
        ),
        "gemma3:27b" : ModelConfig(
            uuid: UUID(uuidString: "d32412a4-c3fe-4a49-a7a6-e41c97218cae")!,
            modelProtocol: .ollama,
            hardcodedCost: budgetCatalogCost
        ),
        "qwq:32b" : ModelConfig(
            uuid: UUID(uuidString: "d6be9ecc-d3dd-4de5-bbc7-6ad1c4a0b070")!,
            modelProtocol: .ollama,
            hardcodedCost: defaultCatalogCost
        ),
        "llama3.3:latest" : ModelConfig(
            uuid: UUID(uuidString: "1a58c4ee-a676-43bb-9c7f-dd54b9d2f210")!,
            modelProtocol: .ollama,
            hardcodedCost: defaultCatalogCost
        ),
        "deepseek-r1:70b" : ModelConfig(
            uuid: UUID(uuidString: "06cde022-d5de-4a05-a7eb-61c52bbc23b1")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.reasoningRequired, .tools],
            hardcodedRequestFeatures: ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text],
                parallelToolCalls: .unsupported,
                reasoningEfforts: []
            ),
            hardcodedCost: premiumCatalogCost
        ),
        "deepseek-r1:latest" : ModelConfig(
            uuid: UUID(uuidString: "dd0ef2c3-60a6-431a-be0a-a02e688bb517")!,
            modelProtocol: .ollama,
            hardcodedCost: defaultCatalogCost
        ),
        "llama4:scout" : ModelConfig(
            uuid: UUID(uuidString: "e508c1c6-54d4-42da-b6b4-831155be4fa3")!,
            modelProtocol: .ollama,
            hardcodedCost: defaultCatalogCost
        ),
        "qwen3:30b-a3b" : ModelConfig(
            uuid: UUID(uuidString: "aa3d0a83-0799-40e5-b9bb-218f9539bb6c")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.thinking, .tools],
            hardcodedCost: defaultCatalogCost
        ),
        "qwen3-vl:32b": ModelConfig(
            uuid: UUID(uuidString: "beddad55-22f6-4e01-ac11-7be586532944")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: defaultCatalogCost
        ),
        "qwen3.5:35b": ModelConfig(
            uuid: UUID(uuidString: "f0399013-8a04-45bd-860f-34fc92bf3865")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: defaultCatalogCost
        ),
        "gemma4:e4b": ModelConfig(
            uuid: UUID(uuidString: "9023cd6b-54f5-439f-bf59-833d41926d27")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .audio, .thinking, .tools],
            hardcodedCost: defaultCatalogCost
        ),
        "gemma4:31b": ModelConfig(
            uuid: UUID(uuidString: "a74e8c24-07d9-4e9a-9bde-74e11aa3d7f5")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .audio, .thinking, .tools],
            hardcodedCost: defaultCatalogCost
        ),
        "qwen3.6:35b": ModelConfig(
            uuid: UUID(uuidString: "7ed01fa2-59dc-4e83-ba95-75b2f36c7b30")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: defaultCatalogCost
        ),
        "qwen3.6:27b": ModelConfig(
            uuid: UUID(uuidString: "06717736-12fd-4755-9570-648f30f77bd7")!,
            modelProtocol: .ollama,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: defaultCatalogCost
        ),
    ]
    public static let lmStudioServerURL = URL(string: "http://localhost:1234")!
    public static let lmStudioModelIDMap: [String: ModelConfig] = [
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
            hardcodedCost: premiumCatalogCost
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
            hardcodedCost: premiumCatalogCost
        ),
        "qwen/qwen3-vl-30b": ModelConfig(
            uuid: UUID(uuidString: "36456ae3-8d80-43c5-b769-4537b70925eb")!,
            modelProtocol: .lmStudio,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: defaultCatalogCost
        ),
        "qwen/qwen3.6-27b": ModelConfig(
            uuid: UUID(uuidString: "df9cfe25-cbb2-4d5f-9060-9c83d95f6f53")!,
            modelProtocol: .lmStudio,
            hardcodedCapabilities: [.vision, .thinking, .tools],
            hardcodedCost: defaultCatalogCost
        ),
        "mistralai/devstral-small-2507": ModelConfig(
            uuid: UUID(uuidString: "1d368b05-d961-4bad-a7cf-5a6a506542ae")!,
            modelProtocol: .lmStudio,
            hardcodedCost: defaultCatalogCost
        ),
        "qwen/qwen3-coder-30b": ModelConfig(
            uuid: UUID(uuidString: "f1075c75-ab6f-42b1-9375-252018ffdc80")!,
            modelProtocol: .lmStudio,
            hardcodedCost: defaultCatalogCost
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
            hardcodedCost: budgetCatalogCost
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
            hardcodedCost: defaultCatalogCost
        ),
        "lmstudio-community/Qwen3.5-397B-A17B-MLX-8bit": ModelConfig(
            uuid: UUID(uuidString: "2e22b0a6-8431-4b02-a804-d2c83250a443")!,
            modelProtocol: .lmStudio,
            hardcodedCapabilities: [.vision, .tools],
            hardcodedCost: defaultCatalogCost
        ),
    ]
}
