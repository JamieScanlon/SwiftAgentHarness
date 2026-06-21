import Foundation

/// One skill row for REST skill registry reads (Agent Skills directory name + description).
public struct AvailableSkillInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}
