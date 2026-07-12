
import Foundation

public struct ServerConfig {
    public var port: Int = 8080
    public var enableDiscovery: Bool = false
    public var logLevel: String = "info"

    /// If set, SwiftData uses this file URL for the store; otherwise the default Application Support path is used.
    public var dataStorePath: String? = nil
    /// When false, SwiftData is opened with `allowsSave: false` (read-only intent). Copy production stores to a scratch path if you hit WAL/permissions issues.
    public var swiftDataAllowsSave: Bool = true

    /// When true, `POST /api/conversations/:id/preview-context-compaction` is registered (requires `contextCompactionPreviewToken` to be non-empty).
    public var enableContextCompactionPreviewAPI: Bool = false
    /// Must match the `X-SAH-Context-Compaction-Preview-Token` header. Required when the preview API is enabled.
    public var contextCompactionPreviewToken: String? = nil

    /// When set (> 0), soft-deleted conversations older than this window are hard-deleted by a background purge loop.
    public var softDeleteRetentionDays: Int? = nil
    /// Interval between purge sweep attempts when ``softDeleteRetentionDays`` is enabled.
    public var softDeletePurgeIntervalSeconds: UInt64 = 3600
    /// Enables periodic physical pruning of superseded derived artifacts/checkpoints.
    public var derivedRetentionWorkerEnabled: Bool = false
    /// Interval between derived-retention sweep attempts when enabled.
    public var derivedRetentionSweepIntervalSeconds: UInt64 = 3600
    /// Maximum number of rows deleted in one derived-retention sweep.
    public var derivedRetentionBatchLimit: Int = 500
    /// When true, prune only artifacts proven superseded by invalidation markers.
    public var derivedRetentionSupersededOnly: Bool = true
    /// When true, sweep also removes orphan derived rows/snapshots for missing conversations.
    public var derivedRetentionPruneOrphans: Bool = true
    /// Optional override for trust-policy mode (`none`, `gateExecution`, `downgradeContext`, `gateAndDowngrade`).
    public var trustPolicyModeOverrideRaw: String? = nil
    /// Optional override for default policy class (`trusted`, `low_trust`) used for unknown trust values.
    public var trustPolicySafeDefaultClassOverrideRaw: String? = nil
    /// Optional override for publishing governance mode (`strict` or `soft`).
    public var publishingGovernanceModeOverrideRaw: String? = nil
    /// Optional override to enable/disable publishing-governance diagnostics logging.
    public var publishingGovernanceDiagnosticsEnabledOverride: Bool? = nil
    /// When true, guarded HTTP mutation routes require `If-Match` and return 428 when absent.
    public var httpPreconditionsStrictMode: Bool = true
    /// Composition-root context engine slot id (`default`, `noop`).
    public var contextEngineSlotID: String = "default"
    /// Global cap for concurrent main-loop runs across this process.
    public var runtimeGlobalMainLaneLimit: Int = 4
    /// Global cap for concurrent sub-agent runs across this process.
    public var runtimeGlobalSubagentLaneLimit: Int = 8
    /// Per-parent cap for concurrently active child runs.
    public var runtimeMaxChildrenPerAgent: Int = 5
    /// Enables pool-owned response cache wrapping in Model Pool (default off).
    public var modelPoolResponseCacheEnabled: Bool = false
    /// Maximum entries for response cache when enabled.
    public var modelPoolResponseCacheMaxEntries: Int = 512
    /// Optional TTL (seconds) for response cache entries.
    public var modelPoolResponseCacheTTLSeconds: Double? = nil
    /// Optional stable prefix message count for response cache keys.
    public var modelPoolResponseCacheStablePrefixMessageCount: Int? = nil
    /// Enables prompt-cache planning seam in Model Pool (default off/no-op planner).
    public var modelPoolPromptCachePlanningEnabled: Bool = false
    /// Override model-pool budget enforcement (`true` = enabled, `false` = disabled).
    public var modelPoolBudgetEnabledOverride: Bool? = nil
    public var modelPoolMaxUSDPerCallOverride: Double? = nil
    public var modelPoolMaxUSDPerConversationOverride: Double? = nil
    public var modelPoolMaxUSDGlobalOverride: Double? = nil
    public var modelPoolMaxUSDPerAccountOverride: Double? = nil
    public var modelPoolDenyWhenUnknownProjectedCostOverride: Bool? = nil
    public var modelPoolFailoverMaxRetriesOverride: Int? = nil
    public var modelPoolFailoverBaseDelayOverride: TimeInterval? = nil
    public var modelPoolFailoverMaxDelayOverride: TimeInterval? = nil
    /// Override provider preference order for multi-binding merge (first = primary).
    public var modelPoolProviderPreferenceOrderOverride: [ProviderID]? = nil
    /// Poll interval for dynamic capability discovery refresh (`tools/registry` etc.).
    public var dynamicCapabilityDiscoveryPollSeconds: UInt64 = 15
    /// Optional HMAC secret for signed `conversation/{id}/events` resume tokens on WebSocket subscribe. When unset, clients cannot use `resumeToken`.
    public var websocketResumeTokenHMACSecret: String? = nil
    /// Count-based replay retention defaults for communication-layer topic classes.
    public var topicReplayCapacities: TopicReplayCapacityConfiguration = .default
    /// WebSocket harness outbound flow control (`ack` / buffering); enabled by default.
    public var websocketOutboundFlowConfiguration: WebSocketOutboundFlowConfiguration = .init()
    /// Runtime outbound schema enforcement for websocket topic/control frames.
    public var websocketOutboundSchemaEnforcementConfiguration: WebSocketOutboundSchemaEnforcementConfiguration = .default
    /// Default TTL (seconds) for inbound `dedupe_check_and_set` when `dedupeTtlSeconds` is omitted (minutes-scale policy).
    public var websocketInboundDedupeDefaultTtlSeconds: Int = 600
    /// Maximum TTL (seconds) accepted for inbound dedupe; larger client values are clamped.
    public var websocketInboundDedupeMaxTtlSeconds: Int = 3600

