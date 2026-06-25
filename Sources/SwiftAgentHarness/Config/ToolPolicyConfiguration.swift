import Foundation
import Logging

// MARK: - Tool policy (PromptConfig.json)

/// Tool-system policy from `PromptConfig` (approval/escalation/dispatch/env/sub-agent hosting).
///
/// Configure the `toolPolicy` object in **PromptConfig.json** (bundled with the server target). Examples,
/// key reference, and interaction with conversation routing policy (`routingPrefs.explicitToolPolicy`)
/// follow in the comments below.
///
/// **Quick reference**
/// - Omit `toolPolicy` entirely → no restriction (all registered tools eligible, before user overrides).
/// - Runtime context path (`ModePolicyContext`) now uses ``ResolvedModeProfile.tools`` as canonical mode allow/deny ownership.
///
/// Reload the server after editing ``PromptConfig`` so changes take effect.
public struct ToolPolicyConfiguration: Sendable {
    public enum DispatchPlannerMode: String, Sendable, Codable, Equatable {
        case serial
        case allParallel
        case mixedDeterministic
    }

    public enum DescriptorValidationMode: String, Sendable, Codable, Equatable {
        case warning
        case strict
    }

    public enum ApprovalTimeoutBehavior: String, Sendable, Codable, Equatable {
        case autoDeny
        case autoApprove
    }

    public enum ElevatedExecutionPolicy: String, Sendable, Codable, Equatable {
        case privilegedDispatch
    }

    public enum ExecutionEnvironmentKind: String, Sendable, Codable, Equatable, CaseIterable {
        case local
        case docker
        case ssh
        case mcp
        case a2a
        case unknown
    }

    public struct ExecutionEnvironmentPolicy: Sendable, Equatable {
        public var disallowed: Set<ExecutionEnvironmentKind>
        public var approvalRequired: Set<ExecutionEnvironmentKind>
        public var escalationRequired: Set<ExecutionEnvironmentKind>
        public var disallowedAdapterIDs: Set<String>
        public var approvalRequiredAdapterIDs: Set<String>
        public var escalationRequiredAdapterIDs: Set<String>

        public static let unrestricted = ExecutionEnvironmentPolicy(
            disallowed: [],
            approvalRequired: [],
            escalationRequired: [],
            disallowedAdapterIDs: [],
            approvalRequiredAdapterIDs: [],
            escalationRequiredAdapterIDs: []
        )

