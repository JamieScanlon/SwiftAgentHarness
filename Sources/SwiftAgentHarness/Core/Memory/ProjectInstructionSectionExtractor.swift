import Foundation

enum ProjectInstructionSectionExtractor: Sendable {
    static let defaultPostCompactionSectionNames = ["Session Startup", "Red Lines"]
    static let legacyPostCompactionSectionNames = ["Every Session", "Safety"]

    /// Case-insensitive multiset match for configured default section names (order-independent).
    static func matchesDefaultSectionSet(_ sectionNames: [String]) -> Bool {
        let expected = defaultPostCompactionSectionNames
        guard sectionNames.count == expected.count else { return false }

        var counts: [String: Int] = [:]
        for name in expected {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            counts[normalized, default: 0] += 1
        }
        for name in sectionNames {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let count = counts[normalized], count > 0 else { return false }
            if count == 1 {
                counts.removeValue(forKey: normalized)
            } else {
                counts[normalized] = count - 1
            }
        }
        return counts.isEmpty
    }

    /// Extract named H2/H3 sections from markdown. Headings are matched case-insensitively.
    /// Content inside fenced code blocks is not scanned for headings.
    static func extractSections(
        from content: String,
        sectionNames: [String],
        foundNames: inout [String]
    ) -> [String] {
        var results: [String] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for name in sectionNames {
            var sectionLines: [String] = []
            var inSection = false
            var sectionLevel = 0
            var inCodeBlock = false

            for line in lines {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    inCodeBlock.toggle()
                    if inSection { sectionLines.append(line) }
                    continue
                }

                if inCodeBlock {
                    if inSection { sectionLines.append(line) }
                    continue
                }

                if let heading = parseHeading(line) {
                    if !inSection {
                        if heading.text.caseInsensitiveCompare(name) == .orderedSame {
                            inSection = true
                            sectionLevel = heading.level
                            sectionLines = [line]
                        }
                    } else {
                        if heading.level <= sectionLevel {
                            break
                        }
                        sectionLines.append(line)
                    }
                    continue
                }

                if inSection {
                    sectionLines.append(line)
                }
            }

            if !sectionLines.isEmpty {
                results.append(sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                foundNames.append(name)
            }
        }

        return results
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: "^(#{2,3})\\s+(.+?)\\s*$") else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 2,
              let hashRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line)
        else { return nil }
        return (String(line[hashRange]).count, String(line[textRange]))
    }
}
