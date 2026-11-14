import EasyJSON
import Foundation
import SwiftAgentKit

/// A tool-call id that also names the vendor response it came from, as `<call id>@<response id>`.
///
/// OpenAI's and Gemini's computer-use APIs continue a turn from the stored response (`previous_response_id`,
/// `previous_interaction_id`) rather than from replayed history, because their calls depend on reasoning state the
/// client never sees. The response id rides on the call ids the conversation already keeps, so a turn can be
/// continued after a restart.
struct ChainedProviderCall: Sendable, Hashable {
    static let separator: Character = "@"

    var callID: String
    var responseID: String?

    init(callID: String, responseID: String?) {
        self.callID = callID
        self.responseID = responseID
    }

    init(_ toolCallID: String) {
        guard let index = toolCallID.lastIndex(of: Self.separator) else {
            self.init(callID: toolCallID, responseID: nil)
            return
        }
        let responseID = String(toolCallID[toolCallID.index(after: index)...])
        self.init(callID: String(toolCallID[..<index]), responseID: responseID.isEmpty ? nil : responseID)
    }

    var toolCallID: String {
        responseID.map { "\(callID)\(Self.separator)\($0)" } ?? callID
    }

    /// The latest assistant turn whose calls name a response, and that response: the turn a request continues from.
    static func chain(in messages: [Message]) -> (index: Int, responseID: String)? {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }),
              let responseID = messages[index].toolCalls.lazy.compactMap({ $0.id.flatMap { ChainedProviderCall($0).responseID } }).first
        else { return nil }
        return (index, responseID)
    }
}

/// HTTP status handling shared by the JSON vendor codecs.
enum ProviderHTTPStatus {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let liveTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.networkError(URLError(.badServerResponse)) }
        return (data, http)
    }

    static func validate(_ response: HTTPURLResponse, body: Data, provider: String) throws {
        switch response.statusCode {
        case 200...299: return
        case 408, 504: throw LLMError.timeout
        case 429: throw LLMError.rateLimitExceeded
        case 401, 403: throw LLMError.authenticationFailed
        case 404: throw LLMError.modelNotFound("\(provider) HTTP 404")
        case 500...599: throw LLMError.networkError(URLError(.badServerResponse))
        default:
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw LLMError.invalidRequest("\(provider) HTTP \(response.statusCode): \(message)")
        }
    }

    static func dataURL(_ image: Message.Image) -> String? {
        guard let data = image.imageData else { return nil }
        return "data:\(image.mediaType ?? "image/png");base64,\(data.base64EncodedString())"
    }

    static func encode(_ json: JSON) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(json)
    }

    static func decode(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    /// A tool's parameter schema as JSON: the registered raw schema when there is one, else one built from its
    /// parameters.
    static func parameterSchema(_ tool: ToolDefinition, raw: JSON?) -> JSON {
        if let raw { return raw }
        var properties: [String: JSON] = [:]
        for parameter in tool.parameters {
            properties[parameter.name] = .object(["type": .string(parameter.type), "description": .string(parameter.description)])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(tool.parameters.filter(\.required).map { .string($0.name) }),
        ])
    }
}
