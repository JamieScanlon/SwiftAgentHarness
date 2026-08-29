import Foundation
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

private actor MutableRunsStore {
    private var runsByID: [UUID: ConversationRunInfo]
    private var listOverride: ConversationRunListResponse?

    init(runs: [ConversationRunInfo] = []) {
        self.runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
    }

    func setRun(_ run: ConversationRunInfo) {
        runsByID[run.id] = run
    }

    func setListOverride(_ response: ConversationRunListResponse?) {
        listOverride = response
    }

    func getRun(runID: UUID, includeProjectionDetail: Bool) -> ConversationRunInfo? {
        guard let run = runsByID[runID] else { return nil }
        guard includeProjectionDetail else {
            return ConversationRunInfo(
                id: run.id,
                conversationID: run.conversationID,
                startedAt: run.startedAt,
                endedAt: run.endedAt,
                outcome: run.outcome,
                iterationCount: run.iterationCount,
                toolCallCount: run.toolCallCount,
                firstMessageId: run.firstMessageId,
                lastMessageId: run.lastMessageId,
                cancellationReason: run.cancellationReason,
                errorDetails: run.errorDetails,
                terminalReason: run.terminalReason,
                tokenRollup: run.tokenRollup,
                costRollup: run.costRollup,
                projectionDetail: nil
            )
        }
        return run
    }

    func listRuns(filter: ConversationRunListFilter) -> ConversationRunListResponse {
        if let listOverride { return listOverride }
        var runs = Array(runsByID.values)
        if let outcomes = filter.outcomes, !outcomes.isEmpty {
            let allowed = Set(outcomes)
            runs = runs.filter { allowed.contains($0.outcome) }
        }
        runs.sort { lhs, rhs in
            (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
        let limited = Array(runs.prefix(filter.limit))
        return ConversationRunListResponse(runs: limited, cursor: nil, total: runs.count)
    }
}

private final class MutableRunsRuntimeStub: APILayerChatRuntimeManaging, Sendable {
    let store: MutableRunsStore

    init(store: MutableRunsStore) {
        self.store = store
    }

    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        _ = conversationID
        return AsyncStream { $0.finish() }
    }

    func apiSendMessageAndStreamResponse(
        conversationID: UUID,
        _ text: String,
        images: [Message.Image],
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass? = nil,
        systemReminder: String?,
        originSurface: String? = nil,
        originSenderID: String? = nil,
        originSenderIsOwner: Bool? = nil
    ) async throws -> ChatStreamResponse {
        _ = (
            conversationID,
            text,
            images,
            enableTools,
            enableAgents,
            expectedPreviousTailHarnessMessageID,
            inputTrustRaw,
            resolvedInputTrustClass,
            systemReminder,
            originSurface,
            originSenderID
        )
        throw APILayerConversationAPIError.unsupported
    }

    func apiCancelMessageStream() async {}

    func apiSetOrchestrationStateTopicRefreshHandler(
        _ handler: @escaping @Sendable (UUID, ConversationOrchestrationState) async -> Void
    ) async {
        _ = handler
    }

    func apiClearOrchestrationStateTopicRefreshHandler() async {}

    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        _ = (conversationID, runID)
    }

    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        _ = conversationID
        return await store.listRuns(filter: filter)
    }

    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        _ = conversationID
        return await store.getRun(runID: runID, includeProjectionDetail: includeProjectionDetail)
    }
}

private enum RunsRouteETagTestSupport {
    static func makeModel() -> Model {
        APILayerRESTRouteTestSupport.makeTestModel()
    }

    static func makeOpenRun(conversationID: UUID, runID: UUID = UUID()) -> ConversationRunInfo {
        ConversationRunInfo(
            id: runID,
            conversationID: conversationID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: nil,
            outcome: .open,
            iterationCount: 0,
            toolCallCount: 0,
            firstMessageId: "msg-first",
            lastMessageId: nil
        )
    }

