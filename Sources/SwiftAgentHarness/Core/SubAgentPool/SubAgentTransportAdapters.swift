import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitA2A
import SwiftAgentKitACP

enum SubAgentTransportPermissionGate {
    static func initialPhase(for request: SubAgentTransportInvocationRequest) -> SubAgentDelegateEventPhase {
        if permissionAlreadyGranted(request) || request.registryEntry.permissionPolicy == .auto {
            return .running
        }
        return .awaitingApproval
    }

    static func initialApprovalRoute(for request: SubAgentTransportInvocationRequest) -> ToolApprovalRoute? {
        if permissionAlreadyGranted(request) || request.registryEntry.permissionPolicy == .auto {
            return nil
        }
        switch request.registryEntry.permissionPolicy {
        case .askParent: return .parent
        case .askUser: return .user
        case .auto: return nil
        }
    }

    static func permissionAlreadyGranted(_ request: SubAgentTransportInvocationRequest) -> Bool {
        guard let metadata = request.launchPlan.request.metadata,
              case .object(let object) = metadata,
              case .boolean(true) = object["permissionAlreadyGranted"] else {
            return false
        }
        return true
    }
}

struct A2ASubAgentTransportAdapter: SubAgentTransportAdapting {
    let id = "a2a-default"
    let transportKind: SubAgentTransportKind = .a2a
    let capabilities = SubAgentTransportCapabilities(
        transportKind: .a2a,
        supportsStreaming: true,
        supportsLongRunning: true,
        maxRecursionDepth: 4,
        useClasses: ["remote", "delegate"]
    )

    private let a2aManagerProvider: SubAgentPoolA2AManagerProvider
    private let sessionStore: SubAgentRemoteTransportSessionStore
    private let toolCallTimeout: TimeInterval
    private let logger: Logger?

    init(
        a2aManagerProvider: SubAgentPoolA2AManagerProvider,
        sessionStore: SubAgentRemoteTransportSessionStore = .shared,
        toolCallTimeout: TimeInterval = 300,
        logger: Logger? = nil
    ) {
        self.a2aManagerProvider = a2aManagerProvider
        self.sessionStore = sessionStore
        self.toolCallTimeout = toolCallTimeout
        self.logger = logger
    }

    func invoke(_ request: SubAgentTransportInvocationRequest) async throws -> SubAgentTransportInvocationResult {
        let actualKind = SubAgentTransportKind(rawOrAlias: request.toolEntry.executionEnvironment.adapterID)
        if actualKind != .unknown, actualKind != transportKind {
            throw SubAgentTransportAdapterError.invalidExecutionEnvironment(expected: transportKind, actual: actualKind)
        }
        let sessionHandleID = request.launchPlan.request.agentID ?? request.registryEntry.agentID
        let lifecycleID = request.launchPlan.asyncHandleID
            ?? "a2a-\(request.parentConversationID.uuidString.lowercased())-\(sessionHandleID)"
        let correlation = SubAgentTransportInvocationCorrelation(
            lifecycleID: lifecycleID,
            transportKind: transportKind,
            sessionHandleID: sessionHandleID,
            completionHandleID: request.launchPlan.asyncHandleID
        )
        let initialPhase = SubAgentTransportPermissionGate.initialPhase(for: request)
        let initialApprovalRoute = SubAgentTransportPermissionGate.initialApprovalRoute(for: request)
        let initialEvent = SubAgentDelegateEvent(
            lifecycleID: lifecycleID,
            parentConversationID: request.parentConversationID,
            delegateToolName: request.registryEntry.delegateToolName,
            asyncHandleID: request.launchPlan.asyncHandleID,
            phase: initialPhase,
            eventTrustLevel: SubAgentTrustLevel.knownParty.rawValue,
            defaultTrustLevel: request.registryEntry.defaultTrustLevel.rawValue,
            permissionPolicy: request.registryEntry.permissionPolicy.rawValue,
            approvalRoute: initialApprovalRoute,
            updatedAt: Date()
        )
        let session = RemoteTransportSession(
            correlation: correlation,
            parentConversationID: request.parentConversationID,
            delegateToolName: request.registryEntry.delegateToolName,
            defaultTrustLevel: request.registryEntry.defaultTrustLevel.rawValue,
            permissionPolicy: request.registryEntry.permissionPolicy.rawValue,
            status: initialPhase == .awaitingApproval ? .awaitingApproval : .running
        )
        let delegateEvents = await sessionStore.register(session: session, initialEvent: initialEvent)
        let capturedRequest = request
        await sessionStore.setExecution(lifecycleID: lifecycleID) { [self] in
            await self.runA2ADelegate(request: capturedRequest, lifecycleID: lifecycleID)
        }
        if initialPhase == .running {
            await sessionStore.startExecution(lifecycleID: lifecycleID)
        }
        return SubAgentTransportInvocationResult(outcome: .remoteStarted(correlation: correlation), delegateEvents: delegateEvents)
    }

