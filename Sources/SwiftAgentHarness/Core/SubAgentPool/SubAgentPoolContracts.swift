import Foundation
import EasyJSON
import SwiftAgentKit
import SwiftAgentKitOrchestrator

enum SubAgentPermissionPolicy: String, Codable, Sendable, Equatable {
    case auto
    case askParent = "ask-parent"
    case askUser = "ask-user"
}

enum SubAgentTrustLevel: String, Codable, Sendable, Equatable {
    case system
    case userDeferred = "user-deferred"
    case knownParty = "known-party"
    case unknownParty = "unknown-party"
}

public struct SubAgentHostingPolicy: Sendable, Codable, Equatable {
    public var hostPersonaID: String?
    public var delegationAllowlist: [String]
    public var authScopeTags: [String]
    public var routingDomain: String?
    public var tenantScope: String?

    public init(
        hostPersonaID: String? = nil,
        delegationAllowlist: [String] = [],
        authScopeTags: [String] = [],
        routingDomain: String? = nil,
        tenantScope: String? = nil
    ) {
        self.hostPersonaID = hostPersonaID
        self.delegationAllowlist = delegationAllowlist
        self.authScopeTags = authScopeTags
        self.routingDomain = routingDomain
        self.tenantScope = tenantScope
    }
}

struct SubAgentRoutingContext: Sendable, Codable, Equatable {
    var hostPersonaID: String?
    var authScopeTags: [String]
    var routingDomain: String?
    var tenantScope: String?

    init(
        hostPersonaID: String? = nil,
        authScopeTags: [String] = [],
        routingDomain: String? = nil,
        tenantScope: String? = nil
    ) {
        self.hostPersonaID = hostPersonaID
        self.authScopeTags = authScopeTags
        self.routingDomain = routingDomain
        self.tenantScope = tenantScope
    }
}

enum SubAgentTransportKind: String, Codable, Sendable, CaseIterable {
    case a2a
    case inProcess = "in-process"
    case acpStdio = "acp-stdio"
    case customEndpoint = "custom-endpoint"
    case unknown

    init(rawOrAlias value: String?) {
        guard let value else {
            self = .unknown
            return
        }
        switch value.lowercased() {
        case "a2a":
            self = .a2a
        case "in-process", "inprocess", "local":
            self = .inProcess
        case "acp-stdio", "acp_stdio", "acp":
            self = .acpStdio
        case "custom-endpoint", "custom_endpoint", "endpoint":
            self = .customEndpoint
        default:
            self = .unknown
        }
    }
}

struct SubAgentTransportCapabilities: Sendable, Equatable {
    var transportKind: SubAgentTransportKind
    var supportsStreaming: Bool
    var supportsLongRunning: Bool
    var maxRecursionDepth: Int?
    var useClasses: [String]
}

enum SubAgentRecursionLimits {
    /// Fail-closed ceiling when no registry, mode-profile, or transport cap resolves.
    static let absoluteMaxDepthFallback = 3
}

struct SubAgentTransportInvocationRequest: Sendable {
    var launchPlan: SubAgentLaunchPlan
    var registryEntry: SubAgentRegistryEntry
    var toolEntry: ToolRegistryEntry
    var parentConversationID: UUID
}

struct SubAgentTransportInvocationCorrelation: Sendable, Equatable {
    var lifecycleID: String
    var transportKind: SubAgentTransportKind
    var sessionHandleID: String
    var completionHandleID: String?
}

typealias SubAgentDelegateCompletionUsage = DelegateCompletionUsagePayload

enum SubAgentDelegateEventPhase: String, Sendable, Equatable {
    case queued
    case dispatching
    case running
    case awaitingApproval = "awaiting-approval"
    case completing
    case done
    case failed
    case orphaned
}

struct SubAgentDelegateEvent: Sendable, Equatable {
    var lifecycleID: String
    var parentConversationID: UUID
    var childConversationID: UUID?
    var delegateToolName: String?
    var asyncHandleID: String?
    var phase: SubAgentDelegateEventPhase
    var eventTrustLevel: String?
    var defaultTrustLevel: String?
    var permissionPolicy: String?
    var approvalRoute: ToolApprovalRoute?
    var completionAnnounceID: UUID?
    var toolCallID: String?
    var completionSource: String?
    var completionUsage: SubAgentDelegateCompletionUsage?
    var error: String?
    var runtimeLifecycleEvent: RuntimeLifecycleEventPayload?
    var updatedAt: Date

    init(
        lifecycleID: String,
        parentConversationID: UUID,
        childConversationID: UUID? = nil,
        delegateToolName: String? = nil,
        asyncHandleID: String? = nil,
        phase: SubAgentDelegateEventPhase,
        eventTrustLevel: String? = nil,
        defaultTrustLevel: String? = nil,
        permissionPolicy: String? = nil,
        approvalRoute: ToolApprovalRoute? = nil,
        completionAnnounceID: UUID? = nil,
        toolCallID: String? = nil,
        completionSource: String? = nil,
        completionUsage: SubAgentDelegateCompletionUsage? = nil,
        error: String? = nil,
        runtimeLifecycleEvent: RuntimeLifecycleEventPayload? = nil,
        updatedAt: Date = Date()
    ) {
        self.lifecycleID = lifecycleID
        self.parentConversationID = parentConversationID
        self.childConversationID = childConversationID
        self.delegateToolName = delegateToolName
        self.asyncHandleID = asyncHandleID
        self.phase = phase
        self.eventTrustLevel = eventTrustLevel
        self.defaultTrustLevel = defaultTrustLevel
        self.permissionPolicy = permissionPolicy
        self.approvalRoute = approvalRoute
        self.completionAnnounceID = completionAnnounceID
        self.toolCallID = toolCallID
        self.completionSource = completionSource
        self.completionUsage = completionUsage
        self.error = error
        self.runtimeLifecycleEvent = runtimeLifecycleEvent
        self.updatedAt = updatedAt
    }
}

