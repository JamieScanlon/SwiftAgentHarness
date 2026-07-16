import CryptoKit
import Foundation

struct SystemPromptSkillRenderSnapshot: Sendable, Equatable, Codable {
    let activatedSkillNames: [String]
    let skillsIndexDigest: String?

    static func capture(
        activatedSkillNames: [String],
        skillsIndexXML: String?
    ) -> SystemPromptSkillRenderSnapshot {
        let sortedNames = activatedSkillNames.sorted()
        let indexDigest = skillsIndexXML.map { SystemPromptDispatchCodec.sha256Digest(of: $0) }
        return SystemPromptSkillRenderSnapshot(
            activatedSkillNames: sortedNames,
            skillsIndexDigest: indexDigest
        )
    }
}

struct SystemPromptAssemblyReplaySpec: Sendable, Equatable, Codable {
    let assemblyFingerprint: String
    let assembleReferenceDateISO: String
    let userSystemPrompt: String
    let activatedSkillNames: [String]
    let skillsIndexDigest: String?
    let providerStablePrefix: String?
    let contributionSourcesDigest: String
    /// PromptConfig-derived values captured at assemble time so replays never re-read ambient config.
    let promptConfigSnapshot: PromptAssemblyConfigSnapshot

    enum CodingKeys: String, CodingKey {
        case assemblyFingerprint
        case assembleReferenceDateISO
        case userSystemPrompt
        case activatedSkillNames
        case skillsIndexDigest
        case providerStablePrefix
        case contributionSourcesDigest
        case promptConfigSnapshot
    }

    init(
        assemblyFingerprint: String,
        assembleReferenceDateISO: String,
        userSystemPrompt: String,
        activatedSkillNames: [String],
        skillsIndexDigest: String?,
        providerStablePrefix: String?,
        contributionSourcesDigest: String,
        promptConfigSnapshot: PromptAssemblyConfigSnapshot
    ) {
        self.assemblyFingerprint = assemblyFingerprint
        self.assembleReferenceDateISO = assembleReferenceDateISO
        self.userSystemPrompt = userSystemPrompt
        self.activatedSkillNames = activatedSkillNames
        self.skillsIndexDigest = skillsIndexDigest
        self.providerStablePrefix = providerStablePrefix
        self.contributionSourcesDigest = contributionSourcesDigest
        self.promptConfigSnapshot = promptConfigSnapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assemblyFingerprint = try container.decode(String.self, forKey: .assemblyFingerprint)
        assembleReferenceDateISO = try container.decode(String.self, forKey: .assembleReferenceDateISO)
        userSystemPrompt = try container.decode(String.self, forKey: .userSystemPrompt)
        activatedSkillNames = try container.decode([String].self, forKey: .activatedSkillNames)
        skillsIndexDigest = try container.decodeIfPresent(String.self, forKey: .skillsIndexDigest)
        providerStablePrefix = try container.decodeIfPresent(String.self, forKey: .providerStablePrefix)
        contributionSourcesDigest = try container.decode(String.self, forKey: .contributionSourcesDigest)
        promptConfigSnapshot = try container.decodeIfPresent(
            PromptAssemblyConfigSnapshot.self,
            forKey: .promptConfigSnapshot
        ) ?? PromptAssemblyConfigSnapshot(from: .default, strictAgentHarnessPrompts: true)
    }

    static func contributionSourcesDigest(contributions: [SystemPromptContribution]) -> String {
        let canonical = contributions
            .sorted { $0.source.rawValue < $1.source.rawValue }
            .map { contribution in
                var parts: [String] = ["source=\(contribution.source.rawValue)"]
                if let prefix = contribution.stablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty {
                    parts.append("prefix=\(String(prefix.prefix(128)))")
                }
                if !contribution.sectionOverrides.isEmpty {
                    let overrides = contribution.sectionOverrides
                        .keys
                        .sorted { $0.rawValue < $1.rawValue }
                        .map { key in
                            let value = contribution.sectionOverrides[key] ?? ""
                            return "\(key.rawValue)=\(String(value.prefix(128)))"
                        }
                        .joined(separator: ",")
                    parts.append("overrides=\(overrides)")
                }
                if !contribution.sectionDirectives.isEmpty {
                    let directives = contribution.sectionDirectives
                        .keys
                        .sorted { $0.rawValue < $1.rawValue }
                        .map { key in
                            let value = contribution.sectionDirectives[key] ?? ""
                            return "\(key.rawValue)=\(String(value.prefix(128)))"
                        }
                        .joined(separator: ",")
                    parts.append("directives=\(directives)")
                }
                if !contribution.suppress.isEmpty {
                    parts.append("suppress=\(contribution.suppress.map(\.rawValue).sorted().joined(separator: ","))")
                }
                return parts.joined(separator: "|")
            }
            .joined(separator: ";")
        return SystemPromptDispatchCodec.sha256Digest(of: canonical)
    }

