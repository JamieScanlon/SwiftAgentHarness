import EasyJSON
import Foundation
import SwiftAgentKit

/// Canonical Tool System metadata row used by the gateway to classify and filter tools.
struct ToolRegistryEntry: Sendable {
    enum TransportKind: String, Sendable {
        case local
        case mcp
        case a2a
        case acp
        case unknown
    }

    enum EffectClass: String, Sendable {
        case readOnly
        case mutating
        case unknown
    }

    enum ParallelHint: String, Sendable {
        case parallelizable
        case serialOnly
        case unknown
    }

    enum PolicyTag: String, Sendable, Hashable {
        case sensitive
        case requiresApproval
        case elevated
        case exactContentObservation = "exact-content-observation"
        case compactionProtected = "compaction-protected"
    }

    enum ExecutionEnvironmentKind: String, Sendable, Codable, Equatable {
        case local
        case docker
        case ssh
        case mcp
        case a2a
        case unknown
    }

    enum ExecutionIsolationLevel: String, Sendable, Codable, Equatable {
        case inProcess = "in-process"
        case remoteManaged = "remote-managed"
        case remoteExternal = "remote-external"
        case unknown
    }

    struct ExecutionEnvironmentDescriptor: Sendable, Equatable {
        let kind: ExecutionEnvironmentKind
        let adapterID: String
        let isolationLevel: ExecutionIsolationLevel
    }

    let definition: ToolDefinition
    let source: ToolListingSource
    let transportKind: TransportKind
    let effectClass: EffectClass
    let parallelHint: ParallelHint
    let policyTags: Set<PolicyTag>
    /// Custom `group:*` tags from descriptor policy tags for registry-backed group aliases.
    let groupPolicyTags: Set<String>
    let haltsLoop: Bool
    let executionEnvironment: ExecutionEnvironmentDescriptor
    let normalizedSchemaFingerprint: String?
    let normalizedSchemaVersion: String?
    let normalizedTopLevelType: String?
    let normalizedRequiredCount: Int?
    let normalizedPropertyCount: Int?
    /// Canonical registration-time parameters schema (provider-agnostic).
    let canonicalParametersSchema: JSON?
    /// Legacy names that resolve to this entry's canonical `name` (normalized at init).
    let aliases: [String]
    /// Bytes past which runtime delivery spills to disk instead of lossy truncation; `nil` uses global default.
    let maxResultSizeBeforeSpill: Int?
    /// When true, oversized results are not spilled (self-bounding read tools).
    let spillExempt: Bool

    var name: String { definition.name }
    var description: String { definition.description }

    init(
        definition: ToolDefinition,
        source: ToolListingSource,
        transportKind: TransportKind,
        effectClass: EffectClass = .unknown,
        parallelHint: ParallelHint = .unknown,
        policyTags: Set<PolicyTag> = [],
        groupPolicyTags: Set<String> = [],
        haltsLoop: Bool? = nil,
        executionEnvironment: ExecutionEnvironmentDescriptor? = nil,
        normalizedSchemaFingerprint: String? = nil,
        normalizedSchemaVersion: String? = nil,
        normalizedTopLevelType: String? = nil,
        normalizedRequiredCount: Int? = nil,
        normalizedPropertyCount: Int? = nil,
        canonicalParametersSchema: JSON? = nil,
        aliases: [String]? = nil,
        maxResultSizeBeforeSpill: Int? = nil,
        spillExempt: Bool? = nil
    ) {
        self.definition = definition
        self.source = source
        self.transportKind = transportKind
        self.effectClass = effectClass
        self.parallelHint = parallelHint
        self.groupPolicyTags = groupPolicyTags
        self.haltsLoop = haltsLoop ?? Self.defaultHaltsLoop(for: definition.name)
        self.executionEnvironment = executionEnvironment
            ?? Self.defaultExecutionEnvironmentDescriptor(transportKind: transportKind)
        self.normalizedSchemaFingerprint = normalizedSchemaFingerprint
        self.normalizedSchemaVersion = normalizedSchemaVersion
        self.normalizedTopLevelType = normalizedTopLevelType
        self.normalizedRequiredCount = normalizedRequiredCount
        self.normalizedPropertyCount = normalizedPropertyCount
        self.canonicalParametersSchema = canonicalParametersSchema
        self.aliases = Self.normalizedAliases(aliases ?? ToolBuiltinAliases.aliases(forCanonicalName: definition.name))
        self.maxResultSizeBeforeSpill = maxResultSizeBeforeSpill
        self.spillExempt = spillExempt ?? ToolRegistrySpillPolicy.isSpillExempt(toolName: definition.name)
        self.policyTags = Self.augmentedPolicyTags(
            policyTags,
            definition: definition,
            transportKind: transportKind,
            source: source
        )
    }