struct SubAgentTransportDelegateEventsRequest: Sendable {
    var correlation: SubAgentTransportInvocationCorrelation
    var parentConversationID: UUID
}

enum SubAgentTransportInvocationOutcome: Sendable, Equatable {
    case delegatedToHostInProcess
    case remoteStarted(correlation: SubAgentTransportInvocationCorrelation)
}

struct SubAgentTransportInvocationResult: Sendable {
    var outcome: SubAgentTransportInvocationOutcome
    var delegateEvents: [SubAgentDelegateEvent]

    init(
        outcome: SubAgentTransportInvocationOutcome,
        delegateEvents: [SubAgentDelegateEvent] = []
    ) {
        self.outcome = outcome
        self.delegateEvents = delegateEvents
    }
}

struct SubAgentTransportCancellationRequest: Sendable {
    var lifecycleID: String
    var transportKind: SubAgentTransportKind
    var sessionHandleID: String
    var completionHandleID: String?
}

enum SubAgentTransportCancellationDisposition: Sendable, Equatable {
    case noAction
    case cancellationRequested
    case cancelled
}

struct SubAgentTransportCancellationResult: Sendable, Equatable {
    var disposition: SubAgentTransportCancellationDisposition
    var note: String?
    var delegateEvents: [SubAgentDelegateEvent]

    init(
        disposition: SubAgentTransportCancellationDisposition,
        note: String? = nil,
        delegateEvents: [SubAgentDelegateEvent] = []
    ) {
        self.disposition = disposition
        self.note = note
        self.delegateEvents = delegateEvents
    }
}

enum SubAgentTransportPermissionDecision: String, Sendable, Codable, Equatable {
    case approved
    case denied
}

struct SubAgentTransportPermissionResolutionRequest: Sendable {
    var lifecycleID: String
    var transportKind: SubAgentTransportKind
    var sessionHandleID: String
    var completionHandleID: String?
    var parentConversationID: UUID
    var approvalRoute: ToolApprovalRoute
    var decision: SubAgentTransportPermissionDecision
    var source: String
}

enum SubAgentTransportPermissionResolutionDisposition: Sendable, Equatable {
    case noAction
    case resumed
    case cancelled
}

struct SubAgentTransportPermissionResolutionResult: Sendable, Equatable {
    var disposition: SubAgentTransportPermissionResolutionDisposition
    var note: String?
    var correlation: SubAgentTransportInvocationCorrelation?
    var delegateEvents: [SubAgentDelegateEvent]

    init(
        disposition: SubAgentTransportPermissionResolutionDisposition,
        note: String? = nil,
        correlation: SubAgentTransportInvocationCorrelation? = nil,
        delegateEvents: [SubAgentDelegateEvent] = []
    ) {
        self.disposition = disposition
        self.note = note
        self.correlation = correlation
        self.delegateEvents = delegateEvents
    }
}

struct SubAgentTransportRecoveryRequest: Sendable {
    var lifecycleID: String
    var transportKind: SubAgentTransportKind
    var sessionHandleID: String
    var completionHandleID: String?
}

enum SubAgentTransportRecoveryDisposition: Sendable, Equatable {
    case noAction
    case cancelled
    case resumed
}

struct SubAgentTransportRecoveryResult: Sendable, Equatable {
    var disposition: SubAgentTransportRecoveryDisposition
    var note: String?
    var correlation: SubAgentTransportInvocationCorrelation?
    var delegateEvents: [SubAgentDelegateEvent]

    init(
        disposition: SubAgentTransportRecoveryDisposition,
        note: String? = nil,
        correlation: SubAgentTransportInvocationCorrelation? = nil,
        delegateEvents: [SubAgentDelegateEvent] = []
    ) {
        self.disposition = disposition
        self.note = note
        self.correlation = correlation
        self.delegateEvents = delegateEvents
    }
}

protocol SubAgentTransportAdapting: Sendable {
    var id: String { get }
    var transportKind: SubAgentTransportKind { get }
    var capabilities: SubAgentTransportCapabilities { get }
    func invoke(_ request: SubAgentTransportInvocationRequest) async throws -> SubAgentTransportInvocationResult
    func delegateEvents(_ request: SubAgentTransportDelegateEventsRequest) async -> AsyncStream<SubAgentDelegateEvent>
    func cancel(_ request: SubAgentTransportCancellationRequest) async throws -> SubAgentTransportCancellationResult
    func resolvePermission(_ request: SubAgentTransportPermissionResolutionRequest) async throws -> SubAgentTransportPermissionResolutionResult
    func recover(_ request: SubAgentTransportRecoveryRequest) async throws -> SubAgentTransportRecoveryResult
}

