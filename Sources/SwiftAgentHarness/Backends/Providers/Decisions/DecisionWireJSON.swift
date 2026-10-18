import EasyJSON
import Foundation

/// JSON with ordered object keys, used to write wire bodies so question order and ids stay stable.
indirect enum WireJSON: Sendable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([WireJSON])
    case object([(String, WireJSON)])

    static func == (lhs: WireJSON, rhs: WireJSON) -> Bool {
        lhs.serialized() == rhs.serialized()
    }

    /// EasyJSON objects are unordered; their keys are written sorted for stable bodies.
    init(_ json: JSON) {
        switch json {
        case .string(let value): self = .string(value)
        case .double(let value): self = .number(value)
        case .integer(let value): self = .integer(value)
        case .boolean(let value): self = .bool(value)
        case .array(let values): self = .array(values.map(WireJSON.init))
        case .object(let object):
            self = .object(object.keys.sorted().map { ($0, WireJSON(object[$0]!)) })
        }
    }

    func serialized() -> Data {
        var output = ""
        write(into: &output)
        return Data(output.utf8)
    }

    private func write(into output: inout String) {
        switch self {
        case .string(let value):
            output += Self.quote(value)
        case .number(let value):
            output += value.isFinite ? Self.formatNumber(value) : "null"
        case .integer(let value):
            output += String(value)
        case .bool(let value):
            output += value ? "true" : "false"
        case .null:
            output += "null"
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                value.write(into: &output)
            }
            output += "]"
        case .object(let pairs):
            output += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { output += "," }
                output += Self.quote(pair.0)
                output += ":"
                pair.1.write(into: &output)
            }
            output += "}"
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

enum DecisionEntryText {
    /// Strings pass through; objects and arrays become stable, pretty-printed JSON.
    static func text(_ entry: DecisionEntry) -> String {
        if case .string(let value) = entry { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(entry)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// Read helpers over decoded EasyJSON responses.
extension JSON {
    subscript(wire key: String) -> JSON? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var wireObject: [String: JSON]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var wireArray: [JSON]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var wireString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var wireNumber: Double? {
        switch self {
        case .double(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    var wireInt: Int? {
        switch self {
        case .integer(let value): return value
        case .double(let value) where value == value.rounded(): return Int(value)
        default: return nil
        }
    }
}
