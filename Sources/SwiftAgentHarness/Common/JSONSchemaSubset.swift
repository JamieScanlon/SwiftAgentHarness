import EasyJSON
import Foundation

/// Validates a value against the subset of JSON Schema a task's return schema uses: `type`, `enum`, `const`,
/// `properties`, `required`, `additionalProperties: false`, `items`, and the numeric, length, and count bounds.
/// Keywords outside the subset are ignored rather than failing the value.
enum JSONSchemaSubset {
    /// Every way `value` fails `schema`, each prefixed with its JSON path. Empty when it matches.
    static func problems(_ value: JSON, against schema: JSON, path: String = "$") -> [String] {
        guard case .object(let rules) = schema else { return [] }
        var problems: [String] = []
        if let types = typeNames(rules["type"]), !types.contains(where: { matches(value, type: $0) }) {
            return ["\(path): expected \(types.joined(separator: " or ")), got \(typeName(value))"]
        }
        if case .array(let allowed)? = rules["enum"], !allowed.contains(where: { equal($0, value) }) {
            problems.append("\(path): not one of the allowed values")
        }
        if let constant = rules["const"], !equal(constant, value) {
            problems.append("\(path): not the required value")
        }
        switch value {
        case .object(let fields):
            if case .array(let required)? = rules["required"] {
                for case .string(let name) in required where fields[name] == nil {
                    problems.append("\(path): missing required \(name)")
                }
            }
            let properties: [String: JSON]
            if case .object(let declared)? = rules["properties"] { properties = declared } else { properties = [:] }
            for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
                if let rule = properties[name] {
                    problems += self.problems(field, against: rule, path: "\(path).\(name)")
                } else if case .boolean(false)? = rules["additionalProperties"] {
                    problems.append("\(path): unexpected property \(name)")
                } else if case .object? = rules["additionalProperties"], let rule = rules["additionalProperties"] {
                    problems += self.problems(field, against: rule, path: "\(path).\(name)")
                }
            }
        case .array(let items):
            if let minimum = int(rules["minItems"]), items.count < minimum { problems.append("\(path): fewer than \(minimum) items") }
            if let maximum = int(rules["maxItems"]), items.count > maximum { problems.append("\(path): more than \(maximum) items") }
            if let rule = rules["items"] {
                for (index, item) in items.enumerated() {
                    problems += self.problems(item, against: rule, path: "\(path)[\(index)]")
                }
            }
        case .string(let text):
            if let minimum = int(rules["minLength"]), text.count < minimum { problems.append("\(path): shorter than \(minimum)") }
            if let maximum = int(rules["maxLength"]), text.count > maximum { problems.append("\(path): longer than \(maximum)") }
        case .integer, .double:
            let number = double(value) ?? 0
            if let minimum = double(rules["minimum"]), number < minimum { problems.append("\(path): below \(minimum)") }
            if let maximum = double(rules["maximum"]), number > maximum { problems.append("\(path): above \(maximum)") }
        case .boolean:
            break
        }
        return problems
    }

    private static func typeNames(_ json: JSON?) -> [String]? {
        switch json {
        case .string(let name)?: return [name]
        case .array(let names)?: return names.compactMap { if case .string(let name) = $0 { return name } else { return nil } }
        default: return nil
        }
    }

    private static func matches(_ value: JSON, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .boolean), ("integer", .integer): return true
        case ("integer", .double(let number)): return number.rounded() == number
        case ("number", .integer), ("number", .double): return true
        default: return false
        }
    }

    private static func typeName(_ value: JSON) -> String {
        switch value {
        case .object: "object"
        case .array: "array"
        case .string: "string"
        case .boolean: "boolean"
        case .integer: "integer"
        case .double: "number"
        }
    }

    private static func equal(_ lhs: JSON, _ rhs: JSON) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }

    private static func int(_ json: JSON?) -> Int? {
        switch json {
        case .integer(let value)?: value
        case .double(let value)? where value.rounded() == value: Int(value)
        default: nil
        }
    }

    private static func double(_ json: JSON?) -> Double? {
        switch json {
        case .integer(let value)?: Double(value)
        case .double(let value)?: value
        default: nil
        }
    }
}