    func delegateEvents(_ request: SubAgentTransportDelegateEventsRequest) async -> AsyncStream<SubAgentDelegateEvent> {
        await sessionStore.stream(correlation: request.correlation)
    }

    func cancel(_ request: SubAgentTransportCancellationRequest) async throws -> SubAgentTransportCancellationResult {
        if let manager = await a2aManagerProvider.currentManager() {
            _ = await manager.cancelAgentCall(invocationID: request.lifecycleID)
        }
        return await sessionStore.cancel(request)
    }

    func resolvePermission(
        _ request: SubAgentTransportPermissionResolutionRequest
    ) async throws -> SubAgentTransportPermissionResolutionResult {
        await sessionStore.resolvePermission(request)
    }

    func recover(_ request: SubAgentTransportRecoveryRequest) async throws -> SubAgentTransportRecoveryResult {
        await sessionStore.recover(request)
    }

    private func runA2ADelegate(
        request: SubAgentTransportInvocationRequest,
        lifecycleID: String
    ) async {
        let sessionTemplate = RemoteTransportSession(
            correlation: SubAgentTransportInvocationCorrelation(
                lifecycleID: lifecycleID,
                transportKind: transportKind,
                sessionHandleID: request.registryEntry.agentID,
                completionHandleID: request.launchPlan.asyncHandleID
            ),
            parentConversationID: request.parentConversationID,
            delegateToolName: request.registryEntry.delegateToolName,
            defaultTrustLevel: request.registryEntry.defaultTrustLevel.rawValue,
            permissionPolicy: request.registryEntry.permissionPolicy.rawValue,
            status: .running
        )
        guard let manager = await a2aManagerProvider.currentManager() else {
            let event = SubAgentDelegateEvent(
                lifecycleID: lifecycleID,
                parentConversationID: request.parentConversationID,
                delegateToolName: request.registryEntry.delegateToolName,
                asyncHandleID: request.launchPlan.asyncHandleID,
                phase: .failed,
                defaultTrustLevel: sessionTemplate.defaultTrustLevel,
                permissionPolicy: sessionTemplate.permissionPolicy,
                error: "a2a_manager_unavailable",
                updatedAt: Date()
            )
            await sessionStore.emit(event, lifecycleID: lifecycleID)
            return
        }
        let toolCall = SubAgentA2ADelegateStreamMapping.toolCall(from: request, lifecycleID: lifecycleID)
        do {
            let (handle, events) = try await manager.streamAgentCall(
                toolCall,
                invocationID: lifecycleID,
                orchestratorDefaultTimeout: toolCallTimeout
            )
            if let taskID = handle.taskID {
                await sessionStore.updateCorrelation(
                    lifecycleID: lifecycleID,
                    sessionHandleID: taskID,
                    completionHandleID: request.launchPlan.asyncHandleID
                )
            }
            for await event in events {
                guard let mapped = SubAgentA2ADelegateStreamMapping.map(event: event, session: sessionTemplate) else {
                    continue
                }
                await sessionStore.emit(mapped, lifecycleID: lifecycleID)
            }
        } catch {
            logger?.error("[A2ASubAgentTransportAdapter] delegate failed lifecycle=\(lifecycleID) error=\(String(describing: error))")
            let event = SubAgentDelegateEvent(
                lifecycleID: lifecycleID,
                parentConversationID: request.parentConversationID,
                delegateToolName: request.registryEntry.delegateToolName,
                asyncHandleID: request.launchPlan.asyncHandleID,
                phase: .failed,
                defaultTrustLevel: sessionTemplate.defaultTrustLevel,
                permissionPolicy: sessionTemplate.permissionPolicy,
                error: String(describing: error),
                updatedAt: Date()
            )
            await sessionStore.emit(event, lifecycleID: lifecycleID)
        }
    }
}

