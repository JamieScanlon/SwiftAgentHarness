import EasyJSON
import Foundation
import Logging

/// Source classification for project-local mode profile directories.
public enum ModeProfileProjectConfigSource: Sendable {
    /// Operator-controlled directory; security-sensitive slices are stripped before merge.
    case operatorDirectory
}

/// Harness-shaped registry: built-in ids match persisted ``InteractionMode/rawValue`` strings.
public actor ModeRegistryService {
    /// Canonical built-in cap for collaboration planning turns.
    static let builtInPlanMaxIterations = 8

    private var profiles: [String: ResolvedModeProfile] = [:]
    private var diagnostics: [String] = []
    private let projectConfigDirectory: URL?
    private let projectConfigSource: ModeProfileProjectConfigSource?
    private var onDidMutate: (@Sendable () -> Void)?

    public init(
        seedingBuiltIns: Bool = true,
        modeProfileConfiguration: ModeProfileConfiguration? = nil,
        projectConfigDirectory: URL? = nil,
        projectConfigSource: ModeProfileProjectConfigSource? = nil,
        additionalProfiles: [ResolvedModeProfile] = []
    ) {
        self.projectConfigDirectory = projectConfigDirectory
        self.projectConfigSource = projectConfigSource
        if seedingBuiltIns {
            ModeProfileBuiltInCatalog.seed(into: &profiles)
        }
        let loaded = modeProfileConfiguration ?? .empty
        diagnostics.append(contentsOf: loaded.diagnostics)
        Self.mergeConfigurationProfiles(loaded.profiles, into: &profiles, diagnostics: &diagnostics)
        Self.loadAndMergeProjectProfiles(
            from: projectConfigDirectory,
            source: projectConfigSource,
            into: &profiles,
            diagnostics: &diagnostics
        )
        for profile in additionalProfiles {
            if profiles[profile.id] == nil {
                profiles[profile.id] = profile
            }
        }
        Self.validateMachineSubAgentProfiles(in: profiles, diagnostics: &diagnostics)
    }

    /// Production registry wired to an operator-controlled project config directory.
    public static func makeForHost(
        cwd: String,
        fileManager: FileManager = .default,
        logger: Logger? = nil,
        seedingBuiltIns: Bool = true,
        modeProfileConfiguration: ModeProfileConfiguration? = nil,
        additionalProfiles: [ResolvedModeProfile] = []
    ) -> ModeRegistryService {
        let resolution = ModeProfileProjectConfigDirectoryResolver.resolve(cwd: cwd, fileManager: fileManager)
        if !resolution.diagnostics.isEmpty {
            logger?.warning("Mode profile project config: \(resolution.diagnostics.joined(separator: "; "))")
        }
        return ModeRegistryService(
            seedingBuiltIns: seedingBuiltIns,
            modeProfileConfiguration: modeProfileConfiguration,
            projectConfigDirectory: resolution.directory,
            projectConfigSource: resolution.directory == nil ? nil : .operatorDirectory,
            additionalProfiles: additionalProfiles
        )
    }

    public func missingMachineSubAgentProfileIDs() -> [String] {
        ConversationLineageInference.machineSubAgentModeProfileIDs
            .filter { profiles[$0] == nil }
            .sorted()
    }

    public func setOnDidMutate(_ handler: @escaping @Sendable () -> Void) {
        onDidMutate = handler
    }

    func register(_ profile: ResolvedModeProfile, replacing: Bool = false) throws {
        if profiles[profile.id] != nil, !replacing {
            throw ModeRegistryError.duplicateRegistration(id: profile.id)
        }
        profiles[profile.id] = profile
        notifyMutations()
    }

    /// Re-loads project-local mode config files and merges them over the current registry.
    /// Returns `false` when no project config directory is configured.
    @discardableResult
    func reloadProjectConfig() -> Bool {
        guard projectConfigDirectory != nil, projectConfigSource != nil else { return false }
        Self.loadAndMergeProjectProfiles(
            from: projectConfigDirectory,
            source: projectConfigSource,
            into: &profiles,
            diagnostics: &diagnostics
        )
        notifyMutations()
        return true
    }

    public func resolve(modeId: String) throws -> ResolvedModeProfile {
        guard let profile = profiles[modeId] else {
            throw ModeRegistryError.unknownMode(id: modeId)
        }
        return profile
    }

    /// Unknown ids fall back to **chat** built-in (template persistence parity); logs a warning when ``didFallback``.
    func resolveReportingFallback(
        modeId: String,
        logger: Logger?,
        fallbackModeId: String = InteractionMode.chat.rawValue
    ) -> (profile: ResolvedModeProfile, didFallback: Bool) {
        if let profile = profiles[modeId] {
            return (profile, false)
        }
        logger?.warning("Unknown mode profile id '\(modeId)'; falling back to '\(fallbackModeId)'")
        let fallback = profiles[fallbackModeId] ?? profiles[InteractionMode.chat.rawValue]!
        return (fallback, true)
    }

    func registeredModeIDs() -> [String] {
        profiles.keys.sorted()
    }

    func profilesForPicker() -> [ModeProfilePickerRow] {
        profiles.values
            .map { profile in
                ModeProfilePickerRow(
                    id: profile.id,
                    label: profile.pickerLabel,
                    description: profile.profileDescription,
                    symbol: profile.symbol,
                    summary: Self.summary(for: profile)
                )
            }
            .sorted {
                let lhs = $0.label.lowercased()
                let rhs = $1.label.lowercased()
                if lhs != rhs { return lhs < rhs }
                return $0.id < $1.id
            }
    }

    public func configurationDiagnostics() -> [String] {
        diagnostics
    }

    private func notifyMutations() {
        onDidMutate?()
    }

    private static func validateMachineSubAgentProfiles(
        in profiles: [String: ResolvedModeProfile],
        diagnostics: inout [String]
    ) {
        for id in ConversationLineageInference.machineSubAgentModeProfileIDs.sorted() {
            if profiles[id] == nil {
                diagnostics.append("required machine sub-agent mode profile missing: \(id)")
            }
        }
    }

    private static func loadAndMergeProjectProfiles(
        from projectConfigDirectory: URL?,
        source: ModeProfileProjectConfigSource?,
        into storage: inout [String: ResolvedModeProfile],
        diagnostics: inout [String]
    ) {
        guard let projectConfigDirectory, let source else { return }
        let loaded = ModeProfileConfiguration.loadFromDirectory(projectConfigDirectory)
        diagnostics.append(contentsOf: loaded.diagnostics)
        let profiles: [ModeProfileConfiguration.RawProfile] = switch source {
        case .operatorDirectory:
            ModeProfileProjectOverlayPolicy.sanitizeAll(loaded.profiles, diagnostics: &diagnostics)
        }
        Self.mergeConfigurationProfiles(profiles, into: &storage, diagnostics: &diagnostics)
    }

    private static func mergeConfigurationProfiles(
        _ raws: [ModeProfileConfiguration.RawProfile],
        into storage: inout [String: ResolvedModeProfile],
        diagnostics: inout [String]
    ) {
        guard !raws.isEmpty else { return }
        let order = orderingForMerge(raws, diagnostics: &diagnostics)
        for raw in order {
            guard let base = resolveMergeBase(for: raw, storage: storage, diagnostics: &diagnostics) else {
                continue
            }
            storage[raw.id] = mergeResolved(base: base, raw: raw, diagnostics: &diagnostics)
        }
    }

    private static func resolveMergeBase(
        for raw: ModeProfileConfiguration.RawProfile,
        storage: [String: ResolvedModeProfile],
        diagnostics: inout [String]
    ) -> ResolvedModeProfile? {
        if let ext = raw.extends {
            if let parent = storage[ext] {
                return parent
            }
            diagnostics.append("modeProfiles[\(raw.id)] extends unknown profile '\(ext)'")
            return nil
        }
        if let existing = storage[raw.id] {
            return existing
        }
        guard let im = raw.interactionMode, let ak = raw.assemblyKind else {
            diagnostics.append("modeProfiles[\(raw.id)] missing interactionMode/assemblyKind and does not extend an existing profile")
            return nil
        }
        return ResolvedModeProfile.syntheticSeed(id: raw.id, interactionMode: im, assemblyKind: ak)
    }

    /// Topological order for custom profiles so ``extends`` targets are merged first (built-ins pre-seeded).
    private static func orderingForMerge(_ profiles: [ModeProfileConfiguration.RawProfile], diagnostics: inout [String]) -> [ModeProfileConfiguration.RawProfile] {
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var visiting = Set<String>()
        var visited = Set<String>()
        var ordered: [ModeProfileConfiguration.RawProfile] = []

        func visit(_ id: String) {
            guard let node = byID[id] else { return }
            if visited.contains(id) { return }
            if visiting.contains(id) {
                diagnostics.append("modeProfiles cycle detected involving '\(id)'")
                return
            }
            visiting.insert(id)
            if let ext = node.extends, byID[ext] != nil {
                visit(ext)
            }
            visiting.remove(id)
            visited.insert(id)
            ordered.append(node)
        }

        for id in byID.keys.sorted() {
            visit(id)
        }
        return ordered
    }

    private static func mergeResolved(
        base: ResolvedModeProfile,
        raw: ModeProfileConfiguration.RawProfile,
        diagnostics: inout [String]
    ) -> ResolvedModeProfile {
        let interactionMode = raw.interactionMode ?? base.interactionMode
        let assemblyKind = raw.assemblyKind ?? base.assemblyKind
        let allowsCompaction = raw.allowsProactiveCompactionTriggers ?? base.allowsProactiveCompactionTriggers
        let appliesHarness = raw.appliesAgentBuildOrchestratorHarness ?? base.appliesAgentBuildOrchestratorHarness
        let tags: [String] = raw.semanticLayerTags ?? base.semanticLayerTags
        let label = raw.label ?? base.label
        let profileDescription = raw.profileDescription ?? base.profileDescription
        let symbol = raw.symbol ?? base.symbol
        let seedVersion = base.builtInSeedVersion == ResolvedModeProfile.builtInSeedVersion && raw.extends == nil && raw.id == base.id
            ? ResolvedModeProfile.builtInSeedVersion
            : 0

        let tools = Self.mergeToolsSlice(
            parent: base.tools,
            overlay: raw.tools,
            profileID: raw.id,
            diagnostics: &diagnostics
        )
        let isMachine = ConversationLineageInference.machineSubAgentModeProfileIDs.contains(raw.id)
            || ConversationLineageInference.machineSubAgentModeProfileIDs.contains(base.id)
        if isMachine, raw.allowsHostGrants == true {
            diagnostics.append(
                "modeProfiles[\(raw.id)] allowsHostGrants=true ignored: machine profiles cannot accept host visibility grants"
            )
        }
        let hostGrants = ResolvedModeProfile.resolveAllowsHostGrants(
            id: raw.id,
            explicitOnThisRow: isMachine ? nil : raw.allowsHostGrants,
            inherited: isMachine ? nil : (base.allowsHostGrants, base.allowsHostGrantsSource)
        )
        let resolvedHostGrants: (value: Bool, source: AllowsHostGrantsSource) =
            isMachine ? (false, .machinePinned) : hostGrants

        return ResolvedModeProfile(
            id: raw.id,
            interactionMode: interactionMode,
            assemblyKind: assemblyKind,
            allowsProactiveCompactionTriggers: allowsCompaction,
            appliesAgentBuildOrchestratorHarness: appliesHarness,
            allowsHostGrants: resolvedHostGrants.value,
            allowsHostGrantsSource: resolvedHostGrants.source,
            builtInSeedVersion: seedVersion,
            semanticLayerTags: tags,
            label: label,
            profileDescription: profileDescription,
            symbol: symbol,
            tools: tools,
            skills: Self.mergeSkillsSlice(
                parent: base.skills,
                overlay: raw.skills,
                profileID: raw.id,
                diagnostics: &diagnostics
            ),
            context: Self.mergeContextSlice(parent: base.context, overlay: raw.context),
            runtime: Self.mergeRuntimeSlice(
                parent: base.runtime,
                overlay: raw.runtime,
                profileID: raw.id,
                diagnostics: &diagnostics
            ),
            model: Self.mergeModelSlice(parent: base.model, overlay: raw.model),
            subAgents: Self.mergeSubAgentsSlice(
                parent: base.subAgents,
                overlay: raw.subAgents,
                profileID: raw.id,
                diagnostics: &diagnostics
            ),
            hooks: Self.mergeTransitionHooksSlice(parent: base.hooks, overlay: raw.hooks)
        )
    }

    private static func mergeToolsSlice(
        parent: ModeProfileToolsSlice,
        overlay: JSON?,
        profileID: String,
        diagnostics: inout [String]
    ) -> ModeProfileToolsSlice {
        guard let overlay, let o = overlay.objectFields else { return parent }
        var allow = parent.allow
        if o.keys.contains("allow") {
            allow = ModeProfileJSONParsing.normalizedToolPolicyAllowList(
                raw: o["allow"],
                profileID: profileID,
                fieldPath: "tools.allow",
                diagnostics: &diagnostics
            )
        }
        if let extra = o.stringArray(for: "allow+"),
           let currentAllow = allow,
           !currentAllow.contains("*") {
            allow = Array(Set(currentAllow + extra)).sorted()
        }
        var deny = parent.deny
        if let extra = o.stringArray(for: "deny") {
            deny = Array(Set(parent.deny + extra)).sorted()
        }
        if let extra = o.stringArray(for: "deny+") {
            deny = Array(Set(deny + extra)).sorted()
        }
        var approval = parent.approvalPolicy
        if let raw = o.optionalString(for: "approvalPolicy"),
           let parsed = ModeProfileToolApprovalPolicy(rawValue: raw) {
            approval = parsed
        }
        return ModeProfileToolsSlice(allow: allow, deny: deny, approvalPolicy: approval)
    }

    private static func mergeSkillsSlice(
        parent: ModeProfileSkillsSlice,
        overlay: JSON?,
        profileID: String,
        diagnostics: inout [String]
    ) -> ModeProfileSkillsSlice {
        guard let overlay, let o = overlay.objectFields else { return parent }
        var allow = parent.allow
        if o.keys.contains("allow") {
            allow = ModeProfileJSONParsing.normalizedProfileAllowList(
                raw: o["allow"],
                profileID: profileID,
                fieldPath: "skills.allow",
                diagnostics: &diagnostics
            )
        }
        if let extra = o.stringArray(for: "allow+"),
           let currentAllow = allow,
           !currentAllow.contains("*") {
            allow = Array(Set(currentAllow + extra)).sorted()
        }
        var deny = parent.deny
        if let extra = o.stringArray(for: "deny") {
            deny = Array(Set(parent.deny + extra)).sorted()
        }
        if let extra = o.stringArray(for: "deny+") {
            deny = Array(Set(deny + extra)).sorted()
        }
        return ModeProfileSkillsSlice(allow: allow, deny: deny)
    }

    private static func mergeContextSlice(parent: ModeProfileContextSlice, overlay: JSON?) -> ModeProfileContextSlice {
        guard let overlay, let o = overlay.objectFields else { return parent }
        var copy = parent
        if let v = o.optionalString(for: "compactionLevel") {
            copy.compactionLevel = v.nilIfEmpty
        }
        if o.keys.contains("modeDirective") {
            copy.modeDirective = o.optionalString(for: "modeDirective")?.nilIfEmpty
        }
        if let mo = o["sectionOverrides"]?.objectFields {
            var merged = parent.sectionOverrides
            for (key, value) in mo {
                if case .string(let text) = value {
                    merged[key] = text
                }
            }
            copy.sectionOverrides = merged
        }
        if let sup = ModeProfileJSONParsing.normalizedStringArray(from: o["suppressSections"]) {
            copy.suppressSections = Array(Set(parent.suppressSections + sup)).sorted()
        }
        if let v = o.optionalString(for: "memoryInjection") {
            copy.memoryInjection = v.nilIfEmpty
        }
        if o.keys.contains("includeSkills"), let b = o.optionalBool(for: "includeSkills") {
            copy.includeSkills = b
        }
        if o.keys.contains("includeToolGuidance"), let b = o.optionalBool(for: "includeToolGuidance") {
            copy.includeToolGuidance = b
        }
        if o.keys.contains("omitWorkspaceConventions"), let b = o.optionalBool(for: "omitWorkspaceConventions") {
            copy.omitWorkspaceConventions = b
        }
        return copy
    }

    private static func mergeRuntimeSlice(
        parent: ModeProfileRuntimeSlice,
        overlay: JSON?,
        profileID: String,
        diagnostics: inout [String]
    ) -> ModeProfileRuntimeSlice {
        guard let overlay, let o = overlay.objectFields else { return parent }
        var copy = parent
        if o.keys.contains("maxIterations") {
            if let v = o.optionalInt(for: "maxIterations") {
                copy.maxIterations = max(1, v)
            } else {
                copy.maxIterations = nil
            }
        }
        if o.keys.contains("stopOnApprovalRequest"), let b = o.optionalBool(for: "stopOnApprovalRequest") {
            copy.stopOnApprovalRequest = b
        }
        if let terminationOverlay = o["termination"]?.objectFields {
            copy.termination = mergeTerminationSlice(
                parent: copy.termination,
                overlay: terminationOverlay,
                profileID: profileID,
                diagnostics: &diagnostics
            )
        }
        return copy
    }

    private static func mergeTerminationSlice(
        parent: ModeProfileTerminationSlice?,
        overlay: [String: JSON],
        profileID: String,
        diagnostics: inout [String]
    ) -> ModeProfileTerminationSlice {
        var merged = parent ?? .bareMessageDefault
        if let raw = overlay.optionalString(for: "policy") {
            guard let parsed = ModeProfileTerminationPolicy(rawValue: raw) else {
                diagnostics.append("modeProfiles[\(profileID)].runtime.termination.policy invalid '\(raw)'")
                return merged
            }
            merged.policy = parsed
        }
        if overlay.keys.contains("onBareMessage") {
            diagnostics.append("modeProfiles[\(profileID)].runtime.termination.onBareMessage is no longer supported")
        }
        if let recoveryOverlay = overlay["recovery"]?.objectFields {
            merged.recovery = mergeTerminationRecoverySlice(
                parent: merged.recovery,
                overlay: recoveryOverlay,
                profileID: profileID,
                diagnostics: &diagnostics
            )
        }
        if merged.policy == .terminalTool, merged.recovery == nil {
            merged.recovery = ModeProfileTerminationRecoverySlice(
                strategy: .forcedToolChoice,
                rollbackStalledTurn: true,
                maxAttempts: 2,
                reminder: .escalating
            )
        }
        return merged
    }

    private static func mergeTerminationRecoverySlice(
        parent: ModeProfileTerminationRecoverySlice?,
        overlay: [String: JSON],
        profileID: String,
        diagnostics: inout [String]
    ) -> ModeProfileTerminationRecoverySlice {
        var merged = parent ?? ModeProfileTerminationRecoverySlice()
        if let raw = overlay.optionalString(for: "strategy") {
            guard let parsed = ModeProfileTerminationRecoveryStrategy(rawValue: raw) else {
                diagnostics.append("modeProfiles[\(profileID)].runtime.termination.recovery.strategy invalid '\(raw)'")
                return merged
            }
            merged.strategy = parsed
        }
        if let rollback = overlay.optionalBool(for: "rollbackStalledTurn") {
            merged.rollbackStalledTurn = rollback
        }
        if let attempts = overlay.optionalInt(for: "maxAttempts") {
            merged.maxAttempts = max(1, attempts)
        }
        if let inject = overlay.optionalInt(for: "behavioralInjectAfterStalls") {
            merged.behavioralInjectAfterStalls = max(1, inject)
        }
        if let temperature = overlay.optionalDouble(for: "behavioralRecoveryTemperature") {
            merged.behavioralRecoveryTemperature = temperature
        }
        if let raw = overlay.optionalString(for: "reminder") {
            guard let parsed = ModeProfileTerminationRecoveryReminder(rawValue: raw) else {
                diagnostics.append("modeProfiles[\(profileID)].runtime.termination.recovery.reminder invalid '\(raw)'")
                return merged
            }
            merged.reminder = parsed
        }
        return merged
    }

    private static func mergeModelSlice(parent: ModeProfileModelSlice, overlay: JSON?) -> ModeProfileModelSlice {
        guard let overlay, let o = overlay.objectFields else { return parent }
        var copy = parent
        if o.keys.contains("query") {
            copy.query = o.optionalString(for: "query")?.nilIfEmpty
        }
        if o.keys.contains("fallback") {
            copy.fallback = o.optionalString(for: "fallback")?.nilIfEmpty
        }
        if o.keys.contains("thinkingConfig") {
            copy.thinkingConfig = parseThinkingConfig(raw: o["thinkingConfig"])
        }
        return copy
    }

    private static func parseThinkingConfig(raw: JSON?) -> ThinkingConfig? {
        guard let raw else { return nil }
        if case .string(let stringValue) = raw {
            switch stringValue {
            case "disabled":
                return .disabled
            case "adaptive":
                return .adaptive
            default:
                return nil
            }
        }
        guard let object = raw.objectFields,
              let levelRaw = object.optionalString(for: "level"),
              let level = ThinkingLevel(rawValue: levelRaw) else {
            return nil
        }
        return .level(level, budgetTokens: object.optionalInt(for: "budgetTokens"))
    }

    private static func mergeSubAgentsSlice(
        parent: ModeProfileSubAgentsSlice,
        overlay: JSON?,
        profileID: String,
        diagnostics: inout [String]
    ) -> ModeProfileSubAgentsSlice {
        guard let overlay, let o = overlay.objectFields else { return parent }
        var copy = parent
        if o.keys.contains("allow") {
            copy.allow = ModeProfileJSONParsing.normalizedSubAgentAllowList(
                raw: o["allow"],
                profileID: profileID,
                diagnostics: &diagnostics
            )
        }
        if let d = o.optionalInt(for: "maxDepth") {
            copy.maxDepth = max(0, d)
        }
        if let raw = o.optionalString(for: "childModeOnSpawn"), let trimmed = raw.nilIfEmpty {
            copy.childModeOnSpawnProfileId = trimmed
        }
        return copy
    }

    private static func mergeTransitionHooksSlice(parent: ModeProfileTransitionHooksSlice, overlay: JSON?) -> ModeProfileTransitionHooksSlice {
        guard let overlay, let o = overlay.objectFields else { return parent }
        var copy = parent
        if o.keys.contains("onExit") {
            copy.onExit = ModeProfileJSONParsing.normalizedHookIDList(from: o["onExit"])
        }
        if o.keys.contains("onEnter") {
            copy.onEnter = ModeProfileJSONParsing.normalizedHookIDList(from: o["onEnter"])
        }
        return copy
    }

    private static func summary(for profile: ResolvedModeProfile) -> ModeProfileSummary {
        let toolPolicy: String = {
            guard let allow = profile.tools.allow else { return "all" }
            if allow.isEmpty { return "none" }
            if allow.contains("*") && profile.tools.deny.isEmpty { return "all" }
            return "restricted"
        }()
        let modelTier: String? = {
            let source = [profile.model.query, profile.model.fallback]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            guard !source.isEmpty else { return nil }
            if source.contains("reason") || source.contains("high") {
                return "reasoning"
            }
            if source.contains("fast") || source.contains("cheap") {
                return "fast"
            }
            return "custom"
        }()
        return ModeProfileSummary(
            toolPolicy: toolPolicy,
            compaction: profile.context.compactionLevel,
            maxIterations: profile.runtime.maxIterations,
            modelTier: modelTier
        )
    }
}

