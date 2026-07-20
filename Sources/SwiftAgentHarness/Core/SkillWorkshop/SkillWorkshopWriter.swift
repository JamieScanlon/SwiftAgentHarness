import Foundation
import SwiftAgentKitSkills

enum SkillWorkshopWriterError: Error, Equatable {
    case invalidSkillName(String)
    case pathEscape
    case skillNotFound(String)
    case oldTextNotFound
    case encodingFailed
    case parseValidationFailed(String)
}

struct SkillWorkshopWriter: Sendable {
    static let defaultWorkflowSection = "Workflow"

    let skillsRoot: URL

    init(skillsRoot: URL, fileManager: FileManager = .default, parser: SkillParser = SkillParser()) {
        self.skillsRoot = skillsRoot
        _ = fileManager
        _ = parser
    }

    func previewContent(for change: SkillWorkshopChange, normalizedName: String, fileManager: FileManager = .default) throws -> String {
        switch change.action {
        case .create:
            if fileManager.fileExists(atPath: try skillDirectoryURL(for: normalizedName).path) {
                let existing = try readSkillFile(normalizedName: normalizedName, fileManager: fileManager) ?? ""
                return try appendSection(
                    to: existing,
                    sectionName: Self.defaultWorkflowSection,
                    content: change.body,
                    normalizedName: normalizedName,
                    title: change.title,
                    description: change.description
                )
            }
            return composeSkillMarkdown(
                name: normalizedName,
                description: change.description,
                body: change.body
            )
        case .append:
            let section = change.sectionName ?? Self.defaultWorkflowSection
            let existing = try readSkillFile(normalizedName: normalizedName, fileManager: fileManager)
            return try appendSection(
                to: existing,
                sectionName: section,
                content: change.body,
                normalizedName: normalizedName,
                title: change.title,
                description: change.description
            )
        case .replace:
            guard let oldText = change.oldText, !oldText.isEmpty else {
                throw SkillWorkshopWriterError.oldTextNotFound
            }
            let existing = try readSkillFile(normalizedName: normalizedName, fileManager: fileManager) ?? ""
            guard existing.contains(oldText) else {
                throw SkillWorkshopWriterError.oldTextNotFound
            }
            return existing.replacingOccurrences(of: oldText, with: change.body)
        }
    }

    @discardableResult
    func apply(change: SkillWorkshopChange, fileManager: FileManager = .default, parser: SkillParser = SkillParser()) throws -> URL {
        let normalizedName = try SkillWorkshopSkillNameNormalizer.normalize(change.skillName)
        let content = try previewContent(for: change, normalizedName: normalizedName, fileManager: fileManager)
        let scan = SkillWorkshopContentScanner.scan(content)
        guard !scan.hasCritical else {
            throw SkillWorkshopWriterError.parseValidationFailed("critical scan findings")
        }
        let skillDir = try skillDirectoryURL(for: normalizedName)
        try fileManager.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        try MemoryFileLock.atomicWrite(text: content, to: skillFile, fileManager: fileManager)
        _ = try parser.parse(skillFileURL: skillFile)
        return skillFile
    }

    private func skillDirectoryURL(for normalizedName: String, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        let dir = skillsRoot.appendingPathComponent(normalizedName, isDirectory: true)
        guard WorkspacePathPolicy.isPathInsideRoot(dir.path, root: skillsRoot.standardizedFileURL.path) else {
            throw SkillWorkshopWriterError.pathEscape
        }
        return dir
    }

    private func readSkillFile(normalizedName: String, fileManager: FileManager) throws -> String? {
        let dir = try skillDirectoryURL(for: normalizedName)
        let file = dir.appendingPathComponent("SKILL.md")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func composeSkillMarkdown(name: String, description: String, body: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private func appendSection(
        to existing: String?,
        sectionName: String,
        content: String,
        normalizedName: String,
        title: String,
        description: String
    ) throws -> String {
        if existing == nil {
            let base = composeSkillMarkdown(
                name: normalizedName,
                description: description,
                body: "## \(sectionName)\n\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
            return base
        }
        guard var text = existing else { return "" }
        let header = "## \(sectionName)"
        if text.contains(header) {
            if !text.hasSuffix("\n") { text.append("\n") }
            text.append("\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n")
            return text
        }
        if !text.hasSuffix("\n") { text.append("\n") }
        text.append("\n## \(sectionName)\n\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n")
        return text
    }
}