struct InProcessSubAgentTransportAdapter: SubAgentTransportAdapting {
    let id = "inprocess-default"
    let transportKind: SubAgentTransportKind = .inProcess
    let capabilities = SubAgentTransportCapabilities(
        transportKind: .inProcess,
        supportsStreaming: true,
        supportsLongRunning: true,
        maxRecursionDepth: 3,
        useClasses: ["local", "delegate"]
    )

    func invoke(_ request: SubAgentTransportInvocationRequest) async throws -> SubAgentTransportInvocationResult {
        _ = request
        return SubAgentTransportInvocationResult(outcome: .delegatedToHostInProcess)
    }
}

struct ACPStdioSubAgentTransportAdapter: SubAgentTransportAdapting {
    let id = "acp-stdio-default"
    let transportKind: SubAgentTransportKind = .acpStdio
    let capabilities = SubAgentTransportCapabilities(
        transportKind: .acpStdio,
        supportsStreaming: true,
        supportsLongRunning: true,
        maxRecursionDepth: 4,
        useClasses: ["remote", "acp", "delegate"]
    )

    private let acpManagerProvider: SubAgentPoolACPManagerProvider
    private let sessionStore: SubAgentRemoteTransportSessionStore
    private let toolCallTimeout: TimeInterval
    private let logger: Logger?

    init(
        acpManagerProvider: SubAgentPoolACPManagerProvider,
        sessionStore: SubAgentRemoteTransportSessionStore = .shared,
        toolCallTimeout: TimeInterval = 300,
        logger: Logger? = nil
    ) {
        self.acpManagerProvider = acpManagerProvider
        self.sessionStore = sessionStore
        self.toolCallTimeout = toolCallTimeout
        self.logger = logger
    }

    func invoke(_ request: SubAgentTransportInvocationRequest) async throws -> SubAgentTransportInvocationResult {
        let actualKind = SubAgentTransportKind(rawOrAlias: request.toolEntry.executionEnvironment.adapterID)
        if actualKind != .unknown, actualKind != transportKind {
            throw SubAgentTransportAdapterError.invalidExecutionEnvironment(expected: transportKind, actual: actualKind)
        }
        let sessionHandleID = request.launchPlan.request.agentID ?? request.registryEntry.agentID
        let lifecycleID = request.launchPlan.asyncHandleID
            ?? "acp-\(request.parentConversationID.uuidString.lowercased())-\(sessionHandleID)"
        let correlation = SubAgentTransportInvocationCorrelation(
            lifecycleID: lifecycleID,
            transportKind: transportKind,
            sessionHandleID: sessionHandleID,
            completionHandleID: request.launchPlan.asyncHandleID
        )
        let initialPhase = SubAgentTransportPermissionGate.initialPhase(for: request)
        let initialApprovalRoute = SubAgentTransportPermissionGate.initialApprovalRoute(for: request)
        let initialEvent = SubAgentDelegateEvent(
            lifecycleID: lifecycleID,
            parentConversationID: request.parentConversationID,
            delegateToolName: request.registryEntry.delegateToolName,
            asyncHandleID: request.launchPlan.asyncHandleID,
            phase: initialPhase,
            eventTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
            defaultTrustLevel: request.registryEntry.defaultTrustLevel.rawValue,
            permissionPolicy: request.registryEntry.permissionPolicy.rawValue,
            approvalRoute: initialApprovalRoute,
            updatedAt: Date()
        )
        let session = RemoteTransportSession(
            correlation: correlation,
            parentConversationID: request.parentConversationID,
            delegateToolName: request.registryEntry.delegateToolName,
            defaultTrustLevel: request.registryEntry.defaultTrustLevel.rawValue,
            permissionPolicy: request.registryEntry.permissionPolicy.rawValue,
            status: initialPhase == .awaitingApproval ? .awaitingApproval : .running
        )
        let delegateEvents = await sessionStore.register(session: session, initialEvent: initialEvent)
        let capturedRequest = request
        await sessionStore.setExecution(lifecycleID: lifecycleID) { [self] in
            await self.runACPDelegate(request: capturedRequest, lifecycleID: lifecycleID)
        }
        if initialPhase == .running {
            await sessionStore.startExecution(lifecycleID: lifecycleID)
        }
        return SubAgentTransportInvocationResult(outcome: .remoteStarted(correlation: correlation), delegateEvents: delegateEvents)
    }

