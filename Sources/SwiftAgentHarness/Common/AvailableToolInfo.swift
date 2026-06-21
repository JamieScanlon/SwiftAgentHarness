import Foundation

/// Origin of a tool for UI listing (coarse; unknown when not classifiable).
public enum ToolListingSource: String, Codable, Sendable, Equatable {
    case local
    case mcp
    case a2a
    case unknown
}

/// One tool row for REST `GET /api/tools` (global catalog) and `GET /api/conversations/{id}/tools` (effective list).
public struct AvailableToolInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let source: ToolListingSource
    /// Normalized schema fingerprint emitted by canonical tool registration.
    public let normalizedSchemaFingerprint: String?
    /// Normalizer version emitted by canonical tool registration.
    public let normalizedSchemaVersion: String?
    /// Normalized top-level schema type summary.
    public let normalizedTopLevelType: String?
    /// Required parameter count from normalized schema summary.
    public let normalizedRequiredCount: Int?
    /// Properties count from normalized schema summary.
    public let normalizedPropertyCount: Int?

    public init(
        name: String,
        description: String,
        source: ToolListingSource,
        normalizedSchemaFingerprint: String? = nil,
        normalizedSchemaVersion: String? = nil,
        normalizedTopLevelType: String? = nil,
        normalizedRequiredCount: Int? = nil,
        normalizedPropertyCount: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.normalizedSchemaFingerprint = normalizedSchemaFingerprint
        self.normalizedSchemaVersion = normalizedSchemaVersion
        self.normalizedTopLevelType = normalizedTopLevelType
        self.normalizedRequiredCount = normalizedRequiredCount
        self.normalizedPropertyCount = normalizedPropertyCount
    }
}