    /// HS256 secret for verifying inbound ``Authorization: Bearer`` harness access JWTs. Required when ``requireAuthenticatedTenantOnAPI`` is true.
    public var apiAccessTokenHS256Secret: String? = nil
    /// Optional JWT `iss` claim enforcement for harness access tokens.
    public var apiAccessTokenIssuer: String? = nil
    /// Optional JWT `aud` claim enforcement for harness access tokens.
    public var apiAccessTokenAudience: String? = nil

    /// When true, mutating `/api` routes require a validated Bearer JWT owner and conversation rows must match that UUID.
    public var requireAuthenticatedTenantOnAPI: Bool = false
    /// Owner account UUIDs permitted to subscribe to `trace/server` when operator enforcement is active.
    public var serverTraceOperatorOwnerIDs: Set<UUID> = []
    /// When true, `trace/server` and `pool/health` subscribe require an allowlisted operator owner.
    /// Auto-engaged when ``requireAuthenticatedTenantOnAPI`` is true.
    public var enforceOperatorForServerTraceSubscribe: Bool = true
    /// Maximum ``PUT /api/conversations/:id/engine-artifacts/:key`` body size (bytes).
    public var engineArtifactMaxUploadBytes: Int = 16_777_216
    /// Optional override for Application Support directory naming and related on-disk layout.
    public var hostLayout: HarnessHostLayout? = nil
    /// When true, CLI/embedded hosts may resolve sanctioned ambient workspace and backfill ``ModelConversation/harnessPersistenceCwd`` once.
    public var allowAmbientWorkspaceFallback: Bool = false