    func delegateEvents(_ request: SubAgentTransportDelegateEventsRequest) async -> AsyncStream<SubAgentDelegateEvent> {
        await sessionStore.stream(correlation: request.correlation)
    }

    func cancel(_ request: SubAgentTransportCancellationRequest) async throws -> SubAgentTransportCancellationResult {
        if let manager = await acpManagerProvider.currentManager() {
            _ = await manager.cancelAgentCall(invocationID: request.lifecycleID)
        }
        return await sessionStore.cancel(request)
    }

    func resolvePermission(
        _ request: SubAgentTransportPermissionResolutionRequest
    ) async throws -> SubAgentTransportPermissionResolutionResult {
        await sessionStore.resolvePermission(request)
    }

    func recover(_ request: SubAgentTransportRecoveryRequest) async throws -> SubAgentTransportRecoveryResult {
        await sessionStore.recover(request)
    }

    private func runACPDelegate(
        request: SubAgentTransportInvocationRequest,
        lifecycleID: String
    ) async {
        let sessionTemplate = RemoteTransportSession(
            correlation: SubAgentTransportInvocationCorrelation(
                lifecycleID: lifecycleID,
                transportKind: transportKind,
                sessionHandleID: request.registryEntry.agentID,
                completionHandleID: request.launchPlan.asyncHandleID
            ),
            parentConversationID: request.parentConversationID,
            delegateToolName: request.registryEntry.delegateToolName,
            defaultTrustLevel: request.registryEntry.defaultTrustLevel.rawValue,
            permissionPolicy: request.registryEntry.permissionPolicy.rawValue,
            status: .running
        )
        guard let manager = await acpManagerProvider.currentManager() else {
            await sessionStore.emit(
                SubAgentDelegateEvent(
                    lifecycleID: lifecycleID,
                    parentConversationID: request.parentConversationID,
                    delegateToolName: request.registryEntry.delegateToolName,
                    asyncHandleID: request.launchPlan.asyncHandleID,
                    phase: .failed,
                    defaultTrustLevel: sessionTemplate.defaultTrustLevel,
                    permissionPolicy: sessionTemplate.permissionPolicy,
                    error: "acp_manager_unavailable",
                    updatedAt: Date()
                ),
                lifecycleID: lifecycleID
            )
            return
        }
        let agentName = request.registryEntry.delegateToolName
        let defaultDelegate = DefaultACPClientDelegate(autoApprovePermissions: false)
        var activeDelegateBox: SubAgentACPClientDelegateBox?
        if let delegateBox = await acpManagerProvider.delegateBox(forAgentName: agentName) {
            activeDelegateBox = delegateBox
            let harnessDelegate = await acpManagerProvider.makeHarnessDelegate(
                request: request,
                lifecycleID: lifecycleID
            )
            delegateBox.setDelegate(harnessDelegate)
        }
        defer {
            activeDelegateBox?.restoreDefault(defaultDelegate)
            Task {
                await ACPTerminalForegroundOutputRegistry.shared.sweep(lifecycleIDPrefix: lifecycleID)
            }
        }
        let toolCall = SubAgentACPDelegateStreamMapping.toolCall(from: request, lifecycleID: lifecycleID)
        do {
            let (handle, events) = try await manager.streamAgentCall(
                toolCall,
                invocationID: lifecycleID,
                orchestratorDefaultTimeout: toolCallTimeout
            )
            if let sessionID = handle.sessionID {
                await sessionStore.updateCorrelation(
                    lifecycleID: lifecycleID,
                    sessionHandleID: sessionID,
                    completionHandleID: request.launchPlan.asyncHandleID
                )
            }
            for await event in events {
                guard let mapped = SubAgentACPDelegateStreamMapping.map(event: event, session: sessionTemplate) else {
                    continue
                }
                await sessionStore.emit(mapped, lifecycleID: lifecycleID)
            }
        } catch {
            logger?.error("[ACPStdioSubAgentTransportAdapter] delegate failed lifecycle=\(lifecycleID) error=\(String(describing: error))")
            await sessionStore.emit(
                SubAgentDelegateEvent(
                    lifecycleID: lifecycleID,
                    parentConversationID: request.parentConversationID,
                    delegateToolName: request.registryEntry.delegateToolName,
                    asyncHandleID: request.launchPlan.asyncHandleID,
                    phase: .failed,
                    defaultTrustLevel: sessionTemplate.defaultTrustLevel,
                    permissionPolicy: sessionTemplate.permissionPolicy,
                    error: String(describing: error),
                    updatedAt: Date()
                ),
                lifecycleID: lifecycleID
            )
        }
    }
}

