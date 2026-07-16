import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

struct HarnessTriggerRuntimeAdapter: TriggerRuntimeDispatching {
    private let runtime: any APILayerChatRuntimeManaging
    private let session: EmbeddedHarnessAPISession

    init(
        runtime: any APILayerChatRuntimeManaging,
        session: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession()
    ) {
        self.runtime = runtime
        self.session = session
    }

    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?
    ) async throws {
        try await HarnessEmbeddedMutation.dispatchTriggerMessage(
            conversationID: conversationID,
            text: text,
            systemReminder: systemReminder,
            inputTrustRaw: inputTrustRaw,
            resolvedInputTrustClass: resolvedInputTrustClass,
            enableTools: enableTools,
            enableAgents: enableAgents,
            originSurface: originSurface,
            originSenderID: originSenderID,
            session: session,
            fallbackRuntime: runtime
        )
    }
}

struct HarnessTriggerDedupeAdapter: TriggerDedupeChecking {
    private let peek: @Sendable (String) async throws -> Bool
    private let check: @Sendable (String, Int) async throws -> Bool

    init(
        peek: @escaping @Sendable (String) async throws -> Bool,
        check: @escaping @Sendable (String, Int) async throws -> Bool
    ) {
        self.peek = peek
        self.check = check
    }

    init(check: @escaping @Sendable (String, Int) async throws -> Bool) {
        self.peek = { _ in false }
        self.check = check
    }

    func dedupePeek(key: String) async throws -> Bool {
        try await peek(key)
    }

    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
        try await check(key, ttlSeconds)
    }
}

public struct TriggersRuntimeBundle: Sendable {
    let dispatch: TriggerDispatchService
    public let scheduler: TriggerSchedulerService
    public let webhookAdapter: WebhookIngressAdapter
    public let webhookRouteStore: WebhookRouteStore
    public let scheduleTools: ScheduleToolProvider
    public let fileEventQueue: FileEventQueueService
    let replay: TriggerReplayService
    public let channelRegistry: ChannelListenerRegistry
    public let channelSessionLifecycleCoordinator: ChannelSessionLifecycleCoordinator
    let outputRouter: TriggerSymmetricOutputRouter
    public let delegatedCompletionHandoff: TriggerDelegatedCompletionHandoff
    let runRegistry: TriggerDelegatedRunRegistry
}

public enum TriggersRuntimeWiring {
    public struct ScheduleToolPorts: Sendable {
        public var catalogPort: ScheduleToolCatalogPort
        public var tenancyPolicy: TenancyPolicySettings

        public init(
            catalogPort: ScheduleToolCatalogPort,
            tenancyPolicy: TenancyPolicySettings = .disabled
        ) {
            self.catalogPort = catalogPort
            self.tenancyPolicy = tenancyPolicy
        }

        init(
            catalog: any ConversationCatalogServicing,
            tenancyPolicy: TenancyPolicySettings = .disabled
        ) {
            self.catalogPort = ScheduleToolCatalogPort(catalog: catalog)
            self.tenancyPolicy = tenancyPolicy
        }
    }

    public struct DelegatedPorts: Sendable {
        public var spawnSubAgent: @Sendable (UUID, SubAgentSpawnRequest, Model?) async throws -> UUID
        public var sendMessageAndRun: @Sendable (UUID, String) async throws -> Void
        public var lastAssistantText: @Sendable (UUID) async -> String?
        public var stampDelegatedHost: @Sendable (UUID, HarnessTrigger, String) async throws -> Void
        public var resolveParentConversation: @Sendable (UUID) async -> (parentID: UUID, metadata: JSON?)?