    init(
        definition: ToolDefinition,
        source: ToolListingSource,
        effectClass: EffectClass = .unknown,
        parallelHint: ParallelHint = .unknown,
        policyTags: Set<PolicyTag> = [],
        groupPolicyTags: Set<String> = [],
        haltsLoop: Bool? = nil,
        executionEnvironment: ExecutionEnvironmentDescriptor? = nil,
        normalizedSchemaFingerprint: String? = nil,
        normalizedSchemaVersion: String? = nil,
        normalizedTopLevelType: String? = nil,
        normalizedRequiredCount: Int? = nil,
        normalizedPropertyCount: Int? = nil,
        canonicalParametersSchema: JSON? = nil,
        aliases: [String]? = nil
    ) {
        let transportKind: TransportKind
        switch source {
        case .local:
            transportKind = .local
        case .mcp:
            transportKind = .mcp
        case .a2a:
            transportKind = .a2a
        case .unknown:
            transportKind = .unknown
        }
        self.init(
            definition: definition,
            source: source,
            transportKind: transportKind,
            effectClass: effectClass,
            parallelHint: parallelHint,
            policyTags: policyTags,
            groupPolicyTags: groupPolicyTags,
            haltsLoop: haltsLoop,
            executionEnvironment: executionEnvironment,
            normalizedSchemaFingerprint: normalizedSchemaFingerprint,
            normalizedSchemaVersion: normalizedSchemaVersion,
            normalizedTopLevelType: normalizedTopLevelType,
            normalizedRequiredCount: normalizedRequiredCount,
            normalizedPropertyCount: normalizedPropertyCount,
            canonicalParametersSchema: canonicalParametersSchema,
            aliases: aliases
        )
    }

    init(descriptor: RegisteredToolDescriptor) {
        let source: ToolListingSource
        let transportKind: TransportKind
        switch descriptor.source {
        case .local:
            source = .local
            transportKind = .local
        case .mcp:
            source = .mcp
            transportKind = .mcp
        case .a2a:
            source = .a2a
            transportKind = .a2a
        case .acp:
            source = .unknown
            transportKind = .acp
        case .unknown:
            source = .unknown
            transportKind = .unknown
        }
        let effectClass: EffectClass
        switch descriptor.effectClass {
        case .readOnly:
            effectClass = .readOnly
        case .mutating:
            effectClass = .mutating
        case .unknown:
            effectClass = .unknown
        }
        let parallelHint: ParallelHint
        switch descriptor.parallelHint {
        case .parallelizable:
            parallelHint = .parallelizable
        case .serialOnly:
            parallelHint = .serialOnly
        case .unknown:
            parallelHint = .unknown
        }
        var policyTags = Set(descriptor.policyTags.compactMap { tag in
            PolicyTag(rawValue: tag.rawValue)
        })
        policyTags = Self.augmentedPolicyTags(
            policyTags,
            definition: descriptor.definition,
            transportKind: transportKind,
            source: source
        )
        let groupPolicyTags = Set(
            descriptor.policyTags
                .map(\.rawValue)
                .filter { $0.lowercased().hasPrefix("group:") }
        )
        let executionEnvironment = Self.executionEnvironmentDescriptor(
            from: descriptor,
            transportKind: transportKind
        )
        let aliases: [String]
        switch source {
        case .local:
            aliases = ToolBuiltinAliases.aliases(forCanonicalName: descriptor.definition.name)
        default:
            aliases = []
        }
        self.init(
            definition: descriptor.definition,
            source: source,
            transportKind: transportKind,
            effectClass: effectClass,
            parallelHint: parallelHint,
            policyTags: policyTags,
            groupPolicyTags: groupPolicyTags,
            haltsLoop: Self.defaultHaltsLoop(for: descriptor.definition.name),
            executionEnvironment: executionEnvironment,
            normalizedSchemaFingerprint: descriptor.normalizedSchemaFingerprint,
            normalizedSchemaVersion: descriptor.normalizedSchemaVersion,
            normalizedTopLevelType: descriptor.schemaSummary.topLevelType,
            normalizedRequiredCount: descriptor.schemaSummary.requiredCount,
            normalizedPropertyCount: descriptor.schemaSummary.propertyCount,
            canonicalParametersSchema: descriptor.normalizedSchema.schema,
            aliases: aliases,
            maxResultSizeBeforeSpill: nil,
            spillExempt: ToolRegistrySpillPolicy.isSpillExempt(toolName: descriptor.definition.name)
        )
    }

