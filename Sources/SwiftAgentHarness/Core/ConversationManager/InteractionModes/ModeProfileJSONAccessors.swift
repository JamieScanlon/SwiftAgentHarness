import EasyJSON

extension JSON {
    var objectFields: [String: JSON]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }
}

extension Dictionary where Key == String, Value == JSON {
    func optionalString(for key: String) -> String? {
        guard let value = self[key] else { return nil }
        guard case .string(let text) = value else { return nil }
        return text
    }

    func optionalBool(for key: String) -> Bool? {
        guard let value = self[key] else { return nil }
        guard case .boolean(let flag) = value else { return nil }
        return flag
    }

    func optionalInt(for key: String) -> Int? {
        guard let value = self[key] else { return nil }
        switch value {
        case .integer(let number):
            return number
        case .double(let number):
            return Int(number)
        default:
            return nil
        }
    }

    func optionalDouble(for key: String) -> Double? {
        guard let value = self[key] else { return nil }
        switch value {
        case .double(let number):
            return number
        case .integer(let number):
            return Double(number)
        default:
            return nil
        }
    }

    func stringArray(for key: String) -> [String]? {
        guard let value = self[key] else { return nil }
        guard case .array(let array) = value else { return nil }
        return array.compactMap {
            guard case .string(let text) = $0 else { return nil }
            return text
        }
    }

    func stringArrayOrEmpty(for key: String) -> [String] {
        stringArray(for: key) ?? []
    }
}

enum ModeProfileJSONParsing {
    static func normalizedStringArray(from value: JSON?) -> [String]? {
        guard let value else { return nil }
        guard case .array(let array) = value else { return nil }
        let mapped = array.compactMap { item -> String? in
            guard case .string(let text) = item else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return mapped.isEmpty ? [] : mapped
    }

    static func normalizedSubAgentAllowList(
        raw: JSON?,
        profileID: String,
        diagnostics: inout [String]
    ) -> [String] {
        guard let raw else {
            diagnostics.append("modeProfiles[\(profileID)].subAgents.allow must be '*' or [String]")
            return []
        }
        if case .string(let wildcard) = raw {
            let trimmed = wildcard.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "*" {
                return ["*"]
            }
            diagnostics.append("modeProfiles[\(profileID)].subAgents.allow must be '*' or [String]")
            return []
        }
        if case .array(let values) = raw {
            let normalized = values
                .compactMap { item -> String? in
                    guard case .string(let text) = item else { return nil }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            if normalized.count != values.count {
                diagnostics.append("modeProfiles[\(profileID)].subAgents.allow must contain only strings")
            }
            if normalized.contains("*") {
                return ["*"]
            }
            return Array(Set(normalized)).sorted()
        }
        diagnostics.append("modeProfiles[\(profileID)].subAgents.allow must be '*' or [String]")
        return []
    }

    static func normalizedHookIDList(from raw: JSON?) -> [String] {
        guard let raw, case .array(let items) = raw else { return [] }
        return items.compactMap { item -> String? in
            guard case .string(let text) = item else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
