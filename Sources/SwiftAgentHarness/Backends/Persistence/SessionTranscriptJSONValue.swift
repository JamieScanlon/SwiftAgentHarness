//
//  JSON-primitive values for README `details: dict | None` on transcript auxiliary payloads.
//

import Foundation

/// JSON-safe value used for optional **`details`** objects on harness README-shaped transcript rows.
public enum SessionTranscriptJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([SessionTranscriptJSONValue])
    case object([String: SessionTranscriptJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? c.decode(Int.self) {
            self = .int(Int64(i))
            return
        }
        if let i = try? c.decode(Int64.self) {
            self = .int(i)
            return
        }
        if let d = try? c.decode(Double.self) {
            self = .double(d)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? c.decode([SessionTranscriptJSONValue].self) {
            self = .array(a)
            return
        }
        if let o = try? c.decode([String: SessionTranscriptJSONValue].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON fragment")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:
            try c.encodeNil()
        case let .bool(b):
            try c.encode(b)
        case let .int(i):
            try c.encode(i)
        case let .double(d):
            try c.encode(d)
        case let .string(s):
            try c.encode(s)
        case let .array(a):
            try c.encode(a)
        case let .object(o):
            try c.encode(o)
        }
    }
}
