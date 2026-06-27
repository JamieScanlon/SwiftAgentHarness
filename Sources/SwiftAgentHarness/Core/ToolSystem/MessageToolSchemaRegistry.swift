import EasyJSON
import Foundation
import SwiftAgentKit

/// Action-keyed extra parameters a channel contributes to the shared `message` tool schema.
public struct MessageToolMediaParamDescriptor: Sendable, Equatable, Codable {
    public var name: String
    public var type: String
    public var description: String
    public var required: Bool

    public init(name: String, type: String, description: String, required: Bool = false) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

public struct MessageToolActionSchema: Sendable, Equatable {
    public var action: String
    public var mediaParams: [MessageToolMediaParamDescriptor]

    public init(action: String, mediaParams: [MessageToolMediaParamDescriptor]) {
        self.action = action
        self.mediaParams = mediaParams
    }
}

/// Registry of channel `describeMessageTool` contributions merged into the core tool schema.
public enum MessageToolSchemaRegistry {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var actionSchemas: [MessageToolActionSchema] = []

        func set(_ schemas: [MessageToolActionSchema]) {
            lock.lock()
            defer { lock.unlock() }
            actionSchemas = schemas
        }

        func snapshot() -> [MessageToolActionSchema] {
            lock.lock()
            defer { lock.unlock() }
            return actionSchemas
        }
    }

    private static let state = State()

    public static func register(actionSchemas: [MessageToolActionSchema]) {
        state.set(actionSchemas)
    }

    public static func mergedRawSchema(base: JSON) -> JSON {
        let extras = state.snapshot().flatMap(\.mediaParams)
        guard !extras.isEmpty else { return base }
        guard case .object(var root) = base,
              case .object(var properties) = root["properties"] ?? .object([:]) else {
            return base
        }
        var mediaProps: [String: JSON] = [:]
        var requiredMedia: [JSON] = []
        for param in extras {
            mediaProps[param.name] = .object([
                "type": .string(param.type),
                "description": .string(param.description),
            ])
            if param.required {
                requiredMedia.append(.string(param.name))
            }
        }
        properties["media"] = .object([
            "type": .string("object"),
            "description": .string("Platform-specific media parameters declared by the active channel."),
            "properties": .object(mediaProps),
        ])
        root["properties"] = .object(properties)
        if !requiredMedia.isEmpty {
            var required = (root["required"]?.arrayValue ?? []).map { $0 }
            required.append(contentsOf: requiredMedia)
            root["required"] = .array(required)
        }
        return .object(root)
    }
}

private extension JSON {
    var arrayValue: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
