import CryptoKit
import EasyJSON
import Foundation
import SwiftAgentKitOrchestrator

/// Identifies a specific tool invocation for run-scoped `allow-once` approvals.
public struct ToolCallApprovalBinding: Hashable, Sendable, Codable, Equatable {
    public let toolName: String
    public let argumentsFingerprint: String

    public init(toolName: String, argumentsFingerprint: String) {
        self.toolName = toolName
        self.argumentsFingerprint = argumentsFingerprint
    }

    static func from(invocation request: ToolInvocationRequest) -> Self {
        from(toolName: request.toolName, arguments: orchestratorPolicyArguments(for: request))
    }

    static func orchestratorPolicyArguments(for request: ToolInvocationRequest) -> JSON {
        if request.argumentMode == .raw, let envelope = request.rawEnvelope {
            return .object([
                "envelopeVersion": .string(envelope.envelopeVersion),
                "rawText": .string(envelope.rawText),
                "commandToken": envelope.commandToken.map(JSON.string) ?? .string(""),
                "commandName": envelope.commandName.map(JSON.string) ?? .string(""),
                "argsText": envelope.argsText.map(JSON.string) ?? .string(""),
                "parsedTokens": .array((envelope.parsedTokens ?? []).map(JSON.string)),
            ])
        }
        return request.argumentsPayload
    }

    static func from(call: ToolCallRequest) -> Self {
        Self(
            toolName: ToolNamePolicyNormalization.canonical(call.name),
            argumentsFingerprint: argumentsFingerprint(arguments: call.arguments)
        )
    }

    public static func from(toolName: String, arguments: JSON) -> Self {
        Self(
            toolName: ToolNamePolicyNormalization.canonical(toolName),
            argumentsFingerprint: argumentsFingerprint(arguments: arguments)
        )
    }

    public static func argumentsFingerprint(arguments: JSON) -> String {
        let canonical = canonicalJSONString(arguments)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func matches(call: ToolCallRequest) -> Bool {
        Self.from(call: call) == self
    }

    private static func canonicalJSONString(_ json: JSON) -> String {
        switch json {
        case .boolean(let value):
            return value ? "true" : "false"
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .string(let value):
            return encodeJSONString(value)
        case .array(let values):
            let encoded = values.map { canonicalJSONString($0) }.joined(separator: ",")
            return "[\(encoded)]"
        case .object(let fields):
            let encoded = fields.keys.sorted().map { key in
                "\(encodeJSONString(key)):\(canonicalJSONString(fields[key] ?? .object([:])))"
            }.joined(separator: ",")
            return "{\(encoded)}"
        }
    }

    private static func encodeJSONString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

enum ToolCallApprovalPolicy {
    static func isBindingPreApproved(
        call: ToolCallRequest,
        configuration: AgentRuntimeTurnConfiguration
    ) -> Bool {
        configuration.preApprovedCallBindings.contains(where: { $0.matches(call: call) })
    }

    static func isBindingPreApproved(
        call: ToolCallRequest,
        configuration: HarnessRuntimeSession.Configuration
    ) -> Bool {
        configuration.preApprovedCallBindings.contains(where: { $0.matches(call: call) })
    }

    static func isDurableNamePreApproved(
        call: ToolCallRequest,
        configuration: AgentRuntimeTurnConfiguration
    ) -> Bool {
        ToolNamePolicyNormalization.setContains(configuration.preApprovedToolNames, name: call.name)
    }

    static func isDurableNamePreApproved(
        call: ToolCallRequest,
        configuration: HarnessRuntimeSession.Configuration
    ) -> Bool {
        ToolNamePolicyNormalization.setContains(configuration.preApprovedToolNames, name: call.name)
    }

    static func isDurableRulePreApproved(
        call: ToolCallRequest,
        entry: ToolRegistryEntry?,
        configuration: AgentRuntimeTurnConfiguration,
        groupIndex: ToolPolicyGroupIndex,
        nameIndex: ToolRegistryNameIndex = .builtIn
    ) -> Bool {
        guard let entry else { return false }
        return configuration.preApprovedToolRules.contains { rule in
            ToolPolicyCallMatcher.matches(
                rule: rule,
                entry: entry,
                arguments: call.arguments,
                groupIndex: groupIndex,
                nameIndex: nameIndex
            )
        }
    }

    static func isPreApproved(
        call: ToolCallRequest,
        configuration: AgentRuntimeTurnConfiguration,
        entry: ToolRegistryEntry? = nil,
        groupIndex: ToolPolicyGroupIndex = .empty,
        nameIndex: ToolRegistryNameIndex = .builtIn
    ) -> Bool {
        isBindingPreApproved(call: call, configuration: configuration)
            || isDurableNamePreApproved(call: call, configuration: configuration)
            || isDurableRulePreApproved(
                call: call,
                entry: entry,
                configuration: configuration,
                groupIndex: groupIndex,
                nameIndex: nameIndex
            )
    }

    static func isPreApproved(
        call: ToolCallRequest,
        configuration: HarnessRuntimeSession.Configuration,
        entry: ToolRegistryEntry? = nil,
        groupIndex: ToolPolicyGroupIndex = .empty,
        nameIndex: ToolRegistryNameIndex = .builtIn
    ) -> Bool {
        isBindingPreApproved(call: call, configuration: configuration)
            || isDurableNamePreApproved(call: call, configuration: configuration)
            || configuration.preApprovedToolRules.contains { rule in
                guard let entry else { return rule.isNameLevelRule && rule.canonicalToolName != nil }
                return ToolPolicyCallMatcher.matches(
                    rule: rule,
                    entry: entry,
                    arguments: call.arguments,
                    groupIndex: groupIndex,
                    nameIndex: nameIndex
                )
            }
    }
}

enum ToolApprovalResolutionError: Error, Sendable, Equatable {
    case ambiguousPendingApproval(toolName: String, pendingCount: Int)
    case pendingApprovalNotFound(toolName: String)
}
