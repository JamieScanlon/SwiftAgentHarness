import EasyJSON
import Foundation
import Logging

public enum PromptConfigDocumentError: Error, Sendable, Equatable {
    case invalidRoot
}

/// Typed root for a host-supplied PromptConfig.json, parsed once from bytes.
public struct PromptConfigDocument: Sendable {
    /// Top-level keys recognized by the harness. Unknown keys are retained in ``unknownTopLevelKeys``.
    public static let knownTopLevelKeys: Set<String> = [
        "options",
        "settings",
        "agentHarness",
        "toolPolicy",
        "subAgentHostingPolicy",
        "modeProfiles",
        "memory",
        "trustPolicy",
        "conversationTransforms",
        "publishingGovernance",
        "skillWorkshop",
        "lineagePromptSections",
        "subAgentCustomEndpoints",
    ]

    /// EasyJSON root (always an object for a successful parse).
    public let root: JSON
    /// Original bytes used for Foundation-dictionary section parsers.
    public let rawData: Data
    /// Unknown top-level keys discovered at parse time (sorted).
    public let unknownTopLevelKeys: [String]

    public static let empty: PromptConfigDocument = {
        // Safe: `{}` is always a valid empty PromptConfig document.
        try! PromptConfigDocument.parse(data: Data("{}".utf8))
    }()

    public static func parse(data: Data, logger: Logger? = nil) throws -> PromptConfigDocument {
        let root = try JSONDecoder().decode(JSON.self, from: data)
        guard case .object(let fields) = root else {
            throw PromptConfigDocumentError.invalidRoot
        }
        let unknown = fields.keys.filter { !knownTopLevelKeys.contains($0) }.sorted()
        if !unknown.isEmpty {
            logger?.warning(
                "Unknown PromptConfig top-level keys: \(unknown.joined(separator: ", "))"
            )
        }
        return PromptConfigDocument(
            root: root,
            rawData: data,
            unknownTopLevelKeys: unknown
        )
    }

    public static func parse(url: URL, logger: Logger? = nil) throws -> PromptConfigDocument {
        let data = try Data(contentsOf: url)
        return try parse(data: data, logger: logger)
    }

    // MARK: - Section accessors (EasyJSON)

    public var options: JSON? { objectValue(for: "options") }
    public var settings: JSON? { objectValue(for: "settings") }
    public var agentHarness: JSON? { objectValue(for: "agentHarness") }
    public var toolPolicy: JSON? { objectValue(for: "toolPolicy") }
    public var subAgentHostingPolicy: JSON? { objectValue(for: "subAgentHostingPolicy") }
    public var modeProfiles: JSON? { value(for: "modeProfiles") }
    public var memory: JSON? { objectValue(for: "memory") }
    public var trustPolicy: JSON? { objectValue(for: "trustPolicy") }
    public var conversationTransforms: JSON? { objectValue(for: "conversationTransforms") }
    public var publishingGovernance: JSON? { objectValue(for: "publishingGovernance") }
    public var skillWorkshop: JSON? { objectValue(for: "skillWorkshop") }
    public var lineagePromptSections: JSON? { objectValue(for: "lineagePromptSections") }
    public var subAgentCustomEndpoints: JSON? { objectValue(for: "subAgentCustomEndpoints") }

    // MARK: - Foundation bridge for existing section parsers

    /// Full root as Foundation JSON. Derived from the same ``rawData`` (not a second ambient read).
    public func foundationRoot() -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
    }

    public func foundationObject(forKey key: String) -> [String: Any]? {
        foundationRoot()?[key] as? [String: Any]
    }

    // MARK: - Internals

    private func value(for key: String) -> JSON? {
        guard case .object(let fields) = root else { return nil }
        return fields[key]
    }

    private func objectValue(for key: String) -> JSON? {
        guard let value = value(for: key), case .object = value else { return nil }
        return value
    }
}
