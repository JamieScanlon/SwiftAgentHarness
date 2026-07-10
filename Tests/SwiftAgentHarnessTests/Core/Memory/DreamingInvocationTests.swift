import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("DreamingControlStore")
struct DreamingControlStoreTests {
    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-ctrl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("missing control file defaults to enabled")
    func defaultEnabled() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DreamingControlStore(rootDirectory: root)
        #expect(store.isEnabled())
    }

    @Test("on/off persists across reads")
    func onOffPersist() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DreamingControlStore(rootDirectory: root)
        try store.setEnabled(false)
        #expect(!store.isEnabled())
        try store.setEnabled(true)
        #expect(store.isEnabled())
        #expect(FileManager.default.fileExists(atPath: store.controlFileURL.path))
    }

    @Test("statusSummary includes cron and enabled state")
    func statusSummary() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DreamingControlStore(rootDirectory: root)
        let text = store.statusSummary(cronExpr: "0 3 * * *", memoryDirectory: nil)
        #expect(text.contains("Dreaming: on"))
        #expect(text.contains("0 3 * * *"))
    }
}

@Suite("MemoryDreamingBridge")
struct MemoryDreamingBridgeTests {
    private func makeProjectsTree() throws -> (root: URL, projects: URL, memory: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-bridge-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("proj-a", isDirectory: true)
        let memory = project.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        return (root, projects, memory)
    }

    @Test("disabled control store skips sweeps")
    func disabledSkips() async throws {
        let tree = try makeProjectsTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let control = DreamingControlStore(rootDirectory: tree.root)
        try control.setEnabled(false)
        try AgentMemoryStore(memoryDirectory: tree.memory).ensureLayout()
        try DreamRecallStore(memoryDirectory: tree.memory).recordSearchHits(
            query: "q1",
            hits: [MemorySearchHit(filename: "t.md", score: 5, snippet: "rich distinctive conceptual tokens")]
        )
        try DreamRecallStore(memoryDirectory: tree.memory).recordSearchHits(
            query: "q2",
            hits: [MemorySearchHit(filename: "t.md", score: 5, snippet: "rich distinctive conceptual tokens")]
        )

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        config.dreamingMinRecallCount = 1
        config.dreamingMinUniqueQueries = 1
        let bridge = MemoryDreamingBridge(
            config: config,
            controlStore: control,
            projectsRoot: tree.projects
        )
        let swept = try await bridge.runDueSweeps()
        #expect(swept == 0)
        let index = (try? String(contentsOf: tree.memory.appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? ""
        #expect(!index.contains("t.md"))
    }

    @Test("enabled bridge sweeps memory dirs with content")
    func enabledSweeps() async throws {
        let tree = try makeProjectsTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let control = DreamingControlStore(rootDirectory: tree.root)
        try control.setEnabled(true)
        let agentStore = AgentMemoryStore(memoryDirectory: tree.memory)
        try agentStore.ensureLayout()
        try agentStore.appendDailyNote(
            "rich distinctive conceptual tokens here for promotion",
            date: Date()
        )

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        let bridge = MemoryDreamingBridge(
            config: config,
            controlStore: control,
            projectsRoot: tree.projects
        )
        let swept = try await bridge.runDueSweeps()
        #expect(swept == 1)
        let index = try String(contentsOf: tree.memory.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(!index.isEmpty)
        #expect(!index.contains(AgentMemoryStore.dailyFilename(for: Date())))
        let topics = agentStore.listTopicFilenames()
        #expect(!topics.isEmpty)
    }

    @Test("empty projects tree returns zero")
    func emptyTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-empty-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = MemoryDreamingBridge(
            controlStore: DreamingControlStore(rootDirectory: root),
            projectsRoot: projects
        )
        let swept = try await bridge.runDueSweeps()
        #expect(swept == 0)
    }

    @Test("isDreamTrigger recognizes cronJobId and payload")
    func dreamTriggerDetection() {
        let byID = HarnessTrigger(
            id: "dream:1",
            source: .cron,
            sourceMetadata: ["cronJobId": "dream", "payloadKind": "systemEvent"],
            payload: "dream",
            payloadFormat: .text,
            initiator: TriggerInitiator(kind: .system, id: "dream"),
            trust: .system
        )
        #expect(MemoryDreamingBridge.isDreamTrigger(byID))

        let byPayload = HarnessTrigger(
            id: "other:1",
            source: .cron,
            sourceMetadata: ["cronJobId": "other"],
            payload: "dream",
            payloadFormat: .text,
            initiator: TriggerInitiator(kind: .system, id: "other"),
            trust: .system
        )
        #expect(MemoryDreamingBridge.isDreamTrigger(byPayload))

        let unrelated = HarnessTrigger(
            id: "x:1",
            source: .cron,
            sourceMetadata: ["cronJobId": "morning"],
            payload: "hello",
            payloadFormat: .text,
            initiator: TriggerInitiator(kind: .user, id: "u"),
            trust: .userDeferred
        )
        #expect(!MemoryDreamingBridge.isDreamTrigger(unrelated))
    }
}

@Suite("MemoryDreamingCronInstaller")
struct MemoryDreamingCronInstallerTests {
    @Test("installs permanent dream task using dreamingCron")
    func installsPermanentTask() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-cron-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var config = MemoryConfiguration.default
        config.dreamingCron = "15 4 * * *"
        let store = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        let saved = try MemoryDreamingCronInstaller.ensureInstalled(store: store, config: config)
        #expect(saved.id == "dream")
        #expect(saved.permanent)
        #expect(saved.recurring)
        #expect(saved.trust == .system)
        #expect(saved.payloadKind == .systemEvent)
        #expect(saved.schedule.expr == "15 4 * * *")
        #expect(config.dreamingCron == saved.schedule.expr)
    }

    @Test("reinstall refreshes cron expression from config")
    func refreshesExpr() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-cron-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        var config = MemoryConfiguration.default
        config.dreamingCron = "0 3 * * *"
        _ = try MemoryDreamingCronInstaller.ensureInstalled(store: store, config: config)
        config.dreamingCron = "30 2 * * 1"
        let updated = try MemoryDreamingCronInstaller.ensureInstalled(store: store, config: config)
        #expect(updated.schedule.expr == "30 2 * * 1")
        let loaded = try store.task(id: "dream")
        #expect(loaded?.schedule.expr == "30 2 * * 1")
    }

