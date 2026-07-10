import Foundation

enum SkillWorkshopSkillNameNormalizer {
    static let maxLength = 64
    private static let validPattern = #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#

    static func normalize(_ raw: String) throws -> String {
        var normalized = raw.lowercased()
        normalized = normalized.replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if normalized.count > maxLength {
            normalized = String(normalized.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        guard !normalized.isEmpty,
              normalized.range(of: validPattern, options: .regularExpression) != nil else {
            throw SkillWorkshopWriterError.invalidSkillName(raw)
        }
        return normalized
    }
}
