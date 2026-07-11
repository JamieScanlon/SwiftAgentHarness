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
        contributions: [SystemPromptContribution]
    ) -> SystemPromptAssemblyReplaySpec {
        SystemPromptAssemblyReplaySpec(
            assemblyFingerprint: assemblyFingerprint,
            assembleReferenceDateISO: assembleReferenceDateISO,
            userSystemPrompt: userSystemPrompt,
            activatedSkillNames: skillSnapshot.activatedSkillNames,
            skillsIndexDigest: skillSnapshot.skillsIndexDigest,
            providerStablePrefix: providerStablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            contributionSourcesDigest: contributionSourcesDigest(contributions: contributions)
        )
    }

    var replaySpecDigest: String {
        let digestPayload = SystemPromptAssemblyReplaySpecDigestPayload(
            assemblyFingerprint: assemblyFingerprint,
            assembleReferenceDateISO: assembleReferenceDateISO,
            userSystemPrompt: userSystemPrompt,
            skillsIndexDigest: skillsIndexDigest,
            providerStablePrefix: providerStablePrefix,
            contributionSourcesDigest: contributionSourcesDigest
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
}

struct SystemPromptAssemblyRenderProduct: Sendable, Equatable {
    let text: String
    let sectionProvenance: [SystemPromptSectionName: String]
    let skillSnapshot: SystemPromptSkillRenderSnapshot
    let frozenSkillsIndexXML: String?
}

enum SystemPromptAssemblyCheckpointMode: String, Sendable, Codable, Equatable {
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
        guard let jsonData = PromptConfigBundleResource.data(),
              let jsonResult = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
              let optionsObject = jsonResult["options"] as? [String: Any],
              let checkpointObject = optionsObject["systemPromptAssemblyCheckpoint"] as? [String: Any] else {
            return (.digestOnly, defaultMaxFullTextBytes)
        }
        let modeRaw = (checkpointObject["mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mode: SystemPromptAssemblyCheckpointMode = switch modeRaw {
        case "off": .off
        case "fulltext", "full_text", "full": .fullText
        default: .digestOnly
        }
        let maxBytes = checkpointObject["maxFullTextBytes"] as? Int ?? defaultMaxFullTextBytes
        return (mode, max(1_024, maxBytes))
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