    static func build(
        assemblyFingerprint: String,
        assembleReferenceDateISO: String,
        userSystemPrompt: String,
        skillSnapshot: SystemPromptSkillRenderSnapshot,
        providerStablePrefix: String?,
        contributions: [SystemPromptContribution],
        promptConfigSnapshot: PromptAssemblyConfigSnapshot
    ) -> SystemPromptAssemblyReplaySpec {
        SystemPromptAssemblyReplaySpec(
            assemblyFingerprint: assemblyFingerprint,
            assembleReferenceDateISO: assembleReferenceDateISO,
            userSystemPrompt: userSystemPrompt,
            activatedSkillNames: skillSnapshot.activatedSkillNames,
            skillsIndexDigest: skillSnapshot.skillsIndexDigest,
            providerStablePrefix: providerStablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            contributionSourcesDigest: contributionSourcesDigest(contributions: contributions),
            promptConfigSnapshot: promptConfigSnapshot
        )
    }

    var replaySpecDigest: String {
        let digestPayload = SystemPromptAssemblyReplaySpecDigestPayload(
            assemblyFingerprint: assemblyFingerprint,
            assembleReferenceDateISO: assembleReferenceDateISO,
            userSystemPrompt: userSystemPrompt,
            skillsIndexDigest: skillsIndexDigest,
            providerStablePrefix: providerStablePrefix,
            contributionSourcesDigest: contributionSourcesDigest,
            promptConfigSnapshot: promptConfigSnapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(digestPayload) else {
            return SystemPromptDispatchCodec.sha256Digest(of: canonicalDigestString)
        }
        return SystemPromptDispatchCodec.sha256Digest(of: String(decoding: data, as: UTF8.self))
    }

    private var canonicalDigestString: String {
        """
        assemblyFingerprint=\(assemblyFingerprint)
        assembleReferenceDateISO=\(assembleReferenceDateISO)
        userSystemPrompt=\(userSystemPrompt)
        skillsIndexDigest=\(skillsIndexDigest ?? "-")
        providerStablePrefix=\(providerStablePrefix ?? "-")
        contributionSourcesDigest=\(contributionSourcesDigest)
        promptConfigSnapshot.includeAgentSkills=\(promptConfigSnapshot.includeAgentSkills)
        promptConfigSnapshot.includeCurrentDateTime=\(promptConfigSnapshot.includeCurrentDateTime)
        promptConfigSnapshot.strictAgentHarnessPrompts=\(promptConfigSnapshot.strictAgentHarnessPrompts)
        promptConfigSnapshot.assemblyCheckpointMode=\(promptConfigSnapshot.assemblyCheckpointMode.rawValue)
        """
    }
}

private struct SystemPromptAssemblyReplaySpecDigestPayload: Sendable, Equatable, Codable {
    let assemblyFingerprint: String
    let assembleReferenceDateISO: String
    let userSystemPrompt: String
    let skillsIndexDigest: String?
    let providerStablePrefix: String?
    let contributionSourcesDigest: String
    let promptConfigSnapshot: PromptAssemblyConfigSnapshot
}

struct SystemPromptAssemblyRenderProduct: Sendable, Equatable {
    let text: String
    let sectionProvenance: [SystemPromptSectionName: String]
    let skillSnapshot: SystemPromptSkillRenderSnapshot
    let frozenSkillsIndexXML: String?
}

public enum SystemPromptAssemblyCheckpointMode: String, Sendable, Codable, Equatable {
    case off
    case digestOnly
    case fullText
}

enum SystemPromptAssemblyCheckpointConfiguration {
    static let defaultMaxFullTextBytes = 262_144

    static func loadMode() -> SystemPromptAssemblyCheckpointMode {
        load().mode
    }

    static func load() -> (mode: SystemPromptAssemblyCheckpointMode, maxFullTextBytes: Int) {
        let assembly = PromptAssemblyConfiguration.default
        return (assembly.assemblyCheckpointMode, assembly.assemblyCheckpointMaxFullTextBytes)
    }

    static func load(from document: PromptConfigDocument) -> (mode: SystemPromptAssemblyCheckpointMode, maxFullTextBytes: Int) {
        let assembly = PromptAssemblyConfiguration.load(from: document)
        return (assembly.assemblyCheckpointMode, assembly.assemblyCheckpointMaxFullTextBytes)
    }

    static func load(from assembly: PromptAssemblyConfiguration) -> (mode: SystemPromptAssemblyCheckpointMode, maxFullTextBytes: Int) {
        (assembly.assemblyCheckpointMode, assembly.assemblyCheckpointMaxFullTextBytes)
    }

    static func load(from snapshot: PromptAssemblyConfigSnapshot) -> (mode: SystemPromptAssemblyCheckpointMode, maxFullTextBytes: Int) {
        (snapshot.assemblyCheckpointMode, snapshot.assemblyCheckpointMaxFullTextBytes)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