    @Test("deliver wrapper runs bridge not LLM for dream payloads")
    func deliverShortCircuits() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-deliver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let control = DreamingControlStore(rootDirectory: tmp)
        try control.setEnabled(true)
        let projects = tmp.appendingPathComponent("projects", isDirectory: true)
        let memory = projects.appendingPathComponent("p1/memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try AgentMemoryStore(memoryDirectory: memory).ensureLayout()

        final class CaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
            var calls = 0
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
                calls += 1
            }
        }

        actor LocalDedupe: TriggerDedupeChecking {
            private var keys: Set<String> = []
            func dedupePeek(key: String) async throws -> Bool { keys.contains(key) }
            func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
                if keys.contains(key) { return false }
                keys.insert(key)
                return true
            }
        }

        let runtime = CaptureRuntime()
        let audit = TriggerAuditLog(logger: Logger(label: "test"))
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: LocalDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
            auditLog: audit
        )
        let conversationID = UUID()
        let dispatch = TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: TriggerSessionRouter(
                sessionIndex: TriggerSessionIndex(createConversation: { _ in conversationID })
            ),
            promptBuilder: TriggerPromptBuilder(),
            runtime: runtime
        )
        let bridge = MemoryDreamingBridge(
            config: .default,
            controlStore: control,
            projectsRoot: projects
        )
        let deliver = MemoryDreamingDeliver.wrap(dispatch: dispatch, bridge: bridge)
        let store = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        let scheduler = TriggerSchedulerService(
            store: store,
            deliver: deliver,
            lockURL: tmp.appendingPathComponent("lock.json"),
            logger: Logger(label: "test")
        )
        var config = MemoryConfiguration.default
        config.dreamingCron = "0 3 * * *"
        let task = try await MemoryDreamingCronInstaller.ensureInstalled(scheduler: scheduler, config: config)
        #expect(task.id == "dream")
        #expect(task.schedule.expr == config.dreamingCron)

        let result = try await scheduler.fireNow(id: "dream")
        #expect(result.decision == .admitted)
        #expect(runtime.calls == 0)
    }
}
