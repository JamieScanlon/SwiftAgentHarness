import EasyJSON
import Foundation
import OpenAI

enum ToolSchemaWireCodec {
    static func foundationObject(from json: JSON) -> Any? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func openAIJSONSchema(from json: JSON) -> JSONSchema? {
        guard let object = foundationObject(from: json) as? [String: Any] else { return nil }
        return .object(anyJSONDocuments(from: object))
    }

    static func anthropicInputSchema(from json: JSON) -> [String: Any] {
        foundationObject(from: json) as? [String: Any] ?? [:]
    }

    private static func anyJSONDocuments(from object: [String: Any]) -> [String: AnyJSONDocument] {
        object.mapValues { anyJSONDocument(from: $0) }
    }

    private static func anyJSONDocument(from value: Any) -> AnyJSONDocument {
        switch value {
        case let dictionary as [String: Any]:
            return .init(dictionary.mapValues { anyJSONDocument(from: $0) })
        case let array as [Any]:
            return .init(array.map { anyJSONDocument(from: $0) })
        case let string as String:
            return .init(string)
        case let bool as Bool:
            return .init(bool)
        case let int as Int:
            return .init(int)
        case let double as Double:
            return .init(double)
        default:
            return .init(String(describing: value))
        }
    }
}