enum ModeProfileBuiltInCatalog {
    static func profile(for interactionMode: InteractionMode) -> ResolvedModeProfile {
        all().first { $0.interactionMode == interactionMode }
            ?? all().first { $0.id == InteractionMode.chat.rawValue }!
    }

    static func seed(into storage: inout [String: ResolvedModeProfile]) {
        for profile in all() {
            storage[profile.id] = profile
        }
    }

    static func all() -> [ResolvedModeProfile] {
        let v = ResolvedModeProfile.builtInSeedVersion
        let subSeed = ModeProfileSubAgentsSlice.harnessDefaultChildSpawnSeed()
        let chatRuntime = ModeProfileRuntimeSlice(
            maxIterations: nil,
            stopOnApprovalRequest: false,
            termination: ModeProfileTerminationSlice(
                policy: .bareMessage
            )
        )
        let planRuntime = ModeProfileRuntimeSlice(
            maxIterations: ModeRegistryService.builtInPlanMaxIterations,
            stopOnApprovalRequest: true,
            termination: ModeProfileTerminationSlice(
                policy: .terminalTool,
                recovery: ModeProfileTerminationRecoverySlice(
                    strategy: .forcedToolChoice,
                    rollbackStalledTurn: true,
                    maxAttempts: 2,
                    reminder: .escalating
                )
            )
        )
        let agentRuntime = ModeProfileRuntimeSlice(
            termination: ModeProfileTerminationSlice(
                policy: .terminalTool,
                recovery: ModeProfileTerminationRecoverySlice(
                    strategy: .forcedToolChoice,
                    rollbackStalledTurn: true,
                    maxAttempts: 2,
                    reminder: .escalating
                )
            )
        )
        let chatTools = ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
        let planTools = ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
        let agentTools = ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
        let chatModel = ModeProfileModelSlice(thinkingConfig: .disabled)
        let planModel = ModeProfileModelSlice(thinkingConfig: .level(.high, budgetTokens: nil))
        let agentModel = ModeProfileModelSlice(thinkingConfig: .adaptive)
        let transitionHooks = ModeProfileTransitionHooksSlice(
            onExit: ["invalidate_orchestrator"],
            onEnter: ["restore_skill_loader"]
        )
        return [
            ResolvedModeProfile(
                id: InteractionMode.chat.rawValue,
                interactionMode: .chat,
                assemblyKind: .chat,
                allowsProactiveCompactionTriggers: false,
                appliesAgentBuildOrchestratorHarness: false,
                builtInSeedVersion: v,
                semanticLayerTags: [],
                tools: chatTools,
                runtime: chatRuntime,
                model: chatModel,
                subAgents: subSeed,
                hooks: transitionHooks
            ),
            ResolvedModeProfile(
                id: InteractionMode.plan.rawValue,
                interactionMode: .plan,
                assemblyKind: .planCollaboration,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: false,
                builtInSeedVersion: v,
                semanticLayerTags: [],
                tools: planTools,
                runtime: planRuntime,
                model: planModel,
                subAgents: subSeed,
                hooks: transitionHooks
            ),
            ResolvedModeProfile(
                id: InteractionMode.agent.rawValue,
                interactionMode: .agent,
                assemblyKind: .agentBuild,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: true,
                builtInSeedVersion: v,
                semanticLayerTags: [],
                tools: agentTools,
                runtime: agentRuntime,
                model: agentModel,
                subAgents: subSeed,
                hooks: transitionHooks
            ),
        ] + machineProfiles(seedVersion: v)
    }