struct CustomEndpointSubAgentTransportAdapter: SubAgentTransportAdapting {
    let id = "custom-endpoint-default"
    let transportKind: SubAgentTransportKind = .customEndpoint
    let capabilities = SubAgentTransportCapabilities(
        transportKind: .customEndpoint,
        supportsStreaming: true,
        supportsLongRunning: true,
        maxRecursionDepth: 4,
        useClasses: ["remote", "endpoint", "delegate"]
    )

    private let configuration: SubAgentCustomEndpointConfiguration
    private let executor: any CustomEndpointDelegateExecuting
    private let sessionStore: SubAgentRemoteTransportSessionStore
    private let logger: Logger?

    init(
        configuration: SubAgentCustomEndpointConfiguration,
        executor: any CustomEndpointDelegateExecuting,
        sessionStore: SubAgentRemoteTransportSessionStore = .shared,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.executor = executor
        self.sessionStore = sessionStore
        self.logger = logger
    }

    func invoke(_ request: SubAgentTransportInvocationRequest) async throws -> SubAgentTransportInvocationResult {
        let actualKind = SubAgentTransportKind(rawOrAlias: request.toolEntry.executionEnvironment.adapterID)
        if actualKind != .unknown, actualKind != transportKind {
            throw SubAgentTransportAdapterError.invalidExecutionEnvironment(expected: transportKind, actual: actualKind)
        }
        let delegateToolName = request.registryEntry.delegateToolName
        guard let endpoint = configuration.binding(for: delegateToolName) else {
            throw SubAgentTransportAdapterError.missingEndpointConfiguration(delegateToolName: delegateToolName)
        }
        let baseHandle = request.launchPlan.request.agentID ?? request.registryEntry.agentID
        guard !baseHandle.isEmpty else { throw SubAgentTransportAdapterError.missingAgentHandle }
        let lifecycleID = request.launchPlan.asyncHandleID
            ?? "endpoint-\(request.parentConversationID.uuidString.lowercased())-\(baseHandle)"
        let completionHandle = request.launchPlan.asyncHandleID ?? "endpoint-complete-\(lifecycleID)"
        let correlation = SubAgentTransportInvocationCorrelation(
            lifecycleID: lifecycleID,
            transportKind: transportKind,
            sessionHandleID: endpoint.url.absoluteString,
            completionHandleID: completionHandle
        )
        let initialPhase = SubAgentTransportPermissionGate.initialPhase(for: request)
        let initialApprovalRoute = SubAgentTransportPermissionGate.initialApprovalRoute(for: request)
        let initialEvent = SubAgentDelegateEvent(
            lifecycleID: lifecycleID,
            parentConversationID: request.parentConversationID,
            delegateToolName: delegateToolName,
            asyncHandleID: completionHandle,
            phase: initialPhase,
            eventTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
            defaultTrustLevel: request.registryEntry.defaultTrustLevel.rawValue,
            permissionPolicy: request.registryEntry.permissionPolicy.rawValue,
            approvalRoute: initialApprovalRoute,
            updatedAt: Date()
        )
        let session = RemoteTransportSession(
            correlation: correlation,
            parentConversationID: request.parentConversationID,
            delegateToolName: delegateToolName,
            defaultTrustLevel: request.registryEntry.defaultTrustLevel.rawValue,
            permissionPolicy: request.registryEntry.permissionPolicy.rawValue,
            status: initialPhase == .awaitingApproval ? .awaitingApproval : .running
        )
        let delegateEvents = await sessionStore.register(session: session, initialEvent: initialEvent)
        await sessionStore.setExecution(lifecycleID: lifecycleID) { [self] in
            await self.runCustomEndpoint(
                request: request,
                endpoint: endpoint,
                lifecycleID: lifecycleID,
                completionHandle: completionHandle,
                session: session
            )
        }
        if initialPhase == .running {
            await sessionStore.startExecution(lifecycleID: lifecycleID)
        }
        return SubAgentTransportInvocationResult(outcome: .remoteStarted(correlation: correlation), delegateEvents: delegateEvents)
    }

    func delegateEvents(_ request: SubAgentTransportDelegateEventsRequest) async -> AsyncStream<SubAgentDelegateEvent> {
        await sessionStore.stream(correlation: request.correlation)
    }