extension SubAgentTransportAdapting {
    func delegateEvents(_ request: SubAgentTransportDelegateEventsRequest) async -> AsyncStream<SubAgentDelegateEvent> {
        _ = request
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func cancel(_ request: SubAgentTransportCancellationRequest) async throws -> SubAgentTransportCancellationResult {
        _ = request
        return SubAgentTransportCancellationResult(disposition: .noAction)
    }

    func resolvePermission(_ request: SubAgentTransportPermissionResolutionRequest) async throws -> SubAgentTransportPermissionResolutionResult {
        _ = request
        return SubAgentTransportPermissionResolutionResult(disposition: .noAction)
    }

    func recover(_ request: SubAgentTransportRecoveryRequest) async throws -> SubAgentTransportRecoveryResult {
        _ = request
        return SubAgentTransportRecoveryResult(disposition: .noAction)
    }
}

protocol SubAgentTransportAdapterResolving: Sendable {
    func adapter(for transportKind: SubAgentTransportKind) -> (any SubAgentTransportAdapting)?
    func adapter(for registryEntry: SubAgentRegistryEntry) -> (any SubAgentTransportAdapting)?
}

/// Unified registry row for `sub-agents/registry` v2.
struct SubAgentRegistryEntry: Codable, Sendable, Equatable {
    var agentID: String
    var displayName: String
    var description: String
    var delegateToolName: String
    var source: ToolListingSource
    var transportKind: String
    var useClasses: [String]
    var maxRecursionDepth: Int?
    var streaming: Bool?
    var longRunning: Bool?
    var defaultTrustLevel: SubAgentTrustLevel
    var permissionPolicy: SubAgentPermissionPolicy
    var hostingPolicy: SubAgentHostingPolicy
    var availableToolInfo: AvailableToolInfo

    init(
        agentID: String,
        displayName: String,
        description: String,
        delegateToolName: String,
        source: ToolListingSource,
        transportKind: String,
        useClasses: [String] = [],
        maxRecursionDepth: Int? = nil,
        streaming: Bool? = nil,
        longRunning: Bool? = nil,
        defaultTrustLevel: SubAgentTrustLevel = .unknownParty,
        permissionPolicy: SubAgentPermissionPolicy = .askUser,
        hostingPolicy: SubAgentHostingPolicy = SubAgentHostingPolicy(),
        availableToolInfo: AvailableToolInfo
    ) {
        self.agentID = agentID
        self.displayName = displayName
        self.description = description
        self.delegateToolName = delegateToolName
        self.source = source
        self.transportKind = transportKind
        self.useClasses = useClasses
        self.maxRecursionDepth = maxRecursionDepth
        self.streaming = streaming
        self.longRunning = longRunning
        self.defaultTrustLevel = defaultTrustLevel
        self.permissionPolicy = permissionPolicy
        self.hostingPolicy = hostingPolicy
        self.availableToolInfo = availableToolInfo
    }
}

extension SubAgentRegistryEntry {
    var wirePayload: SubAgentRegistryEntryPayload {
        SubAgentRegistryEntryPayload(
            agentID: agentID,
            displayName: displayName,
            description: description,
            delegateToolName: delegateToolName,
            source: source,
            transportKind: transportKind,
            useClasses: useClasses,
            maxRecursionDepth: maxRecursionDepth,
            streaming: streaming,
            longRunning: longRunning,
            defaultTrustLevel: defaultTrustLevel.rawValue,
            permissionPolicy: permissionPolicy.rawValue,
            hostPersonaID: hostingPolicy.hostPersonaID,
            delegationAllowlist: hostingPolicy.delegationAllowlist,
            authScopeTags: hostingPolicy.authScopeTags,
            routingDomain: hostingPolicy.routingDomain,
            tenantScope: hostingPolicy.tenantScope,
            tool: availableToolInfo
        )
    }
}

protocol SubAgentToolClassifying: Sendable {
    func isDelegateTool(entry: ToolRegistryEntry) -> Bool
    func permissionPolicy(for entry: ToolRegistryEntry) -> SubAgentPermissionPolicy
    func trustLevel(for entry: ToolRegistryEntry) -> SubAgentTrustLevel
    func maxRecursionDepth(for entry: ToolRegistryEntry) -> Int?
}

/// Normalized launch contract shared across API and delegate launch paths.
struct SubAgentLaunchRequest: Sendable {
    var context: SubAgentLaunchContext
    var userMessageID: UUID?
    var taskDescription: String?
    var prompt: String?
    var subagentType: String?
    var modelRef: String?
    var runInBackground: Bool
    var agentID: String?
    var agentRef: String?
    var agentQuery: SubAgentQuery?
    var routingContext: SubAgentRoutingContext
    var userSystemPrompt: String?
    var topic: String?
    var description: String?
    var metadata: JSON?
    var interactionMode: String?
    /// Optional closed-world tool allowlist → child `routingPrefs.explicitToolPolicy`.
    var toolsAllow: [String]?
    /// Harness-internal trust signal: delegate tool approval already cleared upstream (model-turn path only).
    var permissionAlreadyGranted: Bool