    /// Least-privilege machine sub-agent profiles seeded as built-ins so that every confinement guarantee
    /// (`ConversationLineageInference.machineSubAgentModeProfileIDs`) resolves even if `PromptConfig.json` is
    /// absent, malformed, or missing an entry — `PromptConfig.json` may still overlay tuning on top.
    static func machineProfiles(seedVersion v: Int) -> [ResolvedModeProfile] {
        let disabledModel = ModeProfileModelSlice(thinkingConfig: .disabled)
        let denyAllSubAgents = ModeProfileSubAgentsSlice(allow: [])
        let memoryFileTools = ModeProfileToolsSlice(
            allow: ["read_file", "read_attachment", "write_file", "edit_file"],
            deny: []
        )
        // Suppress (not just empty) the skills + tool-guidance prompt sections so the chat preamble carries no dead tokens.
        let leanMachineContext = ModeProfileContextSlice(includeSkills: false, includeToolGuidance: false)

        func memoryChatProfile(
            id: String,
            tools: ModeProfileToolsSlice,
            maxIterations: Int = 5
        ) -> ResolvedModeProfile {
            ResolvedModeProfile(
                id: id,
                interactionMode: .chat,
                assemblyKind: .chat,
                allowsProactiveCompactionTriggers: false,
                appliesAgentBuildOrchestratorHarness: false,
                builtInSeedVersion: v,
                semanticLayerTags: [],
                tools: tools,
                context: leanMachineContext,
                runtime: ModeProfileRuntimeSlice(maxIterations: max(1, maxIterations)),
                model: disabledModel,
                subAgents: denyAllSubAgents
            )
        }

        return [
            ResolvedModeProfile(
                id: "subagent-minimal",
                interactionMode: .agent,
                assemblyKind: .agentBuild,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: true,
                builtInSeedVersion: v,
                semanticLayerTags: [],
                tools: ModeProfileToolsSlice(allow: [], deny: []),
                skills: ModeProfileSkillsSlice(allow: []),
                runtime: ModeProfileRuntimeSlice(maxIterations: 1),
                subAgents: denyAllSubAgents
            ),
            memoryChatProfile(
                id: "memory-active-recall",
                tools: ModeProfileToolsSlice(allow: ["memory_search", "memory_get"], deny: [])
            ),
            memoryChatProfile(id: "memory-extraction", tools: memoryFileTools),
            memoryChatProfile(
                id: "memory-pre-compaction-flush",
                tools: memoryFileTools,
                maxIterations: MemoryConfiguration.default.preCompactionFlushMaxIterations
            ),
            ResolvedModeProfile(
                id: "trigger-delegate",
                interactionMode: .agent,
                assemblyKind: .agentBuild,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: true,
                builtInSeedVersion: v,
                semanticLayerTags: [],
                tools: ModeProfileToolsSlice(
                    allow: ["read_file", "glob", "grep", "think"],
                    deny: [
                        "ask_user",
                        "memory_get",
                        "memory_search",
                        "memory_write",
                        "schedule_create",
                        "schedule_delete",
                        "schedule_fire_now",
                        "schedule_list",
                        "spawn_sub_agent",
                    ],
                    approvalPolicy: .never
                ),
                skills: ModeProfileSkillsSlice(allow: []),
                runtime: ModeProfileRuntimeSlice(maxIterations: 8),
                model: disabledModel,
                subAgents: ModeProfileSubAgentsSlice(allow: [], maxDepth: 0)
            ),
        ]
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension ResolvedModeProfile {
    static func builtIn(for interactionMode: InteractionMode) -> ResolvedModeProfile {
        ModeProfileBuiltInCatalog.profile(for: interactionMode)
    }

    /// Synthetic root used when config introduces a **new** mode id without extending a built-in row.
    static func syntheticSeed(
        id: String,
        interactionMode: InteractionMode,
        assemblyKind: SystemPromptAssemblyKind
    ) -> ResolvedModeProfile {
        ResolvedModeProfile(
            id: id,
            interactionMode: interactionMode,
            assemblyKind: assemblyKind,
            allowsProactiveCompactionTriggers: interactionMode != .chat,
            appliesAgentBuildOrchestratorHarness: interactionMode == .agent && assemblyKind == .agentBuild,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            subAgents: .harnessDefaultChildSpawnSeed()
        )
    }
}