        public init(
            spawnSubAgent: @escaping @Sendable (UUID, SubAgentSpawnRequest, Model?) async throws -> UUID,
            sendMessageAndRun: @escaping @Sendable (UUID, String) async throws -> Void,
            lastAssistantText: @escaping @Sendable (UUID) async -> String?,
            stampDelegatedHost: @escaping @Sendable (UUID, HarnessTrigger, String) async throws -> Void,
            resolveParentConversation: @escaping @Sendable (UUID) async -> (parentID: UUID, metadata: JSON?)?
        ) {
            self.spawnSubAgent = spawnSubAgent
            self.sendMessageAndRun = sendMessageAndRun
            self.lastAssistantText = lastAssistantText
            self.stampDelegatedHost = stampDelegatedHost
            self.resolveParentConversation = resolveParentConversation
        }
    }

    public struct Configuration: Sendable {
        public var dataDirectory: URL
        public var eventsDirectory: URL? = nil
        public var fileEventQueueEnabled: Bool = true
        public var channelsConfigURL: URL? = nil
        public var channelListenersEnabled: Bool = false
        public var conversationEventsHub: ConversationEventsTopicHub? = nil
        public var staticWebhookRoutes: [WebhookRoute] = []
        public var schedulerIdentity: String = "sah-trigger-scheduler"

        public init(
            dataDirectory: URL,
            eventsDirectory: URL? = nil,
            fileEventQueueEnabled: Bool = true,
            channelsConfigURL: URL? = nil,
            channelListenersEnabled: Bool = false,
            conversationEventsHub: ConversationEventsTopicHub? = nil,
            staticWebhookRoutes: [WebhookRoute] = [],
            schedulerIdentity: String = "sah-trigger-scheduler"
        ) {
            self.dataDirectory = dataDirectory
            self.eventsDirectory = eventsDirectory
            self.fileEventQueueEnabled = fileEventQueueEnabled
            self.channelsConfigURL = channelsConfigURL
            self.channelListenersEnabled = channelListenersEnabled
            self.conversationEventsHub = conversationEventsHub
            self.staticWebhookRoutes = staticWebhookRoutes
            self.schedulerIdentity = schedulerIdentity
        }
    }

    public static func resolve(
        configuration: Configuration,
        runtime: any APILayerChatRuntimeManaging,
        scheduleToolPorts: ScheduleToolPorts,
        dedupePeek: @escaping @Sendable (String) async throws -> Bool = { _ in false },
        dedupeCheckAndSet: @escaping @Sendable (String, Int) async throws -> Bool,
        createConversation: @escaping @Sendable (String?) async throws -> UUID,
        resolveConversationByTitle: @escaping @Sendable (String) async throws -> UUID? = { _ in nil },
        resolveHostTrigger: @escaping @Sendable () async -> HarnessTrigger? = { nil },
        delegatedPorts: DelegatedPorts,
        logger: Logger
    ) -> TriggersRuntimeBundle {
        resolve(
            configuration: configuration,
            runtime: runtime,
            scheduleToolPorts: scheduleToolPorts,
            dedupePeek: dedupePeek,
            dedupeCheckAndSet: dedupeCheckAndSet,
            createConversation: createConversation,
            resolveConversationByTitle: resolveConversationByTitle,
            taskRuns: .disabled,
            resolveHostTrigger: resolveHostTrigger,
            delegatedPorts: delegatedPorts,
            logger: logger
        )
    }

