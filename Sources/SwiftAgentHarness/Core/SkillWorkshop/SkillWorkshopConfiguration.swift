import Foundation
import Logging

public struct SkillWorkshopConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var maxProposalsPerWorkspace: Int

    public static let `default` = SkillWorkshopConfiguration(
        enabled: false,
        maxProposalsPerWorkspace: 50
    )

    public init(enabled: Bool, maxProposalsPerWorkspace: Int) {
        self.enabled = enabled
        self.maxProposalsPerWorkspace = maxProposalsPerWorkspace
    }
}

enum SkillWorkshopConfigurationLoader {
    static func load(from document: PromptConfigDocument, logger: Logger? = nil) -> SkillWorkshopConfiguration {
        guard let object = document.foundationObject(forKey: "skillWorkshop") else {
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