    init(
        context: SubAgentLaunchContext,
        userMessageID: UUID? = nil,
        taskDescription: String? = nil,
        prompt: String? = nil,
        subagentType: String? = nil,
        modelRef: String? = nil,
        runInBackground: Bool = false,
        agentID: String? = nil,
        agentRef: String? = nil,
        agentQuery: SubAgentQuery? = nil,
        routingContext: SubAgentRoutingContext = SubAgentRoutingContext(),
        userSystemPrompt: String? = nil,
        topic: String? = nil,
        description: String? = nil,
        metadata: JSON? = nil,
        interactionMode: String? = nil,
        toolsAllow: [String]? = nil,
        permissionAlreadyGranted: Bool = false
    ) {
        self.context = context
        self.userMessageID = userMessageID
        self.taskDescription = taskDescription
        self.prompt = prompt
        self.subagentType = subagentType
        self.modelRef = modelRef
        self.runInBackground = runInBackground
        self.agentID = agentID
        self.agentRef = agentRef
        self.agentQuery = agentQuery
        self.routingContext = routingContext
        self.userSystemPrompt = userSystemPrompt
        self.topic = topic
        self.description = description
        self.metadata = metadata
        self.interactionMode = interactionMode
        self.toolsAllow = toolsAllow
        self.permissionAlreadyGranted = permissionAlreadyGranted
    }

    init(spawnRequest request: SubAgentSpawnRequest) {
        self.init(
            context: request.resolvedContext(),
            userMessageID: request.userMessageID,
            taskDescription: request.taskDescription,
            prompt: request.prompt,
            subagentType: request.subagentType,
            modelRef: request.modelRef,
            runInBackground: request.runInBackground ?? false,
            agentID: request.agentID,
            agentRef: request.preferredAgentRef(),
            agentQuery: request.agentQuery,
            routingContext: SubAgentRoutingContext(
                hostPersonaID: request.hostPersonaID,
                authScopeTags: request.authScopeTags ?? request.agentQuery?.authScopeTags ?? [],
                routingDomain: request.routingDomain ?? request.agentQuery?.routingDomain,
                tenantScope: request.tenantScope ?? request.agentQuery?.tenantScope
            ),
            userSystemPrompt: request.userSystemPrompt,
            topic: request.topic,
            description: request.description,
            metadata: Self.sanitizedClientMetadata(request.metadata),
            interactionMode: request.interactionMode,
            toolsAllow: request.toolsAllow,
            permissionAlreadyGranted: false
        )
    }

    static func sanitizedClientMetadata(_ metadata: JSON?) -> JSON? {
        guard case .object(var object) = metadata else { return metadata }
        object = object.filter { key, _ in
            !key.lowercased().hasPrefix("permission")
        }
        return object.isEmpty ? nil : .object(object)
    }
}

struct SubAgentLaunchPlan: Sendable {
    var spawnPlan: SubAgentSpawnPlan
    var request: SubAgentLaunchRequest
    /// Stable async handle for `runInBackground` launches.
    var asyncHandleID: String?
    var delegationContext: SubAgentDelegationContext
}

enum SubAgentPoolError: Error, Sendable, Equatable {
    case unavailable(reference: String)
    case lifecycleNotFound(lifecycleID: String)
    case transportUnavailable(kind: SubAgentTransportKind)
    case admissionRejected(reason: String)
    case operationFailed(reason: String)
}

enum SubAgentRequestPriority: Sendable, Equatable {
    case foreground
    case background
}

struct SubAgentRunReservation: Sendable, Equatable {
    var parentConversationID: UUID
    var parentRunID: UUID?
    var ownerAccountID: UUID?
    var lifecycleID: String
    var priority: SubAgentRequestPriority

    init(
        parentConversationID: UUID,
        parentRunID: UUID? = nil,
        ownerAccountID: UUID? = nil,
        lifecycleID: String,
        priority: SubAgentRequestPriority = .foreground
    ) {
        self.parentConversationID = parentConversationID
        self.parentRunID = parentRunID
        self.ownerAccountID = ownerAccountID
        self.lifecycleID = lifecycleID
        self.priority = priority
    }
}

struct SubAgentRunAcquisition: Sendable, Equatable {
    var reservation: SubAgentRunReservation
    var runID: UUID

    init(reservation: SubAgentRunReservation, runID: UUID) {
        self.reservation = reservation
        self.runID = runID
    }
}

protocol SubAgentRunScheduling: Sendable {
    func acquire(reservation: SubAgentRunReservation) async throws -> SubAgentRunAcquisition
    func release(acquisition: SubAgentRunAcquisition) async
    func inFlightCount(parentConversationID: UUID) async -> Int
}

struct NoOpSubAgentRunScheduler: SubAgentRunScheduling {
    func acquire(reservation: SubAgentRunReservation) async throws -> SubAgentRunAcquisition {
        SubAgentRunAcquisition(reservation: reservation, runID: UUID())
    }

    func release(acquisition: SubAgentRunAcquisition) async {
        _ = acquisition
    }

