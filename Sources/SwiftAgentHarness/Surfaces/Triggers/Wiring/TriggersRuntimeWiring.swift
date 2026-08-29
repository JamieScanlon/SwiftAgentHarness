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
        originSenderID: String?,
        originSenderIsOwner: Bool?
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
            originSenderIsOwner: originSenderIsOwner,
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
    /// The shared registration endpoint. Phase-3 clients (slash, CLI, HTTP) attach here.
    let registration: TriggerRegistrationService
    public let scheduler: TriggerSchedulerService
    public let webhookAdapter: WebhookIngressAdapter
    public let webhookRouteStore: WebhookRouteStore
    public let scheduleTools: ScheduleToolProvider
    public let webhookTools: WebhookToolProvider
    /// Read-only. Channel mutation is owner-only and has no agent-facing tool — see
    /// ``ChannelToolProvider``.
    public let channelTools: ChannelToolProvider
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
        /// Operator-owned spend ceilings. No agent-facing parameter reaches this.
        public var budgets: TriggerBudgetConfiguration = TriggerBudgetConfiguration()
        /// Settled USD for a finished trigger-host conversation, from the host's authoritative
        /// per-run usage rollups. Without it the ledger never accrues and ceilings never bind — the
        /// harness says so loudly at boot rather than presenting an unmetered ceiling as enforcement.
        public var conversationCostUSD: (@Sendable (UUID) async -> Double?)? = nil
        /// Opt in to the in-package meter (``TriggerConversationCostMeter``) instead of supplying
        /// your own. Ignored when `conversationCostUSD` is set — an explicit meter always wins.
        ///
        /// **On by default.** Main-loop and sub-agent spend both reach the per-run rollups now, and
        /// main-loop cost is the figure `BudgetEnforcingLLM` settled — the same number
        /// `ModelPoolCostLedger` bills — rather than a re-derivation from the conversation's model.
        ///
        /// It is still catalog rates, not an invoice: a registry row with no rates contributes
        /// tokens and no cost, so a deployment running unpriced models will see ceilings that do not
        /// bind. Boot logs `trigger_budgets_priced_from_catalog_rates` to say so. Set `false` to opt
        /// out, or supply `conversationCostUSD` to override entirely.
        public var meterConversationCostFromRunRollups: Bool = true
        /// How long a still-running trigger run may hold up settlement before the finished runs are
        /// billed without it. Nothing in the harness times a run out, so without this a wedged lane
        /// pins the charge until retention drops it; set it above your longest legitimate run,
        /// because settling early is unrecoverable.
        public var meterOpenRunGrace: TimeInterval = 6 * 3600

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
        let initiatorBurst = TriggerInitiatorBurstGate()
        let budgetNotifier = TriggerBudgetNotifierHolder()
        let spendLedger = TriggerSpendLedgerStore(
            fileURL: configuration.dataDirectory.appendingPathComponent("trigger_spend_ledger.json"),
            retainedWindows: configuration.budgets.retainedWindows
        )
        // An explicit host meter wins; the in-package one is opt-in; otherwise there is none.
        let costMeter: (@Sendable (UUID) async -> Double?)?
        if let supplied = configuration.conversationCostUSD {
            costMeter = supplied
        } else if configuration.meterConversationCostFromRunRollups {
            costMeter = TriggerConversationCostMeter.runRollups(
                runtime: runtime,
                openRunGrace: configuration.meterOpenRunGrace,
                logger: logger
            ).port
        } else {
            costMeter = nil
        }
        if configuration.budgets.enabled {
            if costMeter == nil {
                logger.warning(
                    "trigger_budgets_unmetered — spend ceilings are configured but no conversationCostUSD meter was supplied; ledgers will not accrue and ceilings will not bind"
                )
            } else if configuration.conversationCostUSD == nil {
                // Said out loud for the same reason `trigger_budgets_unmetered` is: a ceiling that
                // silently measures a fraction of the spend is the same failure as one that
                // measures none, and the fraction is invisible from the ledger.
                logger.warning(
                    "trigger_budgets_priced_from_catalog_rates — metering from per-run rollups at the cost the budget gate settled; a registry model with no configured rates accrues tokens but $0, so its ceilings will not bind"
                )
            }
        }
        let budgetGate = TriggerBudgetGate(
            store: spendLedger,
            configuration: configuration.budgets,
            ports: TriggerSpendPorts(
                conversationCostUSD: costMeter ?? { _ in nil },
                notify: { [budgetNotifier] notice in await budgetNotifier.notify(notice) }
            ),
            logger: logger
        )
        let activationPolicy = TriggerActivationPolicy(
            idempotency: idempotency,
            rateLimit: rateLimit,
            initiatorBurst: initiatorBurst,
            budget: budgetGate,
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
        // Session-scoped tasks (`durable: false`) live here and never reach disk. Shared by
        // reference between the registration endpoint that writes them and the scheduler that
        // fires them — two instances would mean tasks that exist but never run.
        let sessionTaskStore = SessionScopedScheduledTaskStore()
        // Webhook routes are built here rather than at their point of use: the registration
        // endpoint owns webhook create/update/delete too, so the store has to exist first.
        let dynamicStore = WebhookDynamicRouteStore(
            fileURL: configuration.dataDirectory.appendingPathComponent("webhook_subscriptions.json")
        )
        let routeStore = WebhookRouteStore(staticRoutes: configuration.staticWebhookRoutes, dynamicStore: dynamicStore)
        // Per-channel lifecycle overlay. Separate from `channels.json`, which stays operator-owned
        // and is never rewritten from a runtime client; this file records only that a channel config
        // permits is currently held off. A value type over one `fileURL`, so the endpoint that
        // writes it and the registry that reads it agree because they name the same file, not
        // because they share an instance — unlike `SessionScopedScheduledTaskStore` above, whose
        // state is in memory and therefore genuinely must be one object.
        let channelStateStore = ChannelRuntimeStateStore(
            fileURL: configuration.dataDirectory.appendingPathComponent("channel_runtime_state.json")
        )
        let resolvedChannelsConfigURL = configuration.channelsConfigURL
            ?? configuration.dataDirectory.appendingPathComponent("channels.json")
        // Closed below, once the listener registry exists. A lifecycle decision that only persists
        // and never reaches the running process would report a pause that has not happened.
        let channelApplier = ChannelLifecycleApplierHolder()
        // The one registration endpoint. Every create/update/delete for a trigger — agent tool,
        // file drop, installer, and (from phase 3) slash/CLI/HTTP — goes through this value.
        let registration = TriggerRegistrationService(
            store: taskStore,
            sessionStore: sessionTaskStore,
            webhookRoutes: routeStore,
            channelState: channelStateStore,
            channelConfigURL: resolvedChannelsConfigURL,
            channelApply: channelApplier,
            tenancy: scheduleToolPorts.tenancyPolicy,
            auditLog: auditLog,
            logger: logger
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
            sessionStore: sessionTaskStore,
            deliver: dreamingDeliver,
            lockURL: lockURL,
            config: TriggerSchedulerConfiguration(lockIdentity: configuration.schedulerIdentity),
            taskRuns: taskRuns,
            logger: logger
        )
        // Permanent system cron — installer authority only, and write-if-missing so a user deletion
        // is not resurrected on the next boot.
        do {
            try MemoryDreamingCronInstaller.ensureInstalled(
                registration: registration,
                config: memoryConfig,
                logger: logger
            )
        } catch {
            logger.error("[Dreaming] failed to install dream cron: \(error.localizedDescription)")
        }
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
            configURL: resolvedChannelsConfigURL,
            runtimeState: channelStateStore
        )
        // Close the late-bound edge: a persisted lifecycle decision now reaches the live listeners.
        channelApplier.install { [channelRegistry] in
            await channelRegistry.reconcile()
        }
        if let hub = configuration.conversationEventsHub, let channelRunStreamingHolder {
            channelRunStreamingHolder.install(
                ChannelRunStreamingService(
                    hub: hub,
                    // `outboundPlugin`, not `plugin`: this decides whether a turn may open a stream
                    // to the channel, and the answer is "only while its listener is running" — the
                    // same question `syncOutbound` asks. With the weaker lookup, a turn starting at
                    // the moment `withdrawOutbound` was tearing streams down could slip a new one in
                    // behind the teardown and stream to a paused channel anyway.
                    pluginLookup: { channel in
                        await channelRegistry.outboundPlugin(for: channel)
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
            registration: registration,
            catalogPort: scheduleToolPorts.catalogPort,
            tenancyPolicy: scheduleToolPorts.tenancyPolicy,
            channelRegistry: channelRegistry
        )
        let webhookTools = WebhookToolProvider(dataService: scheduleDataService)
        let channelTools = ChannelToolProvider(dataService: scheduleDataService)
        let scheduleTools = ScheduleToolProvider(
            dataService: scheduleDataService,
            resolveHostTrigger: resolveHostTrigger
        )
        let fileEventQueue = FileEventQueueService(
            eventsDirectory: resolvedEventsDirectory,
            dispatch: dispatch,
            registration: registration,
            logger: logger,
            enabled: configuration.fileEventQueueEnabled
        )
        let replay = TriggerReplayService(dispatch: dispatch, eventsDirectory: resolvedEventsDirectory)
        let outputRouter = TriggerSymmetricOutputRouter(
            channelRegistry: channelRegistry,
            auditLog: auditLog,
            logger: logger
        )
        // Late-bound: the router needs the dispatch service, which needs the activation policy,
        // which needs the gate. Every rung notifies — a trigger the user registered is a standing
        // instruction, and making it silently stop firing is a correctness bug in a cost costume.
        budgetNotifier.install { [outputRouter] notice in
            await outputRouter.deliverBudgetNotice(notice)
        }
        let delegatedCompletionHandoff = TriggerDelegatedCompletionHandoff(
            runRegistry: runRegistry,
            outputRouter: outputRouter,
            resolveParentConversation: delegatedPorts.resolveParentConversation,
            lastAssistantText: delegatedPorts.lastAssistantText,
            logger: logger
        )
        return TriggersRuntimeBundle(
            dispatch: dispatch,
            registration: registration,
            scheduler: scheduler,
            webhookAdapter: webhookAdapter,
            webhookRouteStore: routeStore,
            scheduleTools: scheduleTools,
            webhookTools: webhookTools,
            channelTools: channelTools,
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
