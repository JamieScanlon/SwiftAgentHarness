import Foundation
import Logging

public enum PublishingGovernanceMode: String, Sendable, Codable, CaseIterable {
    case strict
    case soft
}

public struct PublishingGovernanceConfiguration: Sendable {
    public var mode: PublishingGovernanceMode
    public var diagnosticsEnabled: Bool

    public init(
        mode: PublishingGovernanceMode = .strict,
        diagnosticsEnabled: Bool = false
    ) {
        self.mode = mode
        self.diagnosticsEnabled = diagnosticsEnabled
    }

    public static let defaultStrict = PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: false)

    public var rejectsInvalidPayloads: Bool {
        mode == .strict
    }

    public static func loadFromPromptConfigBundle(logger: Logger? = nil) -> PublishingGovernanceConfiguration {
        guard let url = PromptConfigBundleResource.url(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = json["publishingGovernance"] as? [String: Any]
        else {
            return .defaultStrict
        }

        let mode = (block["mode"] as? String)
            .flatMap(PublishingGovernanceMode.init(rawValue:))
            ?? .strict
        let diagnosticsEnabled = block["diagnosticsEnabled"] as? Bool ?? false

        if block["mode"] != nil && PublishingGovernanceMode(rawValue: (block["mode"] as? String) ?? "") == nil {
            logger?.warning("Unknown publishingGovernance.mode in PromptConfig.json; using strict")
        }

        return PublishingGovernanceConfiguration(
            mode: mode,
            diagnosticsEnabled: diagnosticsEnabled
        )
    }

    public func applyingOverrides(
        modeRawOverride: String?,
        diagnosticsEnabledOverride: Bool?
    ) -> PublishingGovernanceConfiguration {
        var out = self
        if let raw = modeRawOverride,
           let mode = PublishingGovernanceMode(rawValue: raw) {
            out.mode = mode
        }
        if let diagnosticsEnabledOverride {
            out.diagnosticsEnabled = diagnosticsEnabledOverride
        }
        return out
    }
}