    func inFlightCount(parentConversationID: UUID) async -> Int {
        _ = parentConversationID
        return 0
    }
}

enum SubAgentInvocationPhase: String, Sendable, Codable {
    case queued
    case dispatching
    case running
    case awaitingApproval = "awaiting-approval"
    case completing
    case done
    case failed
}

protocol SubAgentInvocationCoordinating: Sendable {
    func recordTransition(
        parentConversationID: UUID,
        lifecycleID: String,
        phase: SubAgentInvocationPhase
    ) async
}

protocol SubAgentInvocationLifecycleTracking: SubAgentInvocationCoordinating, Sendable {
    func beginInvocation(
        reservation: SubAgentRunReservation
    ) async throws -> SubAgentRunAcquisition
    func endInvocation(_ acquisition: SubAgentRunAcquisition) async
    func endInvocation(lifecycleID: String) async
    func inFlightCount(parentConversationID: UUID) async -> Int
}

struct SubAgentDelegationContext: Sendable {
    var parentConversationID: UUID
    var childConversationID: UUID?
    var delegateToolName: String?
    var resolvedAgentID: String?
    var transportKind: SubAgentTransportKind
    var effectivePermissionPolicy: SubAgentPermissionPolicy
    var effectiveTrustLevel: SubAgentTrustLevel
    var handleID: String?
    var runID: UUID?
    var selectedViaQuery: Bool
}

enum SubAgentSpawnPlan: Sendable, Equatable {
    case fork(userMessageID: UUID)
    case isolated
}

struct SubAgentPendingCompletionEvent: Sendable {
    let conversationID: UUID
    let completion: PendingToolCompletion
    let toolMessage: Message
    let launchHandleID: String?
}

protocol SubAgentCompletionHandoffOwning: Sendable {
    func stop() async
    func registerBackgroundLaunch(handleID: String, conversationID: UUID, parentConversationID: UUID) async
    func startListening(
        orchestrator: SwiftAgentKitOrchestrator,
        resolveConversationID: @escaping @Sendable (_ toolCallID: String, _ handleID: String) async -> UUID?,
        onCompletion: @escaping @Sendable (SubAgentPendingCompletionEvent) async -> Void
    ) async
}

actor SubAgentCompletionHandoffOwner: SubAgentCompletionHandoffOwning {
    private var listenerTask: Task<Void, Never>?
    private var deliveredHandleIDs: Set<String> = []
    private var backgroundConversationIDByHandleID: [String: UUID] = [:]

    func stop() async {
        listenerTask?.cancel()
        listenerTask = nil
    }

    func registerBackgroundLaunch(handleID: String, conversationID: UUID, parentConversationID _: UUID) async {
        backgroundConversationIDByHandleID[handleID] = conversationID
    }

    func startListening(
        orchestrator: SwiftAgentKitOrchestrator,
        resolveConversationID: @escaping @Sendable (_ toolCallID: String, _ handleID: String) async -> UUID?,
        onCompletion: @escaping @Sendable (SubAgentPendingCompletionEvent) async -> Void
    ) async {
        await stop()
        listenerTask = Task.detached {
            let stream = await orchestrator.pendingToolCompletions
            for await completion in stream {
                if Task.isCancelled { return }
                let event = await self.makeEvent(
                    completion: completion,
                    resolveConversationID: resolveConversationID
                )
                guard let event else { continue }
                await onCompletion(event)
            }
        }
    }

    private func makeEvent(
        completion: PendingToolCompletion,
        resolveConversationID: @escaping @Sendable (_ toolCallID: String, _ handleID: String) async -> UUID?
    ) async -> SubAgentPendingCompletionEvent? {
        if deliveredHandleIDs.contains(completion.handleID) {
            return nil
        }
        let conversationID: UUID?
        if let knownConversationID = backgroundConversationIDByHandleID[completion.handleID] {
            conversationID = knownConversationID
        } else {
            conversationID = await resolveConversationID(completion.toolCallID, completion.handleID)
        }
        guard let conversationID else { return nil }
        deliveredHandleIDs.insert(completion.handleID)

        let content: String = {
            let raw: String
            if completion.result.success {
                raw = completion.result.content
            } else {
                let base = completion.result.error ?? "Tool execution failed"
                raw = "\(base) Please try another tool or approach."
            }
            return SubAgentDelegateResultBounds.boundContent(raw)
        }()
        let toolMessage = Message(
            id: UUID(),
            role: .tool,
            content: content,
            timestamp: completion.completedAt,
            toolCallId: completion.toolCallID
        )
        return SubAgentPendingCompletionEvent(
            conversationID: conversationID,
            completion: completion,
            toolMessage: toolMessage,
            launchHandleID: backgroundConversationIDByHandleID[completion.handleID] == nil ? nil : completion.handleID
        )
    }
}

protocol SubAgentPooling: SubAgentToolClassifying {
    func delegateToolNames(from entries: [ToolRegistryEntry]) async -> Set<String>
    func listSubAgents(
        from entries: [ToolRegistryEntry],
        routingContext: SubAgentRoutingContext?,
        conversationID: UUID?
    ) async -> [SubAgentRegistryEntry]
    func refreshSubAgentCatalog(
        conversationID: UUID?,
        fetchEntries: @escaping (UUID?) async -> [ToolRegistryEntry]
    ) async -> [ToolRegistryEntry]
    func normalizeLaunchRequest(_ request: SubAgentSpawnRequest) -> SubAgentLaunchRequest
    func resolveSubAgent(
        _ request: SubAgentLaunchRequest,
        from entries: [ToolRegistryEntry],
        conversationID: UUID?
    ) async throws -> SubAgentLaunchRequest
    func planLaunch(_ request: SubAgentLaunchRequest, parentConversationID: UUID) throws -> SubAgentLaunchPlan
    func selectTransportAdapter(
        for request: SubAgentLaunchRequest,
        entries: [ToolRegistryEntry],
        conversationID: UUID?
    ) async -> (any SubAgentTransportAdapting)?
    func invokeSubAgent(
        launchPlan: SubAgentLaunchPlan,
        registryEntry: SubAgentRegistryEntry,
        toolEntry: ToolRegistryEntry,
        parentConversationID: UUID
    ) async throws -> SubAgentTransportInvocationResult
    func streamDelegateEvents(
        _ request: SubAgentTransportDelegateEventsRequest
    ) async -> AsyncStream<SubAgentDelegateEvent>
    func cancelTransport(_ request: SubAgentTransportCancellationRequest) async throws -> SubAgentTransportCancellationResult
    func resolveTransportPermission(
        _ request: SubAgentTransportPermissionResolutionRequest
    ) async throws -> SubAgentTransportPermissionResolutionResult
    func recoverTransport(_ request: SubAgentTransportRecoveryRequest) async throws -> SubAgentTransportRecoveryResult
    var completionHandoffOwner: any SubAgentCompletionHandoffOwning { get }
}

struct DefaultSubAgentPool: SubAgentPooling, SubAgentTransportAdapterResolving {
    let completionHandoffOwner: any SubAgentCompletionHandoffOwning = SubAgentCompletionHandoffOwner()
    private let adapterRegistry: [SubAgentTransportKind: any SubAgentTransportAdapting]
    private let hostingPolicyConfiguration: SubAgentHostingPolicyConfiguration