        public init(
            disallowed: Set<ExecutionEnvironmentKind> = [],
            approvalRequired: Set<ExecutionEnvironmentKind> = [],
            escalationRequired: Set<ExecutionEnvironmentKind> = [],
            disallowedAdapterIDs: Set<String> = [],
            approvalRequiredAdapterIDs: Set<String> = [],
            escalationRequiredAdapterIDs: Set<String> = []
        ) {
            self.disallowed = disallowed
            self.approvalRequired = approvalRequired
            self.escalationRequired = escalationRequired
            self.disallowedAdapterIDs = Set(
                disallowedAdapterIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            self.approvalRequiredAdapterIDs = Set(
                approvalRequiredAdapterIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            self.escalationRequiredAdapterIDs = Set(
                escalationRequiredAdapterIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
    }

    private let sensitiveToolNames: Set<String>
    private let escalationRequiredToolNames: Set<String>
    private let approvalRequiredToolNames: Set<String>
    private let elevatedToolNames: Set<String>
    private let perCallElevatedToolNames: Set<String>
    public let elevatedAllowFrom: ElevatedAllowlist
    private let subAgentHostingPolicyConfiguration: SubAgentHostingPolicyConfiguration
    public let descriptorValidationMode: DescriptorValidationMode
    /// Approval wait timeout in milliseconds. `nil` disables the timeout so the
    /// harness waits indefinitely for a user response (`autoDeny`/`autoApprove`
    /// only apply when a finite timeout is set).
    public let approvalTimeoutMilliseconds: Int?
    public let approvalTimeoutBehavior: ApprovalTimeoutBehavior
    public let approvalSeverityDefault: String
    public let approvalElevatedSeverityDefault: String
    public let elevatedExecutionPolicy: ElevatedExecutionPolicy
    public let executionEnvironmentPolicy: ExecutionEnvironmentPolicy
    public let parallelDispatchEnabled: Bool
    public let dispatchPlannerMode: DispatchPlannerMode?
    public let pendingToolTimeoutSeconds: TimeInterval?

    init(
        sensitiveToolNames: Set<String> = [],
        escalationRequiredToolNames: Set<String> = [],
        approvalRequiredToolNames: Set<String> = [],
        elevatedToolNames: Set<String> = [],
        perCallElevatedToolNames: Set<String> = [],
        elevatedAllowFrom: ElevatedAllowlist = .cliDefault,
        subAgentHostingPolicyConfiguration: SubAgentHostingPolicyConfiguration = .empty,
        descriptorValidationMode: DescriptorValidationMode = .warning,
        approvalTimeoutMilliseconds: Int? = 120_000,
        approvalTimeoutBehavior: ApprovalTimeoutBehavior = .autoDeny,
        approvalSeverityDefault: String = "medium",
        approvalElevatedSeverityDefault: String = "high",
        elevatedExecutionPolicy: ElevatedExecutionPolicy = .privilegedDispatch,
        executionEnvironmentPolicy: ExecutionEnvironmentPolicy = .unrestricted,
        parallelDispatchEnabled: Bool = false,
        dispatchPlannerMode: DispatchPlannerMode? = nil,
        pendingToolTimeoutSeconds: TimeInterval? = nil
    ) {
        self.sensitiveToolNames = sensitiveToolNames
        self.escalationRequiredToolNames = escalationRequiredToolNames
        self.approvalRequiredToolNames = approvalRequiredToolNames
        self.elevatedToolNames = elevatedToolNames
        self.perCallElevatedToolNames = perCallElevatedToolNames
        self.elevatedAllowFrom = elevatedAllowFrom
        self.subAgentHostingPolicyConfiguration = subAgentHostingPolicyConfiguration
        self.descriptorValidationMode = descriptorValidationMode
        self.approvalTimeoutMilliseconds = approvalTimeoutMilliseconds.map { max(1_000, $0) }
        self.approvalTimeoutBehavior = approvalTimeoutBehavior
        self.approvalSeverityDefault = approvalSeverityDefault.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "medium"
            : approvalSeverityDefault
        self.approvalElevatedSeverityDefault = approvalElevatedSeverityDefault.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "high"
            : approvalElevatedSeverityDefault
        self.elevatedExecutionPolicy = elevatedExecutionPolicy
        self.executionEnvironmentPolicy = executionEnvironmentPolicy
        self.parallelDispatchEnabled = parallelDispatchEnabled
        self.dispatchPlannerMode = dispatchPlannerMode
        self.pendingToolTimeoutSeconds = pendingToolTimeoutSeconds
    }

    /// Unrestricted policy (used when `toolPolicy` is missing from JSON).
    public static let unrestricted = ToolPolicyConfiguration(
        sensitiveToolNames: [],
        escalationRequiredToolNames: [],
        approvalRequiredToolNames: [],
        elevatedToolNames: [],
        perCallElevatedToolNames: [],
        elevatedAllowFrom: .cliDefault,
        subAgentHostingPolicyConfiguration: .empty,
        descriptorValidationMode: .warning,
        approvalTimeoutMilliseconds: 120_000,
        approvalTimeoutBehavior: .autoDeny,
        approvalSeverityDefault: "medium",
        approvalElevatedSeverityDefault: "high",
        elevatedExecutionPolicy: .privilegedDispatch,
        executionEnvironmentPolicy: .unrestricted,
        parallelDispatchEnabled: false,
        dispatchPlannerMode: nil,
        pendingToolTimeoutSeconds: nil
    )

    /// Stable digest for system-prompt assembly fingerprinting (allowlist shape only).
    public func stableAllowlistSignature() -> String {
        Self.hostPolicySignature(
            sensitiveToolNames: sensitiveToolNames,
            escalationRequiredToolNames: escalationRequiredToolNames,
            approvalRequiredToolNames: approvalRequiredToolNames,
            elevatedToolNames: elevatedToolNames,
            perCallElevatedToolNames: perCallElevatedToolNames,
            elevatedAllowFrom: elevatedAllowFrom,
            subAgentHostingPolicyConfiguration: subAgentHostingPolicyConfiguration,
            descriptorValidationMode: descriptorValidationMode,
            approvalTimeoutMilliseconds: approvalTimeoutMilliseconds,
            approvalTimeoutBehavior: approvalTimeoutBehavior,
            approvalSeverityDefault: approvalSeverityDefault,
            approvalElevatedSeverityDefault: approvalElevatedSeverityDefault,
            elevatedExecutionPolicy: elevatedExecutionPolicy,
            executionEnvironmentPolicy: executionEnvironmentPolicy,
            parallelDispatchEnabled: parallelDispatchEnabled,
            dispatchPlannerMode: dispatchPlannerMode,
            pendingToolTimeoutSeconds: pendingToolTimeoutSeconds
        )
    }

    private static func hostPolicySignature(
        sensitiveToolNames: Set<String>,
        escalationRequiredToolNames: Set<String>,
        approvalRequiredToolNames: Set<String>,
        elevatedToolNames: Set<String>,
        perCallElevatedToolNames: Set<String>,
        elevatedAllowFrom: ElevatedAllowlist,
        subAgentHostingPolicyConfiguration: SubAgentHostingPolicyConfiguration,
        descriptorValidationMode: DescriptorValidationMode,
        approvalTimeoutMilliseconds: Int?,
        approvalTimeoutBehavior: ApprovalTimeoutBehavior,
        approvalSeverityDefault: String,
        approvalElevatedSeverityDefault: String,
        elevatedExecutionPolicy: ElevatedExecutionPolicy,
        executionEnvironmentPolicy: ExecutionEnvironmentPolicy,
        parallelDispatchEnabled: Bool,
        dispatchPlannerMode: DispatchPlannerMode?,
        pendingToolTimeoutSeconds: TimeInterval?
    ) -> String {
        let sensitiveSlice = "sensitive:\(sensitiveToolNames.sorted().joined(separator: ","))"
        let escalationSlice = "escalationRequired:\(escalationRequiredToolNames.sorted().joined(separator: ","))"
        let approvalSlice = "approvalRequired:\(approvalRequiredToolNames.sorted().joined(separator: ","))"
        let elevatedSlice = "elevated:\(elevatedToolNames.sorted().joined(separator: ","))"
        let perCallElevatedSlice = "elevatedPerCall:\(perCallElevatedToolNames.sorted().joined(separator: ","))"
        let allowFromParts = elevatedAllowFrom.allowFrom.keys.sorted().map { surface -> String in
            let ids = elevatedAllowFrom.allowFrom[surface]?.sorted().joined(separator: ",") ?? ""
            return "\(surface)=\(ids)"
        }
        let elevatedAllowFromSlice = "elevatedAllowFrom:\(allowFromParts.joined(separator: ";"))"
        let hostingSlice = "subAgentHosting:\(subAgentHostingPolicyConfiguration.stableSignature())"
        let descriptorValidation = "descriptorValidation:\(descriptorValidationMode.rawValue)"
        let approvalTimeoutSlice = "approvalTimeoutMs:\(approvalTimeoutMilliseconds.map(String.init) ?? "disabled")"
        let approvalTimeoutBehaviorSlice = "approvalTimeoutBehavior:\(approvalTimeoutBehavior.rawValue)"
        let approvalSeveritySlice = "approvalSeverity:\(approvalSeverityDefault)"
        let approvalElevatedSeveritySlice = "approvalElevatedSeverity:\(approvalElevatedSeverityDefault)"
        let elevatedExecutionPolicySlice = "elevatedExecutionPolicy:\(elevatedExecutionPolicy.rawValue)"
        let envPolicySlice = "environmentPolicy:disallow=\(executionEnvironmentPolicy.disallowed.map(\.rawValue).sorted().joined(separator: ","));approval=\(executionEnvironmentPolicy.approvalRequired.map(\.rawValue).sorted().joined(separator: ","));escalation=\(executionEnvironmentPolicy.escalationRequired.map(\.rawValue).sorted().joined(separator: ","));disallowAdapters=\(executionEnvironmentPolicy.disallowedAdapterIDs.sorted().joined(separator: ","));approvalAdapters=\(executionEnvironmentPolicy.approvalRequiredAdapterIDs.sorted().joined(separator: ","));escalationAdapters=\(executionEnvironmentPolicy.escalationRequiredAdapterIDs.sorted().joined(separator: ","))"
        let parallel = "parallel:\(parallelDispatchEnabled ? "enabled" : "disabled")"
        let planner = "planner:\(dispatchPlannerMode?.rawValue ?? "nil")"
        let timeout = "pendingTimeout:\(pendingToolTimeoutSeconds.map { String(format: "%.3f", $0) } ?? "nil")"
        return [
            sensitiveSlice,
            escalationSlice,
            approvalSlice,
            elevatedSlice,
            perCallElevatedSlice,
            elevatedAllowFromSlice,
            hostingSlice,
            descriptorValidation,
            approvalTimeoutSlice,
            approvalTimeoutBehaviorSlice,
            approvalSeveritySlice,
            approvalElevatedSeveritySlice,
            elevatedExecutionPolicySlice,
            envPolicySlice,
            parallel,
            planner,
            timeout,
        ]
            .joined(separator: "|")
    }

    func subAgentHostingPolicy(forDelegateToolName name: String) -> SubAgentHostingPolicy {
        subAgentHostingPolicyConfiguration.policy(forDelegateToolName: name)
    }

    func subAgentHostingPolicy(forHostPersonaID hostPersonaID: String) -> SubAgentHostingPolicy? {
        subAgentHostingPolicyConfiguration.policy(forHostPersonaID: hostPersonaID)
    }

    public func isToolAllowed(name: String, context: ModePolicyContext) -> Bool {
        return Self.profileToolsSliceAllows(context.resolvedProfile.tools, toolName: name)
    }

    public func isToolDenied(name: String, context: ModePolicyContext) -> Bool {
        Self.evalDenylist(context.resolvedProfile.tools.deny, toolName: name)
    }

    /// Composes PromptConfig approval tags with ``ModeProfileToolsSlice/approvalPolicy`` (`modes.md`).
    public func requiresApproval(
        toolName: String,
        context: ModePolicyContext,
        toolIsReadOnly: Bool,
        entryRequiresApprovalTag: Bool
    ) -> Bool {
        let base = requiresApproval(name: toolName) || entryRequiresApprovalTag
        guard let slicePolicy = context.resolvedProfile.tools.approvalPolicy else {
            return base
        }
        let sliceAdds: Bool = switch slicePolicy {
        case .never:
            false
        case .all:
            true
        case .sideEffects:
            !toolIsReadOnly
        }
        return base || sliceAdds
    }

    private static func profileToolsSliceAllows(_ slice: ModeProfileToolsSlice, toolName: String) -> Bool {
        guard let allow = slice.allow else { return true }
        return evalAllowlist(allow, toolName: toolName)
    }

    public func isToolSensitive(name: String) -> Bool {
        sensitiveToolNames.contains(name)
    }

    public func requiresEscalation(name: String) -> Bool {
        escalationRequiredToolNames.contains(name)
    }

    public func requiresApproval(name: String) -> Bool {
        approvalRequiredToolNames.contains(name)
    }

    public func isElevatedTool(name: String) -> Bool {
        elevatedToolNames.contains(name)
    }

    public func isPerCallElevatedTool(name: String) -> Bool {
        perCallElevatedToolNames.contains(name)
    }

    /// Per-call elevation mode for a tool: sandboxed by default, elevating only
    /// when a call opts in, governed by the exec-approval path and `allowFrom`.
    public func perCallElevationMode(name: String) -> ElevatedMode? {
        isPerCallElevatedTool(name: name) ? .ask : nil
    }

    public func isExecutionEnvironmentAllowed(kind: ExecutionEnvironmentKind) -> Bool {
        !executionEnvironmentPolicy.disallowed.contains(kind)
    }

    public func requiresExecutionEnvironmentApproval(kind: ExecutionEnvironmentKind) -> Bool {
        executionEnvironmentPolicy.approvalRequired.contains(kind)
    }

    public func requiresExecutionEnvironmentEscalation(kind: ExecutionEnvironmentKind) -> Bool {
        executionEnvironmentPolicy.escalationRequired.contains(kind)
    }

    public func isExecutionEnvironmentAdapterAllowed(adapterID: String?) -> Bool {
        guard let adapterID = adapterID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !adapterID.isEmpty else {
            return true
        }
        return !executionEnvironmentPolicy.disallowedAdapterIDs.contains(adapterID)
    }

    public func requiresExecutionEnvironmentAdapterApproval(adapterID: String?) -> Bool {
        guard let adapterID = adapterID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !adapterID.isEmpty else {
            return false
        }
        return executionEnvironmentPolicy.approvalRequiredAdapterIDs.contains(adapterID)
    }

    public func requiresExecutionEnvironmentAdapterEscalation(adapterID: String?) -> Bool {
        guard let adapterID = adapterID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !adapterID.isEmpty else {
            return false
        }
        return executionEnvironmentPolicy.escalationRequiredAdapterIDs.contains(adapterID)
    }

    private static func evalAllowlist(_ list: [String]?, toolName: String) -> Bool {
        guard let list else { return true }
        if list.isEmpty { return false }
        if list.contains("*") { return true }
        return list.contains(toolName)
    }

    private static func evalDenylist(_ list: [String]?, toolName: String) -> Bool {
        guard let list else { return false }
        if list.isEmpty { return false }
        if list.contains("*") { return true }
        return list.contains(toolName)
    }

    public static func loadFromPromptConfigBundle(logger: Logger? = nil) -> ToolPolicyConfiguration {
        guard let data = PromptConfigBundleResource.data() else {
            logger?.warning("PromptConfig.json not found; tool policy unrestricted")
            return .unrestricted
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unrestricted
        }
        guard let toolPolicy = json["toolPolicy"] as? [String: Any] else {
            return .unrestricted
        }
        let sensitiveToolNames = Set((toolPolicy["sensitive"] as? [String]) ?? [])
        let escalationRequiredToolNames = Set((toolPolicy["escalationRequired"] as? [String]) ?? [])
        let approvalRequiredToolNames = Set(
            (toolPolicy["requireApproval"] as? [String])
                ?? (toolPolicy["approvalRequired"] as? [String])
                ?? []
        )
        let parsedElevated = Self.parseElevatedBlock(toolPolicy["elevated"])
        let subAgentHostingPolicyConfiguration = SubAgentHostingPolicyConfiguration.fromPromptConfigRoot(json)
        let approvalBlock = toolPolicy["approval"] as? [String: Any]
        let descriptorValidationMode: DescriptorValidationMode = {
            guard let raw = toolPolicy["descriptorValidationMode"] as? String,
                  let mode = DescriptorValidationMode(
                    rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                  )
            else {
                return .warning
            }
            return mode
        }()
        // `timeoutMs: 0` (or any non-positive value) disables the timeout so the
        // approval waits indefinitely; absent/null keeps the default.
        let approvalTimeoutMilliseconds: Int? = {
            if let raw = approvalBlock?["timeoutMs"] as? Int {
                return raw <= 0 ? nil : max(1_000, raw)
            }
            if let raw = approvalBlock?["timeoutMs"] as? Double {
                return raw <= 0 ? nil : max(1_000, Int(raw))
            }
            return 120_000
        }()
        let approvalTimeoutBehavior: ApprovalTimeoutBehavior = {
            guard let raw = approvalBlock?["timeoutBehavior"] as? String else {
                return .autoDeny
            }
            return ApprovalTimeoutBehavior(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? .autoDeny
        }()
        let approvalSeverityDefault: String = {
            let raw = approvalBlock?["severityDefault"] as? String
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "medium" : trimmed
        }()
        let approvalElevatedSeverityDefault: String = {
            let raw = approvalBlock?["elevatedSeverityDefault"] as? String
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "high" : trimmed
        }()
        let elevatedExecutionPolicy: ElevatedExecutionPolicy = {
            guard let raw = toolPolicy["elevatedExecutionPolicy"] as? String else {
                return .privilegedDispatch
            }
            return ElevatedExecutionPolicy(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? .privilegedDispatch
        }()
        let executionEnvironmentPolicy: ExecutionEnvironmentPolicy = {
            guard let block = toolPolicy["executionEnvironment"] as? [String: Any] else {
                return .unrestricted
            }
            func parseSet(_ key: String) -> Set<ExecutionEnvironmentKind> {
                guard let values = block[key] as? [String] else { return [] }
                let kinds = values.compactMap { value in
                    ExecutionEnvironmentKind(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                return Set(kinds)
            }
            func parseAdapterSet(_ key: String) -> Set<String> {
                guard let values = block[key] as? [String] else { return [] }
                return Set(
                    values
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            }
            return ExecutionEnvironmentPolicy(
                disallowed: parseSet("disallow"),
                approvalRequired: parseSet("requireApproval"),
                escalationRequired: parseSet("requireEscalation"),
                disallowedAdapterIDs: parseAdapterSet("disallowAdapters"),
                approvalRequiredAdapterIDs: parseAdapterSet("requireApprovalAdapters"),
                escalationRequiredAdapterIDs: parseAdapterSet("requireEscalationAdapters")
            )
        }()
        let dispatchPolicy = Self.parseDispatchPolicyBlock(toolPolicy["dispatch"] as? [String: Any])
        return ToolPolicyConfiguration(
            sensitiveToolNames: sensitiveToolNames,
            escalationRequiredToolNames: escalationRequiredToolNames,
            approvalRequiredToolNames: approvalRequiredToolNames,
            elevatedToolNames: parsedElevated.tools,
            perCallElevatedToolNames: parsedElevated.perCall,
            elevatedAllowFrom: parsedElevated.allowFrom,
            subAgentHostingPolicyConfiguration: subAgentHostingPolicyConfiguration,
            descriptorValidationMode: descriptorValidationMode,
            approvalTimeoutMilliseconds: approvalTimeoutMilliseconds,
            approvalTimeoutBehavior: approvalTimeoutBehavior,
            approvalSeverityDefault: approvalSeverityDefault,
            approvalElevatedSeverityDefault: approvalElevatedSeverityDefault,
            elevatedExecutionPolicy: elevatedExecutionPolicy,
            executionEnvironmentPolicy: executionEnvironmentPolicy,
            parallelDispatchEnabled: dispatchPolicy.parallelDispatchEnabled,
            dispatchPlannerMode: dispatchPolicy.dispatchPlannerMode,
            pendingToolTimeoutSeconds: dispatchPolicy.pendingToolTimeoutSeconds
        )
    }

    struct ParsedElevatedPolicy {
        let tools: Set<String>
        let perCall: Set<String>
        let allowFrom: ElevatedAllowlist
    }

    static func parseElevatedBlock(_ value: Any?) -> ParsedElevatedPolicy {
        if let names = value as? [String] {
            return ParsedElevatedPolicy(tools: Set(names), perCall: [], allowFrom: .cliDefault)
        }
        guard let block = value as? [String: Any] else {
            return ParsedElevatedPolicy(tools: [], perCall: [], allowFrom: .cliDefault)
        }
        let tools = Set((block["tools"] as? [String]) ?? [])
        let perCall = Set((block["perCall"] as? [String]) ?? [])
        var allowFrom: [String: Set<String>] = [:]
        if let raw = block["allowFrom"] as? [String: Any] {
            for (surface, idsValue) in raw {
                if let ids = idsValue as? [String] {
                    allowFrom[surface] = Set(ids)
                }
            }
        }
        return ParsedElevatedPolicy(
            tools: tools,
            perCall: perCall,
            allowFrom: ElevatedAllowlist(allowFrom: allowFrom)
        )
    }

    static func parseDispatchPolicyBlock(
        _ dispatch: [String: Any]?
    ) -> (
        parallelDispatchEnabled: Bool,
        dispatchPlannerMode: DispatchPlannerMode?,
        pendingToolTimeoutSeconds: TimeInterval?
    ) {
        let parallelDispatchEnabled = dispatch?["parallelEnabled"] as? Bool ?? false
        let dispatchPlannerMode: DispatchPlannerMode? = {
            guard let raw = dispatch?["plannerMode"] as? String else {
                return nil
            }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case DispatchPlannerMode.serial.rawValue.lowercased():
                return .serial
            case DispatchPlannerMode.allParallel.rawValue.lowercased():
                return .allParallel
            case DispatchPlannerMode.mixedDeterministic.rawValue.lowercased():
                return .mixedDeterministic
            default:
                return nil
            }
        }()
        let pendingToolTimeoutSeconds: TimeInterval?
        if let rawTimeout = dispatch?["pendingToolTimeoutSeconds"] as? Double {
            pendingToolTimeoutSeconds = rawTimeout > 0 ? rawTimeout : nil
        } else if let rawTimeoutInt = dispatch?["pendingToolTimeoutSeconds"] as? Int {
            let resolved = TimeInterval(rawTimeoutInt)
            pendingToolTimeoutSeconds = resolved > 0 ? resolved : nil
        } else {
            pendingToolTimeoutSeconds = nil
        }
        return (
            parallelDispatchEnabled: parallelDispatchEnabled,
            dispatchPlannerMode: dispatchPlannerMode,
            pendingToolTimeoutSeconds: pendingToolTimeoutSeconds
        )
    }
}

struct SubAgentHostingPolicyConfiguration: Sendable {
    private let defaultPolicy: SubAgentHostingPolicy
    private let policiesByDelegateToolName: [String: SubAgentHostingPolicy]
    private let policiesByHostPersonaID: [String: SubAgentHostingPolicy]

    static let empty = SubAgentHostingPolicyConfiguration(
        defaultPolicy: SubAgentHostingPolicy(),
        policiesByDelegateToolName: [:],
        policiesByHostPersonaID: [:]
    )

    init(
        defaultPolicy: SubAgentHostingPolicy,
        policiesByDelegateToolName: [String: SubAgentHostingPolicy],
        policiesByHostPersonaID: [String: SubAgentHostingPolicy]
    ) {
        self.defaultPolicy = defaultPolicy
        self.policiesByDelegateToolName = policiesByDelegateToolName
        self.policiesByHostPersonaID = policiesByHostPersonaID
    }

    func policy(forDelegateToolName name: String) -> SubAgentHostingPolicy {
        policiesByDelegateToolName[name] ?? defaultPolicy
    }

    func policy(forHostPersonaID hostPersonaID: String) -> SubAgentHostingPolicy? {
        policiesByHostPersonaID[hostPersonaID]
    }

    func stableSignature() -> String {
        var chunks: [String] = []
        for key in policiesByDelegateToolName.keys.sorted() {
            guard let policy = policiesByDelegateToolName[key] else { continue }
            chunks.append("\(key):\(Self.signature(policy))")
        }
        return chunks.joined(separator: "|")
    }

    static func loadFromPromptConfigBundle(logger: Logger? = nil) -> SubAgentHostingPolicyConfiguration {
        guard let data = PromptConfigBundleResource.data() else {
            logger?.warning("PromptConfig.json not found; sub-agent hosting policy disabled")
            return .empty
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        return fromPromptConfigRoot(json)
    }

    static func fromPromptConfigRoot(_ json: [String: Any]) -> SubAgentHostingPolicyConfiguration {
        guard let root = json["subAgentHostingPolicy"] as? [String: Any] else {
            return .empty
        }
        let defaultPolicy = parsePolicy(root["defaults"] as? [String: Any]) ?? SubAgentHostingPolicy()
        var byToolName: [String: SubAgentHostingPolicy] = [:]
        var byHostPersonaID: [String: SubAgentHostingPolicy] = [:]
        if let entries = root["entries"] as? [String: Any] {
            for (toolName, raw) in entries {
                guard let object = raw as? [String: Any],
                      let policy = parsePolicy(object) else { continue }
                byToolName[toolName] = policy
                if let hostPersonaID = policy.hostPersonaID, !hostPersonaID.isEmpty {
                    byHostPersonaID[hostPersonaID] = policy
                }
            }
        }
        return SubAgentHostingPolicyConfiguration(
            defaultPolicy: defaultPolicy,
            policiesByDelegateToolName: byToolName,
            policiesByHostPersonaID: byHostPersonaID
        )
    }

    private static func parsePolicy(_ raw: [String: Any]?) -> SubAgentHostingPolicy? {
        guard let raw else { return nil }
        let allowlist = (raw["delegationAllowlist"] as? [String]) ?? []
        let authScopeTags = (raw["authScopeTags"] as? [String]) ?? []
        return SubAgentHostingPolicy(
            hostPersonaID: raw["hostPersonaID"] as? String,
            delegationAllowlist: allowlist,
            authScopeTags: authScopeTags,
            routingDomain: raw["routingDomain"] as? String,
            tenantScope: raw["tenantScope"] as? String
        )
    }

    private static func signature(_ policy: SubAgentHostingPolicy) -> String {
        let host = policy.hostPersonaID ?? "*"
        let allow = policy.delegationAllowlist.sorted().joined(separator: ",")
        let scopes = policy.authScopeTags.sorted().joined(separator: ",")
        let domain = policy.routingDomain ?? "*"
        let tenant = policy.tenantScope ?? "*"
        return "host=\(host);allow=\(allow);scopes=\(scopes);domain=\(domain);tenant=\(tenant)"
    }
}