    public init(
        port: Int = 8080,
        enableDiscovery: Bool = false,
        logLevel: String = "info",
        dataStorePath: String? = nil,
        swiftDataAllowsSave: Bool = true,
        enableContextCompactionPreviewAPI: Bool = false,
        contextCompactionPreviewToken: String? = nil,
        softDeleteRetentionDays: Int? = nil,
        softDeletePurgeIntervalSeconds: UInt64 = 3600,
        derivedRetentionWorkerEnabled: Bool = false,
        derivedRetentionSweepIntervalSeconds: UInt64 = 3600,
        derivedRetentionBatchLimit: Int = 500,
        derivedRetentionSupersededOnly: Bool = true,
        derivedRetentionPruneOrphans: Bool = true,
        trustPolicyModeOverrideRaw: String? = nil,
        trustPolicySafeDefaultClassOverrideRaw: String? = nil,
        publishingGovernanceModeOverrideRaw: String? = nil,
        publishingGovernanceDiagnosticsEnabledOverride: Bool? = nil,
        httpPreconditionsStrictMode: Bool = true,
        contextEngineSlotID: String = "default",
        runtimeGlobalMainLaneLimit: Int = 4,
        runtimeGlobalSubagentLaneLimit: Int = 8,
        runtimeMaxChildrenPerAgent: Int = 5,
        modelPoolResponseCacheEnabled: Bool = false,
        modelPoolResponseCacheMaxEntries: Int = 512,
        modelPoolResponseCacheTTLSeconds: Double? = nil,
        modelPoolResponseCacheStablePrefixMessageCount: Int? = nil,
        modelPoolPromptCachePlanningEnabled: Bool = false,
        modelPoolBudgetEnabledOverride: Bool? = nil,
        modelPoolMaxUSDPerCallOverride: Double? = nil,
        modelPoolMaxUSDPerConversationOverride: Double? = nil,
        modelPoolMaxUSDGlobalOverride: Double? = nil,
        modelPoolMaxUSDPerAccountOverride: Double? = nil,
        modelPoolDenyWhenUnknownProjectedCostOverride: Bool? = nil,
        modelPoolFailoverMaxRetriesOverride: Int? = nil,
        modelPoolFailoverBaseDelayOverride: TimeInterval? = nil,
        modelPoolFailoverMaxDelayOverride: TimeInterval? = nil,
        modelPoolProviderPreferenceOrderOverride: [ProviderID]? = nil,
        dynamicCapabilityDiscoveryPollSeconds: UInt64 = 15,
        websocketResumeTokenHMACSecret: String? = nil,
        topicReplayCapacities: TopicReplayCapacityConfiguration = .default,
        websocketOutboundFlowConfiguration: WebSocketOutboundFlowConfiguration = .init(),
        websocketOutboundSchemaEnforcementConfiguration: WebSocketOutboundSchemaEnforcementConfiguration = .default,
        websocketInboundDedupeDefaultTtlSeconds: Int = 600,
        websocketInboundDedupeMaxTtlSeconds: Int = 3600,
        apiAccessTokenHS256Secret: String? = nil,
        apiAccessTokenIssuer: String? = nil,
        apiAccessTokenAudience: String? = nil,
        requireAuthenticatedTenantOnAPI: Bool = false,
        serverTraceOperatorOwnerIDs: Set<UUID> = [],
        enforceOperatorForServerTraceSubscribe: Bool = true,
        engineArtifactMaxUploadBytes: Int = 16_777_216,
        hostLayout: HarnessHostLayout? = nil,
        allowAmbientWorkspaceFallback: Bool = false
    ) {
        self.port = port
        self.enableDiscovery = enableDiscovery
        self.logLevel = logLevel
        self.dataStorePath = dataStorePath
        self.swiftDataAllowsSave = swiftDataAllowsSave
        self.enableContextCompactionPreviewAPI = enableContextCompactionPreviewAPI
        self.contextCompactionPreviewToken = contextCompactionPreviewToken
        self.softDeleteRetentionDays = softDeleteRetentionDays
        self.softDeletePurgeIntervalSeconds = softDeletePurgeIntervalSeconds
        self.derivedRetentionWorkerEnabled = derivedRetentionWorkerEnabled
        self.derivedRetentionSweepIntervalSeconds = derivedRetentionSweepIntervalSeconds
        self.derivedRetentionBatchLimit = max(1, derivedRetentionBatchLimit)
        self.derivedRetentionSupersededOnly = derivedRetentionSupersededOnly
        self.derivedRetentionPruneOrphans = derivedRetentionPruneOrphans
        self.trustPolicyModeOverrideRaw = trustPolicyModeOverrideRaw
        self.trustPolicySafeDefaultClassOverrideRaw = trustPolicySafeDefaultClassOverrideRaw
        self.publishingGovernanceModeOverrideRaw = publishingGovernanceModeOverrideRaw
        self.publishingGovernanceDiagnosticsEnabledOverride = publishingGovernanceDiagnosticsEnabledOverride
        self.httpPreconditionsStrictMode = httpPreconditionsStrictMode
        self.contextEngineSlotID = contextEngineSlotID
        self.runtimeGlobalMainLaneLimit = max(1, runtimeGlobalMainLaneLimit)
        self.runtimeGlobalSubagentLaneLimit = max(1, runtimeGlobalSubagentLaneLimit)
        self.runtimeMaxChildrenPerAgent = min(20, max(1, runtimeMaxChildrenPerAgent))
        self.modelPoolResponseCacheEnabled = modelPoolResponseCacheEnabled
        self.modelPoolResponseCacheMaxEntries = max(1, modelPoolResponseCacheMaxEntries)
        self.modelPoolResponseCacheTTLSeconds = modelPoolResponseCacheTTLSeconds
        self.modelPoolResponseCacheStablePrefixMessageCount = modelPoolResponseCacheStablePrefixMessageCount
        self.modelPoolPromptCachePlanningEnabled = modelPoolPromptCachePlanningEnabled
        self.modelPoolBudgetEnabledOverride = modelPoolBudgetEnabledOverride
        self.modelPoolMaxUSDPerCallOverride = modelPoolMaxUSDPerCallOverride
        self.modelPoolMaxUSDPerConversationOverride = modelPoolMaxUSDPerConversationOverride
        self.modelPoolMaxUSDGlobalOverride = modelPoolMaxUSDGlobalOverride
        self.modelPoolMaxUSDPerAccountOverride = modelPoolMaxUSDPerAccountOverride
        self.modelPoolDenyWhenUnknownProjectedCostOverride = modelPoolDenyWhenUnknownProjectedCostOverride
        self.modelPoolFailoverMaxRetriesOverride = modelPoolFailoverMaxRetriesOverride.map { max(0, $0) }
        self.modelPoolFailoverBaseDelayOverride = modelPoolFailoverBaseDelayOverride.map { max(0, $0) }
        self.modelPoolFailoverMaxDelayOverride = modelPoolFailoverMaxDelayOverride.map { max(0, $0) }
        self.modelPoolProviderPreferenceOrderOverride = modelPoolProviderPreferenceOrderOverride
        self.dynamicCapabilityDiscoveryPollSeconds = max(1, dynamicCapabilityDiscoveryPollSeconds)
        self.websocketResumeTokenHMACSecret = websocketResumeTokenHMACSecret
        self.topicReplayCapacities = topicReplayCapacities
        self.websocketOutboundFlowConfiguration = websocketOutboundFlowConfiguration
        self.websocketOutboundSchemaEnforcementConfiguration = websocketOutboundSchemaEnforcementConfiguration
        self.websocketInboundDedupeDefaultTtlSeconds = max(60, websocketInboundDedupeDefaultTtlSeconds)
        self.websocketInboundDedupeMaxTtlSeconds = max(self.websocketInboundDedupeDefaultTtlSeconds, websocketInboundDedupeMaxTtlSeconds)
        self.apiAccessTokenHS256Secret = apiAccessTokenHS256Secret
        self.apiAccessTokenIssuer = apiAccessTokenIssuer
        self.apiAccessTokenAudience = apiAccessTokenAudience
        self.requireAuthenticatedTenantOnAPI = requireAuthenticatedTenantOnAPI
        self.serverTraceOperatorOwnerIDs = serverTraceOperatorOwnerIDs
        self.enforceOperatorForServerTraceSubscribe = enforceOperatorForServerTraceSubscribe
        self.engineArtifactMaxUploadBytes = max(1024, engineArtifactMaxUploadBytes)
        self.hostLayout = hostLayout
        self.allowAmbientWorkspaceFallback = allowAmbientWorkspaceFallback
    }