    init(
        adapters: [any SubAgentTransportAdapting] = SubAgentDefaultAdapters.make(),
        hostingPolicyConfiguration: SubAgentHostingPolicyConfiguration
    ) {
        var registry: [SubAgentTransportKind: any SubAgentTransportAdapting] = [:]
        for adapter in adapters {
            registry[adapter.transportKind] = adapter
        }
        self.adapterRegistry = registry
        self.hostingPolicyConfiguration = hostingPolicyConfiguration
    }

    func isDelegateTool(entry: ToolRegistryEntry) -> Bool {
        if entry.transportKind == .a2a || entry.source == .a2a { return true }
        if entry.definition.type == .a2aAgent { return true }
        if entry.transportKind == .acp { return true }
        if entry.definition.type == .acpAgent { return true }
        return entry.name.lowercased().hasPrefix("delegate_")
    }

    func permissionPolicy(for entry: ToolRegistryEntry) -> SubAgentPermissionPolicy {
        switch resolvedTransportKind(for: entry) {
        case .a2a, .acpStdio, .customEndpoint:
            return .askUser
        case .inProcess:
            return .askParent
        case .unknown:
            return .askUser
        }
    }

    func trustLevel(for entry: ToolRegistryEntry) -> SubAgentTrustLevel {
        switch resolvedTransportKind(for: entry) {
        case .a2a:
            return .knownParty
        case .acpStdio, .customEndpoint:
            return .unknownParty
        case .inProcess:
            return .system
        case .unknown:
            return .unknownParty
        }
    }

    func maxRecursionDepth(for entry: ToolRegistryEntry) -> Int? {
        let transportKind = resolvedTransportKind(for: entry)
        return adapter(for: transportKind)?.capabilities.maxRecursionDepth
    }

    func adapter(for transportKind: SubAgentTransportKind) -> (any SubAgentTransportAdapting)? {
        adapterRegistry[transportKind]
    }

    func adapter(for registryEntry: SubAgentRegistryEntry) -> (any SubAgentTransportAdapting)? {
        adapter(for: SubAgentTransportKind(rawOrAlias: registryEntry.transportKind))
    }

    func selectTransportAdapter(
        for request: SubAgentLaunchRequest,
        entries: [ToolRegistryEntry],
        conversationID: UUID?
    ) async -> (any SubAgentTransportAdapting)? {
        let registry = await listSubAgents(from: entries, routingContext: nil, conversationID: conversationID)
        if let agentID = request.agentID,
           let entry = registry.first(where: { $0.agentID == agentID || $0.delegateToolName == agentID }) {
            return adapter(for: entry)
        }
        if let subagentType = request.subagentType {
            let kind = SubAgentTransportKind(rawOrAlias: subagentType)
            if let resolved = adapter(for: kind) {
                return resolved
            }
            return adapter(for: .unknown) ?? adapter(for: .inProcess)
        }
        return adapter(for: .inProcess)
    }

    func invokeSubAgent(
        launchPlan: SubAgentLaunchPlan,
        registryEntry: SubAgentRegistryEntry,
        toolEntry: ToolRegistryEntry,
        parentConversationID: UUID
    ) async throws -> SubAgentTransportInvocationResult {
        let requestedKind = SubAgentTransportKind(rawOrAlias: launchPlan.request.subagentType)
        let registryKind = SubAgentTransportKind(rawOrAlias: registryEntry.transportKind)
        let effectiveKind: SubAgentTransportKind = switch requestedKind {
        case .unknown: registryKind
        default: requestedKind
        }
        guard let adapter = adapter(for: effectiveKind) ?? adapter(for: registryEntry) else {
            return SubAgentTransportInvocationResult(outcome: .delegatedToHostInProcess)
        }
        return try await adapter.invoke(
            SubAgentTransportInvocationRequest(
                launchPlan: launchPlan,
                registryEntry: registryEntry,
                toolEntry: toolEntry,
                parentConversationID: parentConversationID
            )
        )
    }

    func streamDelegateEvents(
        _ request: SubAgentTransportDelegateEventsRequest
    ) async -> AsyncStream<SubAgentDelegateEvent> {
        guard let adapter = adapter(for: request.correlation.transportKind) else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return await adapter.delegateEvents(request)
    }

    func refreshSubAgentCatalog(
        conversationID: UUID?,
        fetchEntries: @escaping (UUID?) async -> [ToolRegistryEntry]
    ) async -> [ToolRegistryEntry] {
        await fetchEntries(conversationID)
    }

