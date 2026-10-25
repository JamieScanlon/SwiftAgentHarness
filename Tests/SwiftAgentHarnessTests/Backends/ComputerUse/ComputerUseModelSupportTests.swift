import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use on model descriptors")
struct ComputerUseModelSupportTests {
    private func profile(
        feature: FeatureSupport? = nil,
        maxImageEdgePx: Int? = nil,
        maxImageTokens: Int? = nil
    ) -> ContractProfile {
        var features: [String: FeatureSupport] = ["tools": FeatureSupport()]
        if let feature { features[ComputerUseModelSupport.featureKey] = feature }
        return ContractProfile(
            contract: .generate,
            surface: .anthropicMessages,
            interaction: [.unary],
            input: [.text, .image],
            output: [.text, .toolCalls],
            guarantee: .freeText,
            features: features,
            limits: ContractLimits(maxImageEdgePx: maxImageEdgePx, maxImageTokens: maxImageTokens)
        )
    }

    private let toolset = FeatureSupport(
        version: "toolset-2026-08",
        params: [
            "coordinates": .string("pixels"),
            "maxEdgePx": .integer(2576),
            "keepRecentScreenshots": .integer(4),
            "pruneEvery": .integer(10),
        ]
    )

    @Test("The versioned feature carries the toolset version, coordinate dialect, edge cap, and retention hints")
    func parsesFeature() throws {
        let support = try #require(ComputerUseModelSupport(profile: profile(feature: toolset, maxImageEdgePx: 1568)))
        #expect(support.version == "toolset-2026-08")
        #expect(support.coordinateMode == .imagePixels)
        #expect(support.maxImageEdgePx == 1568)
        #expect(support.keepRecentScreenshots == 4)
        #expect(support.pruneEvery == 10)
    }

    @Test("A normalized-grid dialect selects the 0–999 codec")
    func normalizedDialect() throws {
        let feature = FeatureSupport(version: "cu-2026", params: ["coordinates": .string("normalized-1000")])
        #expect(ComputerUseModelSupport(profile: profile(feature: feature))?.coordinateMode == .normalized1000)
    }

    @Test("No feature, or a feature marked unsupported, means no computer-use support")
    func absentFeature() {
        #expect(ComputerUseModelSupport(profile: profile()) == nil)
        #expect(ComputerUseModelSupport(profile: profile(feature: FeatureSupport(supported: false))) == nil)
    }

    @Test("Image limits come from the model: the tighter of feature and contract caps, with the visual-token cap")
    func imageLimitFromModel() {
        let limit = ObservationImageLimit(model: profile(feature: toolset, maxImageEdgePx: 1568, maxImageTokens: 1600))
        #expect(limit.longEdgePx == 1568)
        #expect(limit.maxVisualTokens == 1600)
        #expect(ObservationImageLimit(model: profile(maxImageEdgePx: 2000)).longEdgePx == 2000)
        #expect(ObservationImageLimit(model: nil).longEdgePx == ObservationImageLimit.defaultLongEdgePx)
        #expect(ObservationImageLimit(model: profile()).longEdgePx == ObservationImageLimit.defaultLongEdgePx)
    }

    @Test("A session configured from the bound model takes its coordinate dialect and image limit")
    func sessionFromModel() {
        let feature = FeatureSupport(version: "cu-2026", params: ["coordinates": .string("normalized-1000"), "maxEdgePx": .integer(1400)])
        let configuration = ComputerUseSessionConfiguration(
            task: ComputerUseTaskContext(userRequest: ["x"]),
            model: profile(feature: feature, maxImageTokens: 1500)
        )
        #expect(configuration.coordinateMode == .normalized1000)
        #expect(configuration.imageLimit == ObservationImageLimit(longEdgePx: 1400, maxVisualTokens: 1500))
        let plain = ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["x"]), model: nil)
        #expect(plain.coordinateMode == .imagePixels)
    }

    @Test("A catalog row can declare the feature and vision caps; the generate profile carries them")
    func catalogRowDeclaresFeature() throws {
        let json = """
        {
          "registryId": "b2000002-0002-4000-8000-0000000000aa",
          "endpointModelId": "claude-test",
          "modelProtocol": "anthropic",
          "capabilities": ["completion", "tools", "vision"],
          "maxContextLength": 200000,
          "vision": {"maxImageEdgePx": 1568, "maxImageTokens": 1600},
          "features": {
            "computer-use": {"supported": true, "version": "toolset-2026-08", "params": {"coordinates": "pixels", "maxEdgePx": 2576}}
          }
        }
        """
        let row = try JSONDecoder().decode(BundledCatalogModelRow.self, from: Data(json.utf8))
        let entry = row.toProviderCatalogEntry().toRegistryEntry(providerID: "anthropic", serverURL: URL(string: "https://api.anthropic.com")!)
        let generate = try #require(entry.profile(for: .generate))
        #expect(generate.limits.maxImageEdgePx == 1568)
        #expect(generate.limits.maxImageTokens == 1600)
        #expect(generate.limits.contextTokens == 200_000)
        #expect(generate.features["tools"] != nil)
        #expect(ComputerUseModelSupport(profile: generate)?.version == "toolset-2026-08")
        #expect(generate.input.contains(.image))
    }

    @Test("A catalog row without them keeps the synthesized profile and no explicit contracts")
    func catalogRowWithoutFeature() throws {
        let json = """
        {"registryId": "b2000002-0002-4000-8000-0000000000ab", "endpointModelId": "m", "modelProtocol": "anthropic",
         "capabilities": ["completion", "tools", "vision"]}
        """
        let row = try JSONDecoder().decode(BundledCatalogModelRow.self, from: Data(json.utf8))
        let entry = row.toProviderCatalogEntry().toRegistryEntry(providerID: "anthropic", serverURL: URL(string: "https://api.anthropic.com")!)
        #expect(entry.contracts.isEmpty)
        #expect(ComputerUseModelSupport(profile: try #require(entry.profile(for: .generate))) == nil)
    }
}
