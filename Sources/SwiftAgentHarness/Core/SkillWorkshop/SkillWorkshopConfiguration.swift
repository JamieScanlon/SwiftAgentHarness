import Foundation
import Logging

struct SkillWorkshopConfiguration: Sendable, Equatable {
    var enabled: Bool
    var maxProposalsPerWorkspace: Int

    static let `default` = SkillWorkshopConfiguration(
        enabled: false,
        maxProposalsPerWorkspace: 50
    )
}

enum SkillWorkshopConfigurationLoader {
    static func loadFromPromptConfigBundle(logger: Logger? = nil) -> SkillWorkshopConfiguration {
        guard let data = PromptConfigBundleResource.data(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = json["skillWorkshop"] as? [String: Any] else {
            return .default
        }
        return load(fromSkillWorkshopObject: object)
    }

    static func load(fromSkillWorkshopObject object: [String: Any]) -> SkillWorkshopConfiguration {
        var config = SkillWorkshopConfiguration.default
        if let enabled = object["enabled"] as? Bool { config.enabled = enabled }
        if let limit = object["maxProposalsPerWorkspace"] as? Int {
            config.maxProposalsPerWorkspace = min(500, max(1, limit))
        }
        return config
    }
}