    func cancel(_ request: SubAgentTransportCancellationRequest) async throws -> SubAgentTransportCancellationResult {
        await sessionStore.cancel(request)
    }

    func resolvePermission(
        _ request: SubAgentTransportPermissionResolutionRequest
    ) async throws -> SubAgentTransportPermissionResolutionResult {
        await sessionStore.resolvePermission(request)
    }

    func recover(_ request: SubAgentTransportRecoveryRequest) async throws -> SubAgentTransportRecoveryResult {
        await sessionStore.recover(request)
    }

    private func runCustomEndpoint(
        request: SubAgentTransportInvocationRequest,
        endpoint: CustomEndpointBinding,
        lifecycleID: String,
        completionHandle: String,
        session: RemoteTransportSession
    ) async {
        let instructions = SubAgentA2ADelegateStreamMapping.instructions(from: request.launchPlan)
        let toolCallID = request.launchPlan.asyncHandleID ?? lifecycleID
        do {
            await sessionStore.emit(
                SubAgentDelegateEvent(
                    lifecycleID: lifecycleID,
                    parentConversationID: request.parentConversationID,
                    delegateToolName: session.delegateToolName,
                    asyncHandleID: completionHandle,
                    phase: .running,
                    eventTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
                    defaultTrustLevel: session.defaultTrustLevel,
                    permissionPolicy: session.permissionPolicy,
                    updatedAt: Date()
                ),
                lifecycleID: lifecycleID
            )
            let response = try await executor.invoke(
                endpoint: endpoint,
                instructions: instructions,
                lifecycleID: lifecycleID,
                toolCallID: toolCallID
            )
            await sessionStore.emit(
                SubAgentDelegateEvent(
                    lifecycleID: lifecycleID,
                    parentConversationID: request.parentConversationID,
                    delegateToolName: session.delegateToolName,
                    asyncHandleID: completionHandle,
                    phase: .done,
                    eventTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
                    defaultTrustLevel: session.defaultTrustLevel,
                    permissionPolicy: session.permissionPolicy,
                    completionSource: response.content,
                    completionUsage: response.usage,
                    updatedAt: Date()
                ),
                lifecycleID: lifecycleID
            )
        } catch {
            logger?.error("[CustomEndpointSubAgentTransportAdapter] delegate failed lifecycle=\(lifecycleID) error=\(String(describing: error))")
            await sessionStore.emit(
                SubAgentDelegateEvent(
                    lifecycleID: lifecycleID,
                    parentConversationID: request.parentConversationID,
                    delegateToolName: session.delegateToolName,
                    asyncHandleID: completionHandle,
                    phase: .failed,
                    eventTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
                    defaultTrustLevel: session.defaultTrustLevel,
                    permissionPolicy: session.permissionPolicy,
                    error: String(describing: error),
                    updatedAt: Date()
                ),
                lifecycleID: lifecycleID
            )
        }
    }
}

enum SubAgentDefaultAdapters {
    static func make(
        a2aManagerProvider: SubAgentPoolA2AManagerProvider = SubAgentPoolA2AManagerProvider(),
        acpManagerProvider: SubAgentPoolACPManagerProvider = SubAgentPoolACPManagerProvider(),
        customEndpointConfiguration: SubAgentCustomEndpointConfiguration = .empty,
        customEndpointExecutor: any CustomEndpointDelegateExecuting = URLSessionCustomEndpointDelegateExecutor(),
        sessionStore: SubAgentRemoteTransportSessionStore = .shared,
        toolCallTimeout: TimeInterval = 300,
        logger: Logger? = nil
    ) -> [any SubAgentTransportAdapting] {
        [
            A2ASubAgentTransportAdapter(
                a2aManagerProvider: a2aManagerProvider,
                sessionStore: sessionStore,
                toolCallTimeout: toolCallTimeout,
                logger: logger
            ),
            InProcessSubAgentTransportAdapter(),
            ACPStdioSubAgentTransportAdapter(
                acpManagerProvider: acpManagerProvider,
                sessionStore: sessionStore,
                toolCallTimeout: toolCallTimeout,
                logger: logger
            ),
            CustomEndpointSubAgentTransportAdapter(
                configuration: customEndpointConfiguration,
                executor: customEndpointExecutor,
                sessionStore: sessionStore,
                logger: logger
            ),
        ]
    }
}