    func withExecutionEnvironment(
        _ executionEnvironment: ExecutionEnvironmentDescriptor
    ) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: definition,
            source: source,
            transportKind: transportKind,
            effectClass: effectClass,
            parallelHint: parallelHint,
            policyTags: policyTags,
            groupPolicyTags: groupPolicyTags,
            haltsLoop: haltsLoop,
            executionEnvironment: executionEnvironment,
            normalizedSchemaFingerprint: normalizedSchemaFingerprint,
            normalizedSchemaVersion: normalizedSchemaVersion,
            normalizedTopLevelType: normalizedTopLevelType,
            normalizedRequiredCount: normalizedRequiredCount,
            normalizedPropertyCount: normalizedPropertyCount,
            canonicalParametersSchema: canonicalParametersSchema,
            aliases: aliases,
            maxResultSizeBeforeSpill: maxResultSizeBeforeSpill,
            spillExempt: spillExempt
        )
    }

    private static func normalizedAliases(_ aliases: [String]) -> [String] {
        var seen: Set<String> = []
        return aliases.compactMap { alias in
            let normalized = ToolRegistryNameIndex.normalizeToken(alias)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func augmentedPolicyTags(
        _ policyTags: Set<PolicyTag>,
        definition: ToolDefinition,
        transportKind: TransportKind,
        source: ToolListingSource
    ) -> Set<PolicyTag> {
        var resolved = policyTags
        if transportKind == .a2a || source == .a2a || definition.type == .a2aAgent {
            resolved.insert(.exactContentObservation)
            resolved.insert(.compactionProtected)
        } else if transportKind == .acp || definition.type == .acpAgent {
            resolved.insert(.exactContentObservation)
            resolved.insert(.compactionProtected)
        } else if ToolRegistryResultFormattingPolicy.isDelegateToolName(definition.name) {
            resolved.insert(.exactContentObservation)
            resolved.insert(.compactionProtected)
        }
        return resolved
    }

    var availableToolInfo: AvailableToolInfo {
        AvailableToolInfo(
            name: name,
            description: description,
            source: source,
            normalizedSchemaFingerprint: normalizedSchemaFingerprint,
            normalizedSchemaVersion: normalizedSchemaVersion,
            normalizedTopLevelType: normalizedTopLevelType,
            normalizedRequiredCount: normalizedRequiredCount,
            normalizedPropertyCount: normalizedPropertyCount
        )
    }

    private static func defaultExecutionEnvironmentDescriptor(
        transportKind: TransportKind
    ) -> ExecutionEnvironmentDescriptor {
        switch transportKind {
        case .local:
            return ExecutionEnvironmentDescriptor(
                kind: .local,
                adapterID: "tool-env.local.default",
                isolationLevel: .inProcess
            )
        case .mcp:
            return ExecutionEnvironmentDescriptor(
                kind: .mcp,
                adapterID: "tool-env.mcp.default",
                isolationLevel: .remoteManaged
            )
        case .a2a:
            return ExecutionEnvironmentDescriptor(
                kind: .a2a,
                adapterID: "tool-env.a2a.default",
                isolationLevel: .remoteExternal
            )
        case .acp:
            return ExecutionEnvironmentDescriptor(
                kind: .mcp,
                adapterID: SubAgentTransportKind.acpStdio.rawValue,
                isolationLevel: .remoteManaged
            )
        case .unknown:
            return ExecutionEnvironmentDescriptor(
                kind: .unknown,
                adapterID: "tool-env.unknown.default",
                isolationLevel: .unknown
            )
        }
    }

    private static func defaultHaltsLoop(for toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.haltSignalToolNames.contains(normalized)
    }

    private static let haltSignalToolNames: Set<String> = [
        "finish",
        "ask_user",
        "declare_agent_build_complete",
        "exit_plan_mode",
    ]

    private static func executionEnvironmentDescriptor(
        from descriptor: RegisteredToolDescriptor,
        transportKind: TransportKind
    ) -> ExecutionEnvironmentDescriptor {
        let fallback = defaultExecutionEnvironmentDescriptor(transportKind: transportKind)
        let tags = descriptor.policyTags.map(\.rawValue)
        let kind = tags
            .lazy
            .compactMap(parseExecutionEnvironmentKind(from:))
            .first ?? fallback.kind
        let adapterID = tags
            .lazy
            .compactMap(parseExecutionEnvironmentAdapterID(from:))
            .first ?? fallback.adapterID
        let isolationLevel = tags
            .lazy
            .compactMap(parseExecutionIsolationLevel(from:))
            .first ?? fallback.isolationLevel
        return ExecutionEnvironmentDescriptor(
            kind: kind,
            adapterID: adapterID,
            isolationLevel: isolationLevel
        )
    }

    private static func parseExecutionEnvironmentKind(
        from rawTag: String
    ) -> ExecutionEnvironmentKind? {
        guard let value = ExecutionEnvironmentTagParser.extractTaggedValue(
            raw: rawTag,
            prefixes: [ExecutionEnvironmentTagParser.kindPrefix, ExecutionEnvironmentTagParser.kindLegacyPrefix]
        ) else { return nil }
        return ExecutionEnvironmentKind(rawValue: value.lowercased())
    }

    private static func parseExecutionEnvironmentAdapterID(
        from rawTag: String
    ) -> String? {
        ExecutionEnvironmentTagParser.extractTaggedValue(
            raw: rawTag,
            prefixes: [ExecutionEnvironmentTagParser.adapterPrefix, ExecutionEnvironmentTagParser.adapterLegacyPrefix]
        )
    }

    private static func parseExecutionIsolationLevel(
        from rawTag: String
    ) -> ExecutionIsolationLevel? {
        guard let value = ExecutionEnvironmentTagParser.extractTaggedValue(
            raw: rawTag,
            prefixes: [ExecutionEnvironmentTagParser.isolationPrefix, ExecutionEnvironmentTagParser.isolationLegacyPrefix]
        ) else { return nil }
        let normalized = value.lowercased()
        switch normalized {
        case ExecutionIsolationLevel.inProcess.rawValue, "inprocess", "local":
            return .inProcess
        case ExecutionIsolationLevel.remoteManaged.rawValue, "remotemanaged":
            return .remoteManaged
        case ExecutionIsolationLevel.remoteExternal.rawValue, "remoteexternal":
            return .remoteExternal
        case ExecutionIsolationLevel.unknown.rawValue:
            return .unknown
        default:
            return nil
        }
    }
}

protocol ToolExecutionEnvironmentAdapting: Sendable {
    var id: String { get }
    func descriptor(for entry: ToolRegistryEntry) -> ToolRegistryEntry.ExecutionEnvironmentDescriptor
}

struct DefaultToolExecutionEnvironmentAdapter: ToolExecutionEnvironmentAdapting {
    let id = "tool-execution-environment.default"

    func descriptor(for entry: ToolRegistryEntry) -> ToolRegistryEntry.ExecutionEnvironmentDescriptor {
        entry.executionEnvironment
    }
}
