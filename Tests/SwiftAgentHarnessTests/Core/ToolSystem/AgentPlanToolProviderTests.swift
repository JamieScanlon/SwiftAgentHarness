import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private final class StubPlanDataProvider: ConversationsDataProviding, @unchecked Sendable {
    var conversations: [UUID: ModelConversation] = [:]

    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func getConversation(id: UUID) async -> ModelConversation? { conversations[id] }
    func switchConversation(id: UUID, message: String?) async throws -> String? { nil }
}

private enum AgentPlanToolTestSupport {
    static func makeProvider(
        dataProvider: ConversationsDataProviding,
        conversationID: UUID
    ) -> AgentPlanToolProvider {
        AgentPlanToolProvider(
            dataProvider: dataProvider,
            resolveConversationID: { conversationID }
        )
    }

    static func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "test-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func makeConversation(id: UUID = UUID()) -> ModelConversation {
        let now = Date()
        return ModelConversation(
            id: id,
            model: makeModel(),
            messages: [],
            createdAt: now,
            updatedAt: now,
            topic: nil,
            description: nil
        )
    }
}

@Suite("AgentPlanToolProvider")
struct AgentPlanToolProviderTests {

    @Test("create_plan writes plan.md and get_plan reads it")
    func createAndGet() async throws {
        let convID = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let taskId = UUID()
        let tasksJSON = """
        [{"id":"\(taskId.uuidString)","description":"First","status":"not-started"}]
        """

        let create = ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(tasksJSON),
                "overview": .string("Overview text"),
                "goal": .string("Goal text"),
            ]),
            id: "c1"
        )
        let createResult = try await provider.executeTool(create)
        #expect(createResult.success == true)

        let get = ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        )
        let getResult = try await provider.executeTool(get)
        #expect(getResult.success == true)
        #expect(getResult.content.contains("# Plan"))
        #expect(getResult.content.contains("Overview text"))
        #expect(getResult.content.contains("## Goal"))
        #expect(getResult.content.contains("Goal text"))
        #expect(getResult.content.contains("## Tasks"))
        #expect(getResult.content.contains("id:\(taskId.uuidString)"))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("create_plan fails when plan already exists")
    func createTwiceFails() async throws {
        let convID = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let taskId = UUID()
        let tasksJSON = "[{\"id\":\"\(taskId.uuidString)\",\"description\":\"T\",\"status\":\"complete\"}]"

        let create = ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(tasksJSON),
            ]),
            id: "c1"
        )
        _ = try await provider.executeTool(create)

        let create2 = ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(tasksJSON),
            ]),
            id: "c2"
        )
        let r2 = try await provider.executeTool(create2)
        #expect(r2.success == false)
        #expect(r2.error?.contains("already exists") == true)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("edit_plan replaces plan.md")
    func editReplaces() async throws {
        let convID = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let t1 = UUID()
        let t2 = UUID()
        let json1 = "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json1),
            ]),
            id: "c1"
        ))

        let json2 = """
        [{"id":"\(t1.uuidString)","description":"A","status":"complete"},{"id":"\(t2.uuidString)","description":"B","status":"not-started"}]
        """
        let editResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.editPlanToolName,
            arguments: .object([
                "tasks": .string(json2),
            ]),
            id: "e1"
        ))
        #expect(editResult.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        #expect(getResult.content.contains("[x] id:\(t1.uuidString)"))
        #expect(getResult.content.contains("[ ] id:\(t2.uuidString)"))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("update_plan_task updates status and description")
    func updateTask() async throws {
        let convID = UUID()
        let taskId = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json = "[{\"id\":\"\(taskId.uuidString)\",\"description\":\"Original\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let upd = ToolCall(
            name: AgentPlanToolProvider.updatePlanTaskToolName,
            arguments: .object([
                "task_id": .string(taskId.uuidString),
                "status": .string("in-progress"),
                "description": .string("Updated"),
            ]),
            id: "u1"
        )
        let ur = try await provider.executeTool(upd)
        #expect(ur.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        #expect(getResult.content.contains("[~] id:\(taskId.uuidString) - Updated"))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("get_plan without file returns success message")
    func getMissing() async throws {
        let convID = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        #expect(getResult.success == true)
        #expect(getResult.content.contains("No plan.md"))
    }

    @Test("updateTaskLine replaces matching id")
    func updateTaskLineUnit() throws {
        let tid = UUID()
        let md = """
        ## Tasks
        [ ] id:\(tid.uuidString) - old
        """
        let out = try AgentPlanToolProvider.updateTaskLine(
            in: md,
            taskId: tid,
            newStatus: .complete,
            newDescription: "new"
        )
        #expect(out.contains("[x] id:\(tid.uuidString) - new"))
        #expect(out.contains("old") == false)
    }

    @Test("update_plan_task fails when task_id is not in plan.md")
    func updateUnknownTaskFails() async throws {
        let convID = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let existing = UUID()
        let json = "[{\"id\":\"\(existing.uuidString)\",\"description\":\"A\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let missing = UUID()
        let upd = ToolCall(
            name: AgentPlanToolProvider.updatePlanTaskToolName,
            arguments: .object([
                "task_id": .string(missing.uuidString),
                "status": .string("complete"),
            ]),
            id: "u1"
        )
        let r = try await provider.executeTool(upd)
        #expect(r.success == false)
        #expect(r.error?.contains("not found") == true)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("update_plan_task with only status preserves description")
    func updateStatusOnly() async throws {
        let convID = UUID()
        let taskId = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json = "[{\"id\":\"\(taskId.uuidString)\",\"description\":\"Keep me\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let upd = ToolCall(
            name: AgentPlanToolProvider.updatePlanTaskToolName,
            arguments: .object([
                "task_id": .string(taskId.uuidString),
                "status": .string("blocked"),
            ]),
            id: "u1"
        )
        let r = try await provider.executeTool(upd)
        #expect(r.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        let doc = PlanMarkdownParser.parseDocument(getResult.content)
        #expect(doc.tasks.count == 1)
        #expect(doc.tasks[0] == PlanTaskInput(id: taskId, description: "Keep me", status: .blocked))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("update_plan_task with only description preserves status")
    func updateDescriptionOnly() async throws {
        let convID = UUID()
        let taskId = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json = "[{\"id\":\"\(taskId.uuidString)\",\"description\":\"Old\",\"status\":\"in-progress\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let upd = ToolCall(
            name: AgentPlanToolProvider.updatePlanTaskToolName,
            arguments: .object([
                "task_id": .string(taskId.uuidString),
                "description": .string("New text"),
            ]),
            id: "u1"
        )
        let r = try await provider.executeTool(upd)
        #expect(r.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        let doc = PlanMarkdownParser.parseDocument(getResult.content)
        #expect(doc.tasks[0] == PlanTaskInput(id: taskId, description: "New text", status: .inProgress))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("create_plan then get_plan content round-trips through PlanMarkdownParser")
    func createGetParseRoundTrip() async throws {
        let convID = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let u1 = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let u2 = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let tasks = [
            PlanTaskInput(id: u1, description: "One", status: .notStarted),
            PlanTaskInput(id: u2, description: "Two", status: .complete),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let tasksData = try encoder.encode(tasks)
        let tasksJSON = String(data: tasksData, encoding: .utf8)!

        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(tasksJSON),
                "overview": .string("Ov"),
                "goal": .string("Gl"),
            ]),
            id: "c1"
        ))

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        let doc = PlanMarkdownParser.parseDocument(getResult.content)
        #expect(doc.overview == "Ov")
        #expect(doc.goal == "Gl")
        #expect(doc.tasks == tasks)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("update_plan_task rejects invalid status string")
    func updateInvalidStatus() async throws {
        let convID = UUID()
        let taskId = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json = "[{\"id\":\"\(taskId.uuidString)\",\"description\":\"X\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let r = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.updatePlanTaskToolName,
            arguments: .object([
                "task_id": .string(taskId.uuidString),
                "status": .string("done"),
            ]),
            id: "u1"
        ))
        #expect(r.success == false)
        #expect(r.error?.contains("Invalid status") == true)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("update_plan_task requires at least one of status or description")
    func updateMissingMutation() async throws {
        let convID = UUID()
        let taskId = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json = "[{\"id\":\"\(taskId.uuidString)\",\"description\":\"X\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let r = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.updatePlanTaskToolName,
            arguments: .object([
                "task_id": .string(taskId.uuidString),
            ]),
            id: "u1"
        ))
        #expect(r.success == false)
        #expect(r.error?.contains("at least one") == true)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("updateTaskLine finds task when line has list bullet prefix")
    func updateTaskLineWithBulletPrefix() throws {
        let tid = UUID()
        let md = """
        ## Tasks
        - [ ] id:\(tid.uuidString) - line
        """
        let out = try AgentPlanToolProvider.updateTaskLine(
            in: md,
            taskId: tid,
            newStatus: .complete,
            newDescription: nil
        )
        #expect(out.contains("[x] id:\(tid.uuidString) - line"))
    }

    @Test("update_plan_task demotes prior in-progress when marking another in-progress")
    func updateDemotesOtherInProgress() async throws {
        let convID = UUID()
        let t1 = UUID()
        let t2 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json =
            "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"in-progress\"},{\"id\":\"\(t2.uuidString)\",\"description\":\"B\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object(["tasks": .string(json)]),
            id: "c1"
        ))

        let ur = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.updatePlanTaskToolName,
            arguments: .object([
                "task_id": .string(t2.uuidString),
                "status": .string("in-progress"),
            ]),
            id: "u1"
        ))
        #expect(ur.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        let doc = PlanMarkdownParser.parseDocument(getResult.content)
        let inProgress = doc.tasks.filter { $0.status == .inProgress }
        #expect(inProgress.count == 1)
        #expect(inProgress[0].id == t2)
        #expect(doc.tasks.first(where: { $0.id == t1 })?.status == .notStarted)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("add_plan_task demotes prior in-progress when adding in-progress")
    func addDemotesOtherInProgress() async throws {
        let convID = UUID()
        let t1 = UUID()
        let t2 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json = "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"in-progress\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object(["tasks": .string(json)]),
            id: "c1"
        ))

        let ar = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.addPlanTaskToolName,
            arguments: .object([
                "task_id": .string(t2.uuidString),
                "description": .string("B"),
                "status": .string("in-progress"),
            ]),
            id: "a1"
        ))
        #expect(ar.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        let doc = PlanMarkdownParser.parseDocument(getResult.content)
        let inProgress = doc.tasks.filter { $0.status == .inProgress }
        #expect(inProgress.count == 1)
        #expect(inProgress[0].id == t2)
        #expect(doc.tasks.first(where: { $0.id == t1 })?.status == .notStarted)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("create_plan demotes extras when multiple tasks are in-progress")
    func createDemotesExtraInProgress() async throws {
        let convID = UUID()
        let t1 = UUID()
        let t2 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json =
            "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"in-progress\"},{\"id\":\"\(t2.uuidString)\",\"description\":\"B\",\"status\":\"in-progress\"}]"
        let cr = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object(["tasks": .string(json)]),
            id: "c1"
        ))
        #expect(cr.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        let doc = PlanMarkdownParser.parseDocument(getResult.content)
        let inProgress = doc.tasks.filter { $0.status == .inProgress }
        #expect(inProgress.count == 1)
        #expect(inProgress[0].id == t1)
        #expect(doc.tasks.first(where: { $0.id == t2 })?.status == .notStarted)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("create/update/get plan tool metadata includes tasks and counts")
    func planToolMetadataIncludesTasks() async throws {
        let convID = UUID()
        let t1 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json = "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"in-progress\"}]"
        let create = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
                "overview": .string("Ov"),
                "goal": .string("G"),
            ]),
            id: "c1"
        ))
        #expect(create.success == true)
        guard case .object(let createMeta) = create.metadata else {
            Issue.record("expected metadata object")
            return
        }
        guard case .boolean(true) = createMeta["exists"] else {
            Issue.record("expected exists true")
            return
        }
        guard case .array(let tasks) = createMeta["tasks"] else {
            Issue.record("expected tasks array")
            return
        }
        #expect(tasks.count == 1)
        guard case .string(let inProgressId) = createMeta["inProgressTaskId"] else {
            Issue.record("expected inProgressTaskId")
            return
        }
        #expect(inProgressId == t1.uuidString)
        guard case .object(let counts) = createMeta["counts"] else {
            Issue.record("expected counts")
            return
        }
        guard case .integer(1) = counts["inProgress"] else {
            Issue.record("expected inProgress count 1")
            return
        }
        guard case .integer(1) = counts["total"] else {
            Issue.record("expected total count 1")
            return
        }

        let get = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        guard case .object(let getMeta) = get.metadata else {
            Issue.record("expected get metadata")
            return
        }
        guard case .boolean(true) = getMeta["exists"] else {
            Issue.record("expected get exists true")
            return
        }
        guard case .array(let getTasks) = getMeta["tasks"] else {
            Issue.record("expected get tasks")
            return
        }
        #expect(getTasks.count == 1)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("declare_agent_build_complete succeeds when every task is [x]")
    func declareCompleteSuccess() async throws {
        let convID = UUID()
        let t1 = UUID()
        let t2 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json =
            "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"complete\"},{\"id\":\"\(t2.uuidString)\",\"description\":\"B\",\"status\":\"complete\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let r = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.declareAgentBuildCompleteToolName,
            arguments: .object([:]),
            id: "d1"
        ))
        #expect(r.success == true)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("declare_agent_build_complete fails when a task stays open")
    func declareCompleteFailsOpen() async throws {
        let convID = UUID()
        let t1 = UUID()
        let t2 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json =
            "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"complete\"},{\"id\":\"\(t2.uuidString)\",\"description\":\"B\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let r = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.declareAgentBuildCompleteToolName,
            arguments: .object([:]),
            id: "d1"
        ))
        #expect(r.success == false)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("add_plan_task appends a task")
    func addPlanTaskAppends() async throws {
        let convID = UUID()
        let t1 = UUID()
        let t2 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json = "[{\"id\":\"\(t1.uuidString)\",\"description\":\"First\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let add = ToolCall(
            name: AgentPlanToolProvider.addPlanTaskToolName,
            arguments: .object([
                "task_id": .string(t2.uuidString),
                "description": .string("Second"),
                "status": .string("in-progress"),
            ]),
            id: "a1"
        )
        let ar = try await provider.executeTool(add)
        #expect(ar.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        #expect(getResult.content.contains("[ ] id:\(t1.uuidString)"))
        #expect(getResult.content.contains("[~] id:\(t2.uuidString) - Second"))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("add_plan_task fails when task_id already exists")
    func addPlanTaskDuplicateFails() async throws {
        let convID = UUID()
        let t1 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json = "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let add = ToolCall(
            name: AgentPlanToolProvider.addPlanTaskToolName,
            arguments: .object([
                "task_id": .string(t1.uuidString),
                "description": .string("Dup"),
                "status": .string("complete"),
            ]),
            id: "a1"
        )
        let ar = try await provider.executeTool(add)
        #expect(ar.success == false)
        #expect(ar.error?.contains("already exists") == true)

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("delete_plan_task removes a task")
    func deletePlanTaskRemoves() async throws {
        let convID = UUID()
        let t1 = UUID()
        let t2 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json =
            "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"not-started\"},{\"id\":\"\(t2.uuidString)\",\"description\":\"B\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json),
            ]),
            id: "c1"
        ))

        let del = ToolCall(
            name: AgentPlanToolProvider.deletePlanTaskToolName,
            arguments: .object([
                "task_id": .string(t1.uuidString),
            ]),
            id: "d1"
        )
        let dr = try await provider.executeTool(del)
        #expect(dr.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        #expect(getResult.content.contains("id:\(t1.uuidString)") == false)
        #expect(getResult.content.contains("[ ] id:\(t2.uuidString)"))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("addingTask and removingTask unit round-trip")
    func addRemoveTaskMarkdown() throws {
        let t1 = UUID()
        let t2 = UUID()
        let base = AgentPlanToolProvider.renderPlanMarkdown(
            overview: "O",
            goal: "G",
            notes: nil,
            tasks: [PlanTaskInput(id: t1, description: "One", status: .notStarted)]
        )
        let withTwo = try AgentPlanToolProvider.addingTask(
            PlanTaskInput(id: t2, description: "Two", status: .inProgress),
            to: base
        )
        #expect(PlanMarkdownParser.parseDocument(withTwo).tasks.count == 2)

        let back = try AgentPlanToolProvider.removingTask(id: t2, from: withTwo)
        #expect(PlanMarkdownParser.parseDocument(back).tasks.count == 1)
        #expect(back.contains("id:\(t2.uuidString)") == false)
    }

    @Test("create_plan with notes seeds ## Notes")
    func createPlanWithNotes() async throws {
        let convID = UUID()
        let taskId = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let tasksJSON = "[{\"id\":\"\(taskId.uuidString)\",\"description\":\"T\",\"status\":\"not-started\"}]"
        let create = ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(tasksJSON),
                "notes": .string("Project: /tmp/foo"),
            ]),
            id: "c1"
        )
        let r = try await provider.executeTool(create)
        #expect(r.success == true)

        let get = ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        )
        let getResult = try await provider.executeTool(get)
        #expect(getResult.content.contains("## Notes"))
        #expect(getResult.content.contains("Project: /tmp/foo"))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("add_plan_note appends to ## Notes")
    func addPlanNoteAppends() async throws {
        let convID = UUID()
        let taskId = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let tasksJSON = "[{\"id\":\"\(taskId.uuidString)\",\"description\":\"T\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(tasksJSON),
                "notes": .string("First block"),
            ]),
            id: "c1"
        ))

        let noteCall = ToolCall(
            name: AgentPlanToolProvider.addPlanNoteToolName,
            arguments: .object([
                "note": .string("Second block"),
            ]),
            id: "n1"
        )
        let nr = try await provider.executeTool(noteCall)
        #expect(nr.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        #expect(getResult.content.contains("First block"))
        #expect(getResult.content.contains("Second block"))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("edit_plan without notes parameter preserves existing notes")
    func editPlanPreservesNotesWhenOmitted() async throws {
        let convID = UUID()
        let t1 = UUID()
        let t2 = UUID()
        let stub = StubPlanDataProvider()
        stub.conversations[convID] = AgentPlanToolTestSupport.makeConversation(id: convID)
        let provider = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convID)

        let json1 = "[{\"id\":\"\(t1.uuidString)\",\"description\":\"A\",\"status\":\"not-started\"}]"
        _ = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string(json1),
                "notes": .string("Secret context: use env FOO"),
            ]),
            id: "c1"
        ))

        let json2 = """
        [{"id":"\(t1.uuidString)","description":"A","status":"not-started"},{"id":"\(t2.uuidString)","description":"B","status":"not-started"}]
        """
        let editResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.editPlanToolName,
            arguments: .object([
                "tasks": .string(json2),
            ]),
            id: "e1"
        ))
        #expect(editResult.success == true)

        let getResult = try await provider.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object([:]),
            id: "g1"
        ))
        #expect(getResult.content.contains("Secret context: use env FOO"))
        #expect(getResult.content.contains("[ ] id:\(t2.uuidString)"))

        #expect(AgentPlanStore.removeConversationDirectory(for: convID))
    }

    @Test("appendingNote merges markdown")
    func appendingNoteUnit() {
        let t = UUID()
        let base = AgentPlanToolProvider.renderPlanMarkdown(
            overview: "O",
            goal: "G",
            notes: "alpha",
            tasks: [PlanTaskInput(id: t, description: "One", status: .notStarted)]
        )
        let out = AgentPlanToolProvider.appendingNote("beta", to: base)
        let doc = PlanMarkdownParser.parseDocument(out)
        #expect(doc.notes.contains("alpha"))
        #expect(doc.notes.contains("beta"))
    }

    @Test("ignores leftover model-supplied conversation_id and binds active conversation")
    func ignoresModelSuppliedConversationID() async throws {
        let convA = UUID()
        let convB = UUID()
        defer {
            _ = AgentPlanStore.removeConversationDirectory(for: convA)
            _ = AgentPlanStore.removeConversationDirectory(for: convB)
        }
        let stub = StubPlanDataProvider()
        stub.conversations[convA] = AgentPlanToolTestSupport.makeConversation(id: convA)
        stub.conversations[convB] = AgentPlanToolTestSupport.makeConversation(id: convB)
        let providerB = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convB)
        let taskB = UUID()
        _ = try await providerB.executeTool(ToolCall(
            name: AgentPlanToolProvider.createPlanToolName,
            arguments: .object([
                "tasks": .string("[{\"id\":\"\(taskB.uuidString)\",\"description\":\"B only\",\"status\":\"not-started\"}]"),
            ]),
            id: "c-b"
        ))

        let providerA = AgentPlanToolTestSupport.makeProvider(dataProvider: stub, conversationID: convA)
        let get = try await providerA.executeTool(ToolCall(
            name: AgentPlanToolProvider.getPlanToolName,
            arguments: .object(["conversation_id": .string(convB.uuidString)]),
            id: "g-a"
        ))
        #expect(get.success == true)
        #expect(!get.content.contains("B only"))
        #expect(get.content.contains("No plan.md yet") || get.content.contains("create_plan"))
    }
}