    static func withDetail(_ run: ConversationRunInfo) -> ConversationRunInfo {
        ConversationRunInfo(
            id: run.id,
            conversationID: run.conversationID,
            startedAt: run.startedAt,
            endedAt: run.endedAt,
            outcome: run.outcome,
            iterationCount: run.iterationCount,
            toolCallCount: run.toolCallCount,
            firstMessageId: run.firstMessageId,
            lastMessageId: run.lastMessageId,
            cancellationReason: run.cancellationReason,
            errorDetails: run.errorDetails,
            terminalReason: run.terminalReason,
            tokenRollup: run.tokenRollup,
            costRollup: run.costRollup,
            projectionDetail: ConversationRunProjectionDetail(
                assistantMessageCount: 2,
                toolRollup: ConversationRunToolRollup(distinctToolNames: ["web_search"], totalToolCallSlots: 1)
            )
        )
    }
}

@Suite("APILayer runs routes")
struct APILayerRunsRouteTests {
    @Test("POST /api/conversations/:id/cancel returns 409 run_not_in_flight without active run")
    func conversationCancelWithoutActiveRunReturnsConflict() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"cancel-idempotent"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            let requestedRunID = UUID()
            let body = #"{"runId":"\#(requestedRunID.uuidString)"}"#
            try await app.testing().test(.POST, "/api/conversations/\(cid)/cancel", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["code"] as? String == "run_not_in_flight")
            })
        }
    }

    @Test("runETag remains an identity token for cancel If-Match")
    func runETagIdentityFormatUnchanged() {
        let runID = UUID(uuidString: "BB4AE52A-D208-4923-A1E8-BD28D83C5DD4")!
        #expect(APILayer.runETag(runID: runID) == "\"run-bb4ae52a-d208-4923-a1e8-bd28d83c5dd4\"")
        #expect(APILayer.runETag(runID: nil) == "\"run-none\"")
    }

    @Test("GET /runs/:runId returns 200 with new ETag after open→terminal mutation; matching ETag returns 304")
    func getRunETagInvalidatesOnTerminalOutcomes() async throws {
        let conversationID = UUID()
        let runID = UUID()
        let open = RunsRouteETagTestSupport.makeOpenRun(conversationID: conversationID, runID: runID)
        let store = MutableRunsStore(runs: [open])
        let runtime = MutableRunsRuntimeStub(store: store)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let api = APILayer(port: 0)
        let modelProvider = APILayerRESTStubModelProvider(models: [RunsRouteETagTestSupport.makeModel()])

        let terminals: [(ConversationRunOutcome, ConversationRunInfo)] = [
            (
                .errored,
                ConversationRunInfo(
                    id: runID,
                    conversationID: conversationID,
                    startedAt: open.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    outcome: .errored,
                    iterationCount: 1,
                    toolCallCount: 0,
                    firstMessageId: open.firstMessageId,
                    lastMessageId: open.firstMessageId,
                    errorDetails: ConversationRunErrorDetails(class: "run_orphaned", message: "stale_running_reconciled")
                )
            ),
            (
                .cancelled,
                ConversationRunInfo(
                    id: runID,
                    conversationID: conversationID,
                    startedAt: open.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_101),
                    outcome: .cancelled,
                    iterationCount: 1,
                    toolCallCount: 0,
                    firstMessageId: open.firstMessageId,
                    lastMessageId: open.firstMessageId,
                    cancellationReason: "user_stop_requested"
                )
            ),
            (
                .completed,
                ConversationRunInfo(
                    id: runID,
                    conversationID: conversationID,
                    startedAt: open.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_102),
                    outcome: .completed,
                    iterationCount: 2,
                    toolCallCount: 1,
                    firstMessageId: open.firstMessageId,
                    lastMessageId: "msg-last"
                )
            ),
            (
                .bounded,
                ConversationRunInfo(
                    id: runID,
                    conversationID: conversationID,
                    startedAt: open.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_103),
                    outcome: .bounded,
                    iterationCount: 3,
                    toolCallCount: 0,
                    firstMessageId: open.firstMessageId,
                    lastMessageId: "msg-last"
                )
            ),
        ]

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )

            for (outcome, terminal) in terminals {
                await store.setRun(open)
                var openETag: String?
                try await app.testing().test(
                    .GET,
                    "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)"
                ) { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: .cacheControl) == "no-cache")
                    openETag = res.headers.first(name: .eTag)
                    let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(body?["outcome"] as? String == ConversationRunOutcome.open.rawValue)
                }
                let previous = try #require(openETag)
                #expect(previous.hasPrefix("\"reg-"))

                await store.setRun(terminal)
                var terminalETag: String?
                try await app.testing().test(
                    .GET,
                    "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)",
                    beforeRequest: { req in
                        req.headers.replaceOrAdd(name: .ifNoneMatch, value: previous)
                    },
                    afterResponse: { res async throws in
                        #expect(res.status == .ok)
                        terminalETag = res.headers.first(name: .eTag)
                        let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                        #expect(body?["outcome"] as? String == outcome.rawValue)
                        #expect(terminalETag != previous)
                    }
                )
                let current = try #require(terminalETag)
                try await app.testing().test(
                    .GET,
                    "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)",
                    beforeRequest: { req in
                        req.headers.replaceOrAdd(name: .ifNoneMatch, value: current)
                    },
                    afterResponse: { res async throws in
                        #expect(res.status == .notModified)
                        #expect(res.headers.first(name: .eTag) == current)
                        #expect(res.headers.first(name: .cacheControl) == "no-cache")
                    }
                )
            }
        }
    }

    @Test("GET /runs/:runId ETag changes when represented ConversationRunInfo fields change")
    func getRunETagTracksRepresentedFieldMutations() async throws {
        let conversationID = UUID()
        let runID = UUID()
        var run = RunsRouteETagTestSupport.makeOpenRun(conversationID: conversationID, runID: runID)
        let store = MutableRunsStore(runs: [run])
        let runtime = MutableRunsRuntimeStub(store: store)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let api = APILayer(port: 0)
        let modelProvider = APILayerRESTStubModelProvider(models: [RunsRouteETagTestSupport.makeModel()])

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )

            func fetchETag() async throws -> String {
                var etag: String?
                try await app.testing().test(
                    .GET,
                    "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)"
                ) { res async throws in
                    #expect(res.status == .ok)
                    etag = res.headers.first(name: .eTag)
                }
                return try #require(etag)
            }

            var previous = try await fetchETag()

            let mutations: [ConversationRunInfo] = [
                ConversationRunInfo(
                    id: runID, conversationID: conversationID, startedAt: run.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_200), outcome: .open,
                    iterationCount: 0, toolCallCount: 0, firstMessageId: run.firstMessageId
                ),
                ConversationRunInfo(
                    id: runID, conversationID: conversationID, startedAt: run.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_200), outcome: .open,
                    iterationCount: 4, toolCallCount: 0, firstMessageId: run.firstMessageId
                ),
                ConversationRunInfo(
                    id: runID, conversationID: conversationID, startedAt: run.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_200), outcome: .open,
                    iterationCount: 4, toolCallCount: 2, firstMessageId: run.firstMessageId
                ),
                ConversationRunInfo(
                    id: runID, conversationID: conversationID, startedAt: run.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_200), outcome: .open,
                    iterationCount: 4, toolCallCount: 2, firstMessageId: run.firstMessageId,
                    lastMessageId: "msg-tail"
                ),
                ConversationRunInfo(
                    id: runID, conversationID: conversationID, startedAt: run.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_200), outcome: .cancelled,
                    iterationCount: 4, toolCallCount: 2, firstMessageId: run.firstMessageId,
                    lastMessageId: "msg-tail", cancellationReason: "user_stop_requested"
                ),
                ConversationRunInfo(
                    id: runID, conversationID: conversationID, startedAt: run.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_200), outcome: .errored,
                    iterationCount: 4, toolCallCount: 2, firstMessageId: run.firstMessageId,
                    lastMessageId: "msg-tail",
                    errorDetails: ConversationRunErrorDetails(class: "run_orphaned", message: "stale_running_reconciled")
                ),
                ConversationRunInfo(
                    id: runID, conversationID: conversationID, startedAt: run.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_200), outcome: .errored,
                    iterationCount: 4, toolCallCount: 2, firstMessageId: run.firstMessageId,
                    lastMessageId: "msg-tail",
                    errorDetails: ConversationRunErrorDetails(class: "run_orphaned", message: "stale_running_reconciled"),
                    tokenRollup: ConversationRunTokenRollup(promptTokens: 1, completionTokens: 2, totalTokens: 3),
                    costRollup: ConversationRunCostRollup(usd: 0.01)
                ),
            ]

            for next in mutations {
                await store.setRun(next)
                let current = try await fetchETag()
                #expect(current != previous)
                previous = current
                run = next
            }
        }
    }

    @Test("GET /runs/:runId detail=true and detail=false do not share ETags when bodies differ")
    func getRunDetailQueryUsesDistinctETags() async throws {
        let conversationID = UUID()
        let runID = UUID()
        let run = RunsRouteETagTestSupport.withDetail(
            RunsRouteETagTestSupport.makeOpenRun(conversationID: conversationID, runID: runID)
        )
        let store = MutableRunsStore(runs: [run])
        let runtime = MutableRunsRuntimeStub(store: store)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let api = APILayer(port: 0)
        let modelProvider = APILayerRESTStubModelProvider(models: [RunsRouteETagTestSupport.makeModel()])

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )

            var plainETag: String?
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)"
            ) { res async throws in
                #expect(res.status == .ok)
                plainETag = res.headers.first(name: .eTag)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["projectionDetail"] == nil)
            }

            var detailETag: String?
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)?detail=1"
            ) { res async throws in
                #expect(res.status == .ok)
                detailETag = res.headers.first(name: .eTag)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["projectionDetail"] != nil)
            }

            let plain = try #require(plainETag)
            let detail = try #require(detailETag)
            #expect(plain != detail)

            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)?detail=1",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifNoneMatch, value: plain)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: .eTag) == detail)
                }
            )
        }
    }

    @Test("GET /runs and /runs/:runId ETags change when only terminalReason changes")
    func listAndGetRunETagInvalidateOnTerminalReasonOnly() async throws {
        let conversationID = UUID()
        let runID = UUID()
        let base = ConversationRunInfo(
            id: runID,
            conversationID: conversationID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_010),
            outcome: .bounded,
            iterationCount: 3,
            toolCallCount: 1,
            firstMessageId: "msg-first",
            lastMessageId: "msg-last"
        )
        let store = MutableRunsStore(runs: [base])
        let runtime = MutableRunsRuntimeStub(store: store)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let api = APILayer(port: 0)
        let modelProvider = APILayerRESTStubModelProvider(models: [RunsRouteETagTestSupport.makeModel()])

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )

            var listETag: String?
            var getETag: String?
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs?limit=1"
            ) { res async throws in
                #expect(res.status == .ok)
                listETag = res.headers.first(name: .eTag)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let runs = body?["runs"] as? [[String: Any]]
                #expect(runs?.first?["terminalReason"] == nil)
                #expect(runs?.first?["markerKind"] == nil)
            }
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)"
            ) { res async throws in
                #expect(res.status == .ok)
                getETag = res.headers.first(name: .eTag)
            }
            let previousList = try #require(listETag)
            let previousGet = try #require(getETag)

            await store.setRun(
                ConversationRunInfo(
                    id: runID,
                    conversationID: conversationID,
                    startedAt: base.startedAt,
                    endedAt: base.endedAt,
                    outcome: .bounded,
                    iterationCount: base.iterationCount,
                    toolCallCount: base.toolCallCount,
                    firstMessageId: base.firstMessageId,
                    lastMessageId: base.lastMessageId,
                    terminalReason: ConversationRunTerminalReason(
                        category: .boundedStop,
                        boundedReason: .maxAgentIterations
                    )
                )
            )

            var nextListETag: String?
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs?limit=1",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifNoneMatch, value: previousList)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    nextListETag = res.headers.first(name: .eTag)
                    let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    let runs = body?["runs"] as? [[String: Any]]
                    let reason = runs?.first?["terminalReason"] as? [String: Any]
                    #expect(reason?["category"] as? String == ConversationRunTerminalCategory.boundedStop.rawValue)
                    #expect(reason?["boundedReason"] as? String == ConversationRunBoundedReason.maxAgentIterations.rawValue)
                    #expect(runs?.first?["markerKind"] == nil)
                }
            )
            let currentList = try #require(nextListETag)
            #expect(currentList != previousList)

            var nextGetETag: String?
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifNoneMatch, value: previousGet)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    nextGetETag = res.headers.first(name: .eTag)
                    let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    let reason = body?["terminalReason"] as? [String: Any]
                    #expect(reason?["category"] as? String == ConversationRunTerminalCategory.boundedStop.rawValue)
                    #expect(body?["markerKind"] == nil)
                }
            )
            let currentGet = try #require(nextGetETag)
            #expect(currentGet != previousGet)

            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs?limit=1",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifNoneMatch, value: currentList)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notModified)
                    #expect(res.headers.first(name: .eTag) == currentList)
                }
            )
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifNoneMatch, value: currentGet)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notModified)
                    #expect(res.headers.first(name: .eTag) == currentGet)
                }
            )
        }
    }

    @Test("GET /runs list ETag changes on outcome-only update and returns 304 when unchanged")
    func listRunsETagIsRepresentationSensitive() async throws {
        let conversationID = UUID()
        let runID = UUID()
        let open = RunsRouteETagTestSupport.makeOpenRun(conversationID: conversationID, runID: runID)
        let store = MutableRunsStore(runs: [open])
        let runtime = MutableRunsRuntimeStub(store: store)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let api = APILayer(port: 0)
        let modelProvider = APILayerRESTStubModelProvider(models: [RunsRouteETagTestSupport.makeModel()])

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )

            var openListETag: String?
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs?limit=10"
            ) { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == "no-cache")
                openListETag = res.headers.first(name: .eTag)
                #expect(openListETag?.hasPrefix("\"reg-") == true)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["total"] as? Int == 1)
            }
            let previous = try #require(openListETag)

            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs?limit=10",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifNoneMatch, value: previous)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notModified)
                    #expect(res.headers.first(name: .cacheControl) == "no-cache")
                }
            )

            await store.setRun(
                ConversationRunInfo(
                    id: runID,
                    conversationID: conversationID,
                    startedAt: open.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_700_000_050),
                    outcome: .errored,
                    iterationCount: 1,
                    toolCallCount: 0,
                    firstMessageId: open.firstMessageId,
                    lastMessageId: open.firstMessageId,
                    errorDetails: ConversationRunErrorDetails(class: "run_orphaned", message: "stale_running_reconciled")
                )
            )

            var erroredListETag: String?
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs?limit=10",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifNoneMatch, value: previous)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    erroredListETag = res.headers.first(name: .eTag)
                    let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    let runs = body?["runs"] as? [[String: Any]]
                    #expect(runs?.first?["outcome"] as? String == ConversationRunOutcome.errored.rawValue)
                }
            )
            let current = try #require(erroredListETag)
            #expect(current != previous)

            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs?outcomes=open&limit=10",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifNoneMatch, value: current)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: .eTag) != current)
                }
            )
        }
    }

    @Test("POST cancel If-Match still uses identity runETag, not representation hash")
    func cancelIfMatchUsesIdentityRunETag() async throws {
        let conversationID = UUID()
        let runID = UUID()
        let model = RunsRouteETagTestSupport.makeModel()
        let conversationRow = ModelConversation(
            id: conversationID,
            model: model,
            currentRunID: runID
        )
        let conversation = ProtocolOnlyConversationGatewayStub(
            conversationsByID: [conversationID: conversationRow]
        )
        let store = MutableRunsStore(runs: [
            RunsRouteETagTestSupport.makeOpenRun(conversationID: conversationID, runID: runID)
        ])
        let runtime = MutableRunsRuntimeStub(store: store)
        let api = APILayer(port: 0)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
        let identity = APILayer.runETag(runID: runID)
        let staleIdentity = APILayer.runETag(runID: UUID())
        let representationETag = APILayer.registryETag(payloadData: Data("not-a-run-identity".utf8))

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )

            let cancelBody = #"{"runId":"\#(runID.uuidString)"}"#
            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID.uuidString)/cancel",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.headers.replaceOrAdd(name: .ifMatch, value: staleIdentity)
                    req.body = .init(string: cancelBody)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .preconditionFailed)
                    #expect(res.headers.first(name: .eTag) == identity)
                }
            )

            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID.uuidString)/cancel",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.headers.replaceOrAdd(name: .ifMatch, value: representationETag)
                    req.body = .init(string: cancelBody)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .preconditionFailed)
                    #expect(res.headers.first(name: .eTag) == identity)
                }
            )

            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID.uuidString)/cancel",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.headers.replaceOrAdd(name: .ifMatch, value: identity)
                    req.body = .init(string: cancelBody)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(body?["outcome"] as? String == ConversationRunOutcome.cancelled.rawValue)
                }
            )
        }
    }
}