    func cancelTransport(_ request: SubAgentTransportCancellationRequest) async throws -> SubAgentTransportCancellationResult {
        guard let adapter = adapter(for: request.transportKind) else {
            return SubAgentTransportCancellationResult(disposition: .noAction, note: "adapter_not_found")
        }
        return try await adapter.cancel(request)
    }

    func resolveTransportPermission(
        _ request: SubAgentTransportPermissionResolutionRequest
    ) async throws -> SubAgentTransportPermissionResolutionResult {
        guard let adapter = adapter(for: request.transportKind) else {
            return SubAgentTransportPermissionResolutionResult(disposition: .noAction, note: "adapter_not_found")
        }
        return try await adapter.resolvePermission(request)
    }

    func recoverTransport(_ request: SubAgentTransportRecoveryRequest) async throws -> SubAgentTransportRecoveryResult {
        guard let adapter = adapter(for: request.transportKind) else {
            return SubAgentTransportRecoveryResult(disposition: .noAction, note: "adapter_not_found")
        }
        return try await adapter.recover(request)
    }

    func delegateToolNames(from entries: [ToolRegistryEntry]) async -> Set<String> {
        Set(entries.filter { isDelegateTool(entry: $0) }.map(\.name))
    }

    func listSubAgents(
        from entries: [ToolRegistryEntry],
        routingContext: SubAgentRoutingContext?,
        conversationID _: UUID?
    ) async -> [SubAgentRegistryEntry] {
        let rows = entries
            .filter { isDelegateTool(entry: $0) }
            .map { entry in
                let transportKind = resolvedTransportKind(for: entry)
                let adapterCapabilities = adapter(for: transportKind)?.capabilities
                let hostingPolicy = hostingPolicyConfiguration.policy(forDelegateToolName: entry.name)
                return SubAgentRegistryEntry(
                    agentID: entry.name,
                    displayName: entry.name,
                    description: entry.description,
                    delegateToolName: entry.name,
                    source: entry.source,
                    transportKind: transportKind.rawValue,
                    useClasses: adapterCapabilities?.useClasses ?? [],
                    maxRecursionDepth: adapterCapabilities?.maxRecursionDepth,
                    streaming: adapterCapabilities?.supportsStreaming,
                    longRunning: adapterCapabilities?.supportsLongRunning,
                    defaultTrustLevel: trustLevel(for: entry),
                    permissionPolicy: permissionPolicy(for: entry),
                    hostingPolicy: hostingPolicy,
                    availableToolInfo: entry.availableToolInfo
                )
            }
            .sorted { $0.delegateToolName < $1.delegateToolName }
        guard let routingContext else { return rows }
        return rows.filter { isRegistryEntryAllowedForRoutingContext($0, routingContext: routingContext) }
    }

    func normalizeLaunchRequest(_ request: SubAgentSpawnRequest) -> SubAgentLaunchRequest {
        SubAgentLaunchRequest(spawnRequest: request)
    }

    func resolveSubAgent(
        _ request: SubAgentLaunchRequest,
        from entries: [ToolRegistryEntry],
        conversationID: UUID?
    ) async throws -> SubAgentLaunchRequest {
        var resolved = request
        let registry = await listSubAgents(from: entries, routingContext: nil, conversationID: conversationID)
        if let explicitAgentID = resolved.agentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitAgentID.isEmpty {
            if let matched = registry.first(where: {
                $0.agentID.caseInsensitiveCompare(explicitAgentID) == .orderedSame
                    || $0.delegateToolName.caseInsensitiveCompare(explicitAgentID) == .orderedSame
            }) {
                guard isRegistryEntryAllowedForRoutingContext(matched, request: resolved) else {
                    throw ConversationServiceError.invalidSubAgentSpawn
                }
                if resolved.subagentType == nil || resolved.subagentType?.isEmpty == true {
                    resolved.subagentType = matched.transportKind
                }
                return resolved
            }
            // No registry row yet (e.g. orchestrator reported zero tools and only the local baseline is
            // visible, or MCP/A2A registration lags). Isolated spawns may still carry an explicit
            // `delegate_*` handle so REST/WS clients can assert routing metadata — the same prefix
            // convention as ``DefaultSubAgentPool/isDelegateTool(entry:)``.
            guard resolved.context == .isolated else {
                throw ConversationServiceError.invalidSubAgentSpawn
            }
            guard Self.isOpaqueDelegateToolHandle(explicitAgentID) else {
                throw ConversationServiceError.invalidSubAgentSpawn
            }
            return resolved
        }
        if let ref = resolved.agentRef,
           let match = SubAgentReferenceResolver.resolve(reference: SubAgentReference(id: ref, slug: ref), in: registry) {
            guard isRegistryEntryAllowedForRoutingContext(match, request: resolved) else {
                throw ConversationServiceError.invalidSubAgentSpawn
            }
            resolved.agentID = match.agentID
            resolved.subagentType = match.transportKind
            return resolved
        }
        if let query = resolved.agentQuery,
           let match = SubAgentReferenceResolver.resolve(reference: SubAgentReference(query: query), in: registry) {
            guard isRegistryEntryAllowedForRoutingContext(match, request: resolved) else {
                throw ConversationServiceError.invalidSubAgentSpawn
            }
            resolved.agentID = match.agentID
            resolved.agentRef = match.agentID
            resolved.subagentType = match.transportKind
            return resolved
        }
        if let subagentType = resolved.subagentType {
            let kind = SubAgentTransportKind(rawOrAlias: subagentType)
            if let match = registry.first(where: { SubAgentTransportKind(rawOrAlias: $0.transportKind) == kind }) {
                guard isRegistryEntryAllowedForRoutingContext(match, request: resolved) else {
                    throw ConversationServiceError.invalidSubAgentSpawn
                }
                resolved.agentID = match.agentID
                resolved.subagentType = match.transportKind
                return resolved
            }
            throw ConversationServiceError.invalidSubAgentSpawn
        }
        return resolved
    }

