import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("APILayer tenancy routes")
struct APILayerTenancyRouteTests {
    @Test("PATCH /api/conversations/:id returns 428 without If-Match when strict mode enabled")
    func conversationPatchStrictModeRequiresIfMatch() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var conversationID = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
            })

            let updateJSON = #"{"topic":"strict mode update"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(conversationID)", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: updateJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionRequired)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_required")
            })
        }
    }

    @Test("POST /api/conversations/:id/branch returns 428 without If-Match when strict preconditions enabled")
    func conversationBranchStrictModeRequiresIfMatch() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            let branchJSON = #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#
            try await app.testing().test(.POST, "/api/conversations/\(cid)/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: branchJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionRequired)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_required")
            })
        }
    }

    @Test("POST /api/conversations/:id/branch returns 412 for stale If-Match when strict preconditions enabled")
    func conversationBranchStrictModePreconditionFailed() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
            })

            let branchJSON = #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#
            try await app.testing().test(.POST, "/api/conversations/\(cid)/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"msg-00000000-0000-0000-0000-000000000099\"")
                req.body = .init(string: branchJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionFailed)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_failed")
            })
        }
    }

    @Test("POST /api/conversations/:id/branch succeeds with matching transcript-tail If-Match when strict preconditions enabled")
    func conversationBranchStrictModeSucceedsWithTailETag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-rest-branch-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let harness = try LocalHarnessSessionPersistence(root: root)
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: harness
        )
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
            })

            let convUUID = try #require(UUID(uuidString: cid))
            let conversation = try #require(await runtimeSession.testing_modelConversation(conversationID: convUUID))
            await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
            await runtimeSession.testing_setActiveStreamingRun(conversationID: convUUID, runID: UUID())
            let userMsgID = UUID()
            await runtimeSession.testing_applyOrchestratorMessages([
                Message(id: userMsgID, role: .user, content: "branch-anchor", timestamp: Date(), toolCalls: []),
            ])

            let tailTag = "\"msg-\(userMsgID.uuidString.lowercased())\""
            let branchJSON = #"{"userMessageID":"\#(userMsgID.uuidString)"}"#
            try await app.testing().test(.POST, "/api/conversations/\(cid)/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: tailTag)
                req.body = .init(string: branchJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("POST /api/conversations/:id/preview-context-compaction returns 401 when token wrong")
    func previewCompactionBadToken() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(
            ContextCompactionPreviewAPISettings(isRouteEnabled: true, authToken: "secret")
        )
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"s"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
                #expect(conversationID.isEmpty == false)
            })
            try await app.testing().test(.POST, "/api/conversations/\(conversationID)/preview-context-compaction", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "wrong")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("POST /api/conversations/:id/tool-approvals returns 401 when strict tenancy requires bearer token")
    func strictTenancyToolApprovalRequiresOwnerHeader() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let owner = UUID()
        let api = APILayer(port: 0)
        await APILayerRESTRouteTestSupport.configureStrictTenancyAuth(on: api)
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: owner)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"tool approval tenancy"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: auth)
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
                #expect(conversationID.isEmpty == false)
            })

            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID)/tool-approvals",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(string: #"{"toolName":"delegate_remote_research","status":"approved"}"#)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                }
            )
        }
    }

    @Test("POST /api/conversations/:id/completion-announcements returns 401 when strict tenancy requires bearer token")
    func strictTenancyCompletionAnnounceRequiresOwnerHeader() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let owner = UUID()
        let api = APILayer(port: 0)
        await APILayerRESTRouteTestSupport.configureStrictTenancyAuth(on: api)
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: owner)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"completion tenancy"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: auth)
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
                #expect(conversationID.isEmpty == false)
            })

            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID)/completion-announcements",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(string: #"{"delegateHandleID":"h","toolCallID":"t","lifecycleID":"l","status":"done"}"#)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                }
            )
        }
    }

    @Test("Distinct X-SAH-Client-Session headers isolate GET /api/conversations/:id reads")
    func distinctClientSessionsIsolateConversationReads() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString
        var idA = ""
        var idB = ""

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))

            let createA = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"alpha-session-marker"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionA)
                req.headers.contentType = .json
                req.body = .init(string: createA)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                idA = (body?["conversationID"] as? String) ?? ""
                #expect(idA.isEmpty == false)
            })

            let createB = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"beta-session-marker"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionB)
                req.headers.contentType = .json
                req.body = .init(string: createB)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                idB = (body?["conversationID"] as? String) ?? ""
                #expect(idB.isEmpty == false)
            })

            try await app.testing().test(.GET, "/api/conversations/\(idA)", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionA)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let messages = json?["messages"] as? [[String: Any]]
                let systemContents = messages?.compactMap { ($0["role"] as? String) == "system" ? ($0["content"] as? String) : nil } ?? []
                #expect(systemContents.contains { $0.contains("alpha-session-marker") })
                #expect(systemContents.contains { $0.contains("beta-session-marker") } == false)
            })

            try await app.testing().test(.GET, "/api/conversations/\(idB)", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionB)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let messages = json?["messages"] as? [[String: Any]]
                let systemContents = messages?.compactMap { ($0["role"] as? String) == "system" ? ($0["content"] as? String) : nil } ?? []
                #expect(systemContents.contains { $0.contains("beta-session-marker") })
                #expect(systemContents.contains { $0.contains("alpha-session-marker") } == false)
            })
        }
    }

    @Test("POST /api/conversations returns 401 when strict tenancy requires bearer token")
    func strictTenancyCreateRequiresOwnerHeader() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await APILayerRESTRouteTestSupport.configureStrictTenancyAuth(on: api)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Strict tenancy returns 403 when mutating another owner's conversation")
    func strictTenancyPatchForbiddenForWrongOwner() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        let ownerA = UUID()
        let ownerB = UUID()
        await APILayerRESTRouteTestSupport.configureStrictTenancyAuth(on: api)
        let authA = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: ownerA)
        let authB = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: ownerB)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: authA)
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            let bumpJSON = #"{"topic":"cross-tenant"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(cid)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: authB)
                req.body = .init(string: bumpJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("DELETE /api/conversations/:id returns 428 without If-Match when strict preconditions enabled")
    func conversationDeleteStrictRequiresIfMatch() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"strict-delete"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            try await app.testing().test(.DELETE, "/api/conversations/\(cid)", afterResponse: { res async throws in
                #expect(res.status == .preconditionRequired)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_required")
            })
        }
    }

    @Test("POST /api/approvals/:id resolves on the unified decision vocabulary")
    func unifiedApprovalResolveAllowAlways() async throws {
        try await ExecApprovalStoreTestSupport.isolated {
            let conversation = ProtocolOnlyConversationGatewayStub()
            let runtime = ProtocolOnlyRuntimeGatewayStub()
            let modelProvider = APILayerRESTStubModelProvider(models: [])
            let api = APILayer(port: 0)
            let grants = InMemoryExecApprovalGrantStore()
            await ExecApprovalStore.shared.configure(grantStore: grants)
            let conversationID = UUID()
            await ExecApprovalStore.shared.registerPending(
                id: "unified-1",
                command: "git push origin main",
                scope: ExecApprovalScope(conversationID: conversationID, ownerAccountID: nil)
            )

            try await withApp { app in
                await api.configureRoutesForTesting(
                    app: app,
                    conversation: conversation,
                    runtime: runtime,
                    modelProvider: modelProvider
                )
                try await app.testing().test(
                    .POST,
                    "/api/approvals/unified-1",
                    beforeRequest: { req in
                        try req.content.encode(["decision": "allowAlways"])
                    }
                ) { res async throws in
                    #expect(res.status == .ok)
                }
                #expect(await ExecApprovalStore.shared.isDurableApproved(command: "git status"))
            }
        }
    }

    @Test("POST /api/approvals/:id returns 403 for cross-tenant resolve under strict tenancy")
    func unifiedApprovalResolveCrossTenantForbidden() async throws {
        try await ExecApprovalStoreTestSupport.isolated {
            let ownerA = UUID()
            let ownerB = UUID()
            let conversationID = UUID()
            let model = APILayerRESTRouteTestSupport.makeTestModel()
            let conversationRow = ModelConversation(
                id: conversationID,
                model: model,
                messages: [],
                createdAt: Date(),
                updatedAt: Date(),
                topic: "exec-approval-tenancy",
                description: nil,
                interactionMode: .chat,
                metadata: nil,
                ownerAccountID: ownerA,
                lineageKind: .root,
                origin: .user
            )
            let conversation = ProtocolOnlyConversationGatewayStub(
                conversationsByID: [conversationID: conversationRow]
            )
            let runtime = ProtocolOnlyRuntimeGatewayStub()
            let modelProvider = APILayerRESTStubModelProvider(models: [model])
            let api = APILayer(port: 0)
            await APILayerRESTRouteTestSupport.configureStrictTenancyAuth(on: api)
            let authB = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: ownerB)
            await ExecApprovalStore.shared.registerPending(
                id: "cross-tenant-1",
                command: "git push origin main",
                scope: ExecApprovalScope(conversationID: conversationID, ownerAccountID: ownerA)
            )

            try await withApp { app in
                await api.configureRoutesForTesting(
                    app: app,
                    conversation: conversation,
                    runtime: runtime,
                    modelProvider: modelProvider
                )
                try await app.testing().test(
                    .POST,
                    "/api/approvals/cross-tenant-1",
                    beforeRequest: { req in
                        req.headers.replaceOrAdd(name: .authorization, value: authB)
                        try req.content.encode(["decision": "allowAlways"])
                    }
                ) { res async throws in
                    #expect(res.status == .forbidden)
                }
            }
        }
    }

    @Test("POST /api/approvals/:id returns 404 for unknown approval")
    func unifiedApprovalResolveUnknown() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = APILayerRESTStubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(
                .POST,
                "/api/approvals/missing-id",
                beforeRequest: { req in
                    try req.content.encode(["decision": "deny"])
                }
            ) { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/exec-approvals/grants returns sorted command names")
    func execApprovalGrantsList() async throws {
        try await ExecApprovalStoreTestSupport.isolated {
            let conversation = ProtocolOnlyConversationGatewayStub()
            let runtime = ProtocolOnlyRuntimeGatewayStub()
            let modelProvider = APILayerRESTStubModelProvider(models: [])
            let api = APILayer(port: 0)
            await ExecApprovalStore.shared.configure(
                grantStore: InMemoryExecApprovalGrantStore(commandNames: ["grep", "git"])
            )

            try await withApp { app in
                await api.configureRoutesForTesting(
                    app: app,
                    conversation: conversation,
                    runtime: runtime,
                    modelProvider: modelProvider
                )
                try await app.testing().test(.GET, "/api/exec-approvals/grants") { res async throws in
                    #expect(res.status == .ok)
                    let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(body?["commandNames"] as? [String] == ["git", "grep"])
                }
            }
        }
    }

    @Test("DELETE /api/exec-approvals/grants/:commandName removes an existing grant")
    func execApprovalGrantsRevoke() async throws {
        try await ExecApprovalStoreTestSupport.isolated {
            let conversation = ProtocolOnlyConversationGatewayStub()
            let runtime = ProtocolOnlyRuntimeGatewayStub()
            let modelProvider = APILayerRESTStubModelProvider(models: [])
            let api = APILayer(port: 0)
            await ExecApprovalStore.shared.configure(
                grantStore: InMemoryExecApprovalGrantStore(commandNames: ["git", "npm"])
            )

            try await withApp { app in
                await api.configureRoutesForTesting(
                    app: app,
                    conversation: conversation,
                    runtime: runtime,
                    modelProvider: modelProvider
                )
                try await app.testing().test(.DELETE, "/api/exec-approvals/grants/git") { res async throws in
                    #expect(res.status == .ok)
                }
                #expect(await ExecApprovalStore.shared.listDurableGrants() == ["npm"])
            }
        }
    }

    @Test("DELETE /api/exec-approvals/grants/:commandName accepts percent-encoded names")
    func execApprovalGrantsRevokePercentEncoded() async throws {
        try await ExecApprovalStoreTestSupport.isolated {
            let conversation = ProtocolOnlyConversationGatewayStub()
            let runtime = ProtocolOnlyRuntimeGatewayStub()
            let modelProvider = APILayerRESTStubModelProvider(models: [])
            let api = APILayer(port: 0)
            await ExecApprovalStore.shared.configure(
                grantStore: InMemoryExecApprovalGrantStore(commandNames: ["git status"])
            )

            try await withApp { app in
                await api.configureRoutesForTesting(
                    app: app,
                    conversation: conversation,
                    runtime: runtime,
                    modelProvider: modelProvider
                )
                try await app.testing().test(.DELETE, "/api/exec-approvals/grants/git%20status") { res async throws in
                    #expect(res.status == .ok)
                }
                #expect(await ExecApprovalStore.shared.listDurableGrants() == [])
            }
        }
    }

    @Test("DELETE /api/exec-approvals/grants/:commandName returns 404 for unknown grant")
    func execApprovalGrantsRevokeNotFound() async throws {
        try await ExecApprovalStoreTestSupport.isolated {
            let conversation = ProtocolOnlyConversationGatewayStub()
            let runtime = ProtocolOnlyRuntimeGatewayStub()
            let modelProvider = APILayerRESTStubModelProvider(models: [])
            let api = APILayer(port: 0)
            await ExecApprovalStore.shared.configure(grantStore: InMemoryExecApprovalGrantStore())

            try await withApp { app in
                await api.configureRoutesForTesting(
                    app: app,
                    conversation: conversation,
                    runtime: runtime,
                    modelProvider: modelProvider
                )
                try await app.testing().test(.DELETE, "/api/exec-approvals/grants/missing") { res async throws in
                    #expect(res.status == .notFound)
                    let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(body?["type"] as? String == "error")
                    #expect(body?["message"] as? String == "Exec approval grant not found")
                }
            }
        }
    }

    @Test("Static exec-approvals grants routes register before :id")
    func execApprovalGrantsRoutesRegisteredBeforeID() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = APILayerRESTStubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            func pathDescription(_ route: Route) -> String {
                route.path.map { component in
                    switch component {
                    case .constant(let value): return value
                    case .parameter(let name): return ":\(name)"
                    case .anything: return "*"
                    case .catchall: return "**"
                    }
                }.joined(separator: "/")
            }
            let execApprovalRoutes = app.routes.all.filter { route in
                pathDescription(route).hasPrefix("api/exec-approvals")
            }
            let grantsGetIndex = execApprovalRoutes.firstIndex { route in
                route.method == .GET && pathDescription(route) == "api/exec-approvals/grants"
            }
            let grantsDeleteIndex = execApprovalRoutes.firstIndex { route in
                route.method == .DELETE && pathDescription(route) == "api/exec-approvals/grants/:commandName"
            }
            let postIDIndex = execApprovalRoutes.firstIndex { route in
                route.method == .POST && pathDescription(route) == "api/exec-approvals/:id"
            }
            #expect(grantsGetIndex != nil)
            #expect(grantsDeleteIndex != nil)
            #expect(postIDIndex != nil)
            if let grantsGetIndex, let grantsDeleteIndex, let postIDIndex {
                #expect(grantsGetIndex < postIDIndex)
                #expect(grantsDeleteIndex < postIDIndex)
            }
        }
    }
}