    static func resolve(
        configuration: Configuration,
        runtime: any APILayerChatRuntimeManaging,
        scheduleToolPorts: ScheduleToolPorts,
        dedupePeek: @escaping @Sendable (String) async throws -> Bool = { _ in false },
        dedupeCheckAndSet: @escaping @Sendable (String, Int) async throws -> Bool,
        createConversation: @escaping @Sendable (String?) async throws -> UUID,
        resolveConversationByTitle: @escaping @Sendable (String) async throws -> UUID? = { _ in nil },
        taskRuns: TriggerTaskRunPorts = .disabled,
        resolveHostTrigger: @escaping @Sendable () async -> HarnessTrigger? = { nil },
        delegatedPorts: DelegatedPorts,
        logger: Logger
    ) -> TriggersRuntimeBundle {
        let auditURL = configuration.dataDirectory.appendingPathComponent("trigger_audit.jsonl")
        let auditLog = TriggerAuditLog(logger: logger, jsonlURL: auditURL)
        let dedupe = HarnessTriggerDedupeAdapter(peek: dedupePeek, check: dedupeCheckAndSet)
        let idempotency = TriggerIdempotencyGate(dedupe: dedupe)
        let rateLimit = TriggerRateLimitGate()
        let costCeiling = TriggerCostCeilingGate()
        let activationPolicy = TriggerActivationPolicy(
            idempotency: idempotency,
            rateLimit: rateLimit,
            costCeiling: costCeiling,
            auditLog: auditLog
        )
        let sessionIndex = TriggerSessionIndex(
            createConversation: createConversation,
            resolveConversationByTitle: resolveConversationByTitle,
            stampDelegatedHost: delegatedPorts.stampDelegatedHost
        )
        let catalogPort = scheduleToolPorts.catalogPort
        let tenancyPolicy = scheduleToolPorts.tenancyPolicy
        let threadedTargetValidator: @Sendable (UUID, HarnessTrigger) async -> Bool = { conversationID, trigger in
            await TriggerThreadedTargetValidator.validate(
                conversationID: conversationID,
                trigger: trigger,
                catalogPort: catalogPort,
                tenancyPolicy: tenancyPolicy
            )
        }
        let sessionRouter = TriggerSessionRouter(
            sessionIndex: sessionIndex,
            threadedTargetValidator: threadedTargetValidator
        )
        let promptBuilder = TriggerPromptBuilder()
        let runtimeAdapter = HarnessTriggerRuntimeAdapter(runtime: runtime)
        let runRegistry = TriggerDelegatedRunRegistry()
        let spawnAdapter = HarnessTriggerDelegatedSpawnAdapter(
            spawnSubAgent: delegatedPorts.spawnSubAgent,
            sendMessageAndRun: delegatedPorts.sendMessageAndRun,
            lastAssistantText: delegatedPorts.lastAssistantText
        )
        let delegatedDispatch = TriggerDelegatedDispatchService(
            spawn: spawnAdapter,
            runRegistry: runRegistry,
            logger: logger
        )
        let channelSessionLifecycleCoordinator = ChannelSessionLifecycleCoordinator()
        let channelRunStreamingHolder = configuration.conversationEventsHub == nil
            ? nil
            : ChannelRunStreamingServiceHolder()
        let dispatch = TriggerDispatchService(
            activationPolicy: activationPolicy,
            sessionRouter: sessionRouter,
            promptBuilder: promptBuilder,
            runtime: runtimeAdapter,
            delegatedDispatch: delegatedDispatch,
            snapshotStore: TriggerSnapshotStore(dataDirectory: configuration.dataDirectory),
            channelRunStreaming: channelRunStreamingHolder,
            lifecycleCoordinator: channelSessionLifecycleCoordinator
        )
        let taskStore = ScheduledTaskStore(
            fileURL: configuration.dataDirectory.appendingPathComponent("scheduled_tasks.json")
        )
        let lockURL = configuration.dataDirectory.appendingPathComponent("scheduler.lock")
        let memoryConfig = MemoryConfiguration.default
        let dreamingBridge = MemoryDreamingBridge(config: memoryConfig, logger: logger)
        let dreamingDeliver = MemoryDreamingDeliver.wrap(
            dispatch: dispatch,
            bridge: dreamingBridge,
            logger: logger
        )
        let scheduler = TriggerSchedulerService(
            store: taskStore,
            deliver: dreamingDeliver,
            lockURL: lockURL,
            config: TriggerSchedulerConfiguration(lockIdentity: configuration.schedulerIdentity),
            taskRuns: taskRuns,
            logger: logger
        )
        // Permanent system cron — installer path only (`allowPermanent` via scanner on store upsert).
        do {
            try MemoryDreamingCronInstaller.ensureInstalled(
                store: taskStore,
                config: memoryConfig,
                logger: logger
            )
        } catch {
            logger.error("[Dreaming] failed to install dream cron: \(error.localizedDescription)")
        }
        let dynamicStore = WebhookDynamicRouteStore(
            fileURL: configuration.dataDirectory.appendingPathComponent("webhook_subscriptions.json")
        )
        let routeStore = WebhookRouteStore(staticRoutes: configuration.staticWebhookRoutes, dynamicStore: dynamicStore)
        let resolvedEventsDirectory = configuration.eventsDirectory
            ?? FileEventQueueLayout.resolveEventsDirectory(dataDirectory: configuration.dataDirectory)
        let channelIngress = ChannelIngressAdapter(dispatch: dispatch)
        let channelRegistry = ChannelListenerRegistry.load(
            dataDirectory: configuration.dataDirectory,
            ingress: channelIngress,
            dedupe: dedupe,
            lifecycleCoordinator: channelSessionLifecycleCoordinator,
            channelRunStreaming: channelRunStreamingHolder,
            logger: logger,
            enabled: configuration.channelListenersEnabled,
            configURL: configuration.channelsConfigURL
        )
        if let hub = configuration.conversationEventsHub, let channelRunStreamingHolder {
            channelRunStreamingHolder.install(
                ChannelRunStreamingService(
                    hub: hub,
                    pluginLookup: { channel in
                        await channelRegistry.plugin(for: channel)
                    },
                    lifecycleCoordinator: channelSessionLifecycleCoordinator
                )
            )
        }
        let webhookValidation = WebhookValidationGate(
            routeStore: routeStore,
            idempotency: idempotency,
            rateLimit: rateLimit
        )
        let directDelivery = WebhookDirectDelivery(
            channelRegistry: channelRegistry,
            logger: logger
        )
        let webhookAdapter = WebhookIngressAdapter(
            validationGate: webhookValidation,
            dispatch: dispatch,
            directDelivery: directDelivery,
            idempotency: idempotency,
            eventsDirectory: configuration.fileEventQueueEnabled ? resolvedEventsDirectory : nil
        )
        let scheduleDataService = ScheduledTaskToolDataService(
            scheduler: scheduler,
            catalogPort: scheduleToolPorts.catalogPort,
            tenancyPolicy: scheduleToolPorts.tenancyPolicy
        )
        let scheduleTools = ScheduleToolProvider(
            dataService: scheduleDataService,
            resolveHostTrigger: resolveHostTrigger
        )
        let fileEventQueue = FileEventQueueService(
            eventsDirectory: resolvedEventsDirectory,
            dispatch: dispatch,
            taskStore: taskStore,
            logger: logger,
            enabled: configuration.fileEventQueueEnabled
        )
        let replay = TriggerReplayService(dispatch: dispatch, eventsDirectory: resolvedEventsDirectory)
        let outputRouter = TriggerSymmetricOutputRouter(
            channelRegistry: channelRegistry,
            auditLog: auditLog,
            logger: logger
        )
        let delegatedCompletionHandoff = TriggerDelegatedCompletionHandoff(
            runRegistry: runRegistry,
            outputRouter: outputRouter,
            resolveParentConversation: delegatedPorts.resolveParentConversation,
            lastAssistantText: delegatedPorts.lastAssistantText,
            logger: logger
        )
        return TriggersRuntimeBundle(
            dispatch: dispatch,
            scheduler: scheduler,
            webhookAdapter: webhookAdapter,
            webhookRouteStore: routeStore,
            scheduleTools: scheduleTools,
            fileEventQueue: fileEventQueue,
            replay: replay,
            channelRegistry: channelRegistry,
            channelSessionLifecycleCoordinator: channelSessionLifecycleCoordinator,
            outputRouter: outputRouter,
            delegatedCompletionHandoff: delegatedCompletionHandoff,
            runRegistry: runRegistry
        )
    }
}