    func planLaunch(_ request: SubAgentLaunchRequest, parentConversationID: UUID) throws -> SubAgentLaunchPlan {
        let spawnPlan: SubAgentSpawnPlan
        switch request.context {
        case .fork:
            guard let userMessageID = request.userMessageID else {
                throw ConversationServiceError.invalidSubAgentSpawn
            }
            spawnPlan = .fork(userMessageID: userMessageID)
        case .isolated:
            spawnPlan = .isolated
        }

        let transportKind = SubAgentTransportKind(rawOrAlias: request.subagentType)
        let effectiveTransport: SubAgentTransportKind = {
            if let explicitAgentID = request.agentID,
               !explicitAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return transportKind
            }
            if request.subagentType == nil {
                return .inProcess
            }
            return transportKind
        }()
        let effectivePermission: SubAgentPermissionPolicy = switch effectiveTransport {
        case .a2a, .acpStdio, .customEndpoint: .askUser
        case .inProcess: .askParent
        case .unknown: .askUser
        }
        let effectiveTrust: SubAgentTrustLevel = switch effectiveTransport {
        case .a2a: .knownParty
        case .acpStdio, .customEndpoint: .unknownParty
        case .inProcess: .system
        case .unknown: .unknownParty
        }

        let asyncHandleID: String? = if request.runInBackground {
            request.agentID ?? "subagent-\(parentConversationID.uuidString)-\(UUID().uuidString)"
        } else {
            nil
        }
        return SubAgentLaunchPlan(
            spawnPlan: spawnPlan,
            request: request,
            asyncHandleID: asyncHandleID,
            delegationContext: SubAgentDelegationContext(
                parentConversationID: parentConversationID,
                childConversationID: nil,
                delegateToolName: request.agentID,
                resolvedAgentID: request.agentID,
                transportKind: effectiveTransport,
                effectivePermissionPolicy: effectivePermission,
                effectiveTrustLevel: effectiveTrust,
                handleID: asyncHandleID,
                runID: nil,
                selectedViaQuery: request.agentQuery != nil && request.agentID != nil
            )
        )
    }

    /// True when `raw` is a non-empty explicit tool handle allowed for isolated spawn without a live catalog row.
    /// Kept consistent with ``isDelegateTool(entry:)``'s `delegate_` naming convention.
    private static func isOpaqueDelegateToolHandle(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.lowercased().hasPrefix("delegate_")
    }

    private func resolvedTransportKind(for entry: ToolRegistryEntry) -> SubAgentTransportKind {
        let adapterKind = SubAgentTransportKind(rawOrAlias: entry.executionEnvironment.adapterID)
        if adapterKind != .unknown {
            return adapterKind
        }
        switch entry.executionEnvironment.kind {
        case .a2a:
            return .a2a
        case .mcp:
            return .acpStdio
        case .local, .docker, .ssh:
            return .inProcess
        case .unknown:
            return .unknown
        }
    }

    private func isRegistryEntryAllowedForRoutingContext(
        _ entry: SubAgentRegistryEntry,
        request: SubAgentLaunchRequest
    ) -> Bool {
        isRegistryEntryAllowedForRoutingContext(entry, routingContext: request.routingContext)
    }

    private func isRegistryEntryAllowedForRoutingContext(
        _ entry: SubAgentRegistryEntry,
        routingContext: SubAgentRoutingContext
    ) -> Bool {
        if let requestedHostPersonaID = routingContext.hostPersonaID,
           !requestedHostPersonaID.isEmpty {
            if let entryHostPersonaID = entry.hostingPolicy.hostPersonaID,
               entryHostPersonaID.caseInsensitiveCompare(requestedHostPersonaID) != .orderedSame {
                return false
            }
            if let hostPolicy = hostingPolicyConfiguration.policy(forHostPersonaID: requestedHostPersonaID),
               !hostPolicy.delegationAllowlist.isEmpty {
                let allowed = Set(hostPolicy.delegationAllowlist.map { $0.lowercased() })
                let entryNames: Set<String> = [
                    entry.agentID.lowercased(),
                    entry.delegateToolName.lowercased(),
                    entry.displayName.lowercased(),
                ]
                if allowed.isDisjoint(with: entryNames) {
                    return false
                }
            }
        }
        if let routingDomain = routingContext.routingDomain,
           !routingDomain.isEmpty {
            guard entry.hostingPolicy.routingDomain?.caseInsensitiveCompare(routingDomain) == .orderedSame else {
                return false
            }
        }
        if let tenantScope = routingContext.tenantScope,
           !tenantScope.isEmpty {
            guard entry.hostingPolicy.tenantScope?.caseInsensitiveCompare(tenantScope) == .orderedSame else {
                return false
            }
        }
        let requestedScopes = Set(routingContext.authScopeTags.map { $0.lowercased() })
        if !requestedScopes.isEmpty {
            let entryScopes = Set(entry.hostingPolicy.authScopeTags.map { $0.lowercased() })
            if !requestedScopes.isSubset(of: entryScopes) {
                return false
            }
        }
        return true
    }
}
