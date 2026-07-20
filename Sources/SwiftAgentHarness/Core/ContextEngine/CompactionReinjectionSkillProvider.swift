import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitSkills

/// Resolves active-skill content for post-compaction re-injection. Kept as a seam so the async,
/// filesystem-backed `SkillLoader` lookup stays out of the synchronous re-injection collector and
/// can be stubbed in tests.
public protocol CompactionReinjectionSkillProviding: Sendable {
    /// Returns name + full-instruction content for each resolvable activated skill, preserving the
    /// input order. Skills that cannot be resolved are omitted.
    func reinjectableSkillContent(activatedSkillNames: [String]) async -> [ReinjectableSkill]
}

/// Default provider backed by the configured skills folder and `SkillLoader.loadSkill(named:)`.
public struct DefaultCompactionReinjectionSkillProvider: CompactionReinjectionSkillProviding {
    private let includeAgentSkills: Bool
    private let skillsFolderPath: String?
    private let logger: Logger?

    public init(
        includeAgentSkills: Bool = PromptAssemblyConfiguration.default.includeAgentSkills,
        skillsFolderPath: String? = PromptAssemblyConfiguration.default.skillsFolderPath,
        logger: Logger? = nil
    ) {
        self.includeAgentSkills = includeAgentSkills
        self.skillsFolderPath = skillsFolderPath
        self.logger = logger
    }

    public func reinjectableSkillContent(activatedSkillNames: [String]) async -> [ReinjectableSkill] {
        guard !activatedSkillNames.isEmpty, includeAgentSkills else {
            return []
        }
        guard let skillsPath = skillsFolderPath else {
            return []
        }
        let loader = SkillLoader(skillsDirectoryURL: URL(fileURLWithPath: skillsPath), logger: logger)
        var resolved: [ReinjectableSkill] = []
        for name in activatedSkillNames {
            guard let skill = try? await loader.loadSkill(named: name) else { continue }
            resolved.append(ReinjectableSkill(name: skill.name, content: skill.fullInstructions))
        }
        return resolved
    }
}