    /// Resolved trace/server subscribe policy (multi-tenant mode always enforces operator allowlist).
    public func resolvedServerTraceSubscribePolicy() -> ServerTraceSubscribePolicy {
        let enforce = requireAuthenticatedTenantOnAPI || enforceOperatorForServerTraceSubscribe
        return ServerTraceSubscribePolicy(
            enforceOperatorAllowlist: enforce,
            operatorOwnerIDs: serverTraceOperatorOwnerIDs
        )
    }

    /// Tenancy policy derived from ``requireAuthenticatedTenantOnAPI``.
    public func tenancyPolicySettings() -> TenancyPolicySettings {
        TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: requireAuthenticatedTenantOnAPI)
    }

    /// Builds the JWT access-token validator when ``apiAccessTokenHS256Secret`` is non-empty.
    public func makeAPIAccessTokenValidator() -> JWTAPIAccessTokenValidator? {
        guard let secret = apiAccessTokenHS256Secret, !secret.isEmpty else { return nil }
        return JWTAPIAccessTokenValidator(
            settings: APIAccessTokenAuthenticationSettings(
                hs256Secret: secret,
                issuer: apiAccessTokenIssuer,
                audience: apiAccessTokenAudience
            )
        )
    }

    /// Access-token auth settings when a secret is configured.
    public func apiAccessTokenAuthenticationSettings() -> APIAccessTokenAuthenticationSettings? {
        guard let secret = apiAccessTokenHS256Secret, !secret.isEmpty else { return nil }
        return APIAccessTokenAuthenticationSettings(
            hs256Secret: secret,
            issuer: apiAccessTokenIssuer,
            audience: apiAccessTokenAudience
        )
    }
}
