import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("APILayer conversation projection routes")
struct APILayerConversationProjectionRouteTests {
    @Test("GET /api/conversations/:id/checkpoints/latest returns all checkpoint taxonomy kinds")
    func conversationLatestCheckpointTaxonomyKinds() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        var model = APILayerRESTRouteTestSupport.makeTestModel()
        model.maxContextLength = 2_500
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "checkpoint-taxonomy")
        let convID = try #require(await runtimeSession.currentConversationID)
        try await runtimeSession.selectConversation(conversationID: convID)
        await runtimeSession.appendMessagesToConversation([
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "checkpoint-seed-a1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "checkpoint-seed-a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u3", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "checkpoint-seed-a3", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u4", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "checkpoint-seed-a4", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u5", timestamp: Date(), toolCalls: []),
        ], conversationID: convID)
        let rawMessages = try await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiListMessagesThrowing(conversationID: convID)
        let compactionConfig = ConversationTransformConfiguration.default.contextCompaction
        let modelLimit = model.maxContextLength ?? compactionConfig.fallbackContextLimitTokens
        let rawMiddle = ContextCompactionCheckpointSupport.rawMiddle(
            from: rawMessages,
            config: compactionConfig,
            modelContextLimitTokens: modelLimit
        )
        let rawMiddleID = try #require(rawMiddle.first?.id)
        let rawAnyID = rawMiddleID
        let derived = HarnessConversationTestFixtures.makeDerivedStore(container: container)
        try derived.appendContextCompactionCheckpoint(
            conversationID: convID,
            rawMiddleMessageIDs: [rawMiddleID],
            compactedMiddleMessages: [Message(id: UUID(), role: .assistant, content: "compact", timestamp: Date(), toolCalls: [])],
            coveredRawMiddle: rawMiddle,
            kind: .summarized,
            config: compactionConfig,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        try derived.appendMemoryInjectionSnapshotCheckpoint(
            conversationID: convID,
            wire: MemoryInjectionSnapshotCheckpointWire(
                schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
                basedOnEventID: 0,
                injectionFingerprint: "mem-fp",
                snapshotJSON: "{\"a\":1}",
                scopeMessageIDs: [rawAnyID],
                createdAt: Date()
            ),
            expectedDerivedSequence: nil
        )
        try derived.appendToolResultTrimCheckpoint(
            conversationID: convID,
            wire: ToolResultTrimCheckpointWire(
                schemaVersion: ToolResultTrimCheckpointWire.currentSchemaVersion,
                basedOnEventID: 0,
                coveredMessageIDs: [rawAnyID],
                trimmedToolCallIds: ["tool-1"],
                configFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
                createdAt: Date()
            ),
            expectedDerivedSequence: nil
        )
        try derived.appendSystemPromptAssemblyCheckpoint(
            conversationID: convID,
            wire: SystemPromptAssemblyCheckpointWire(
                schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                basedOnEventID: 0,
                assemblyFingerprint: "sys-fp",
                replaySpecDigest: "replay-digest",
                createdAt: Date()
            ),
            expectedDerivedSequence: nil
        )

        let modelProvider = APILayerRESTStubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let kinds = [
                HarnessCheckpointWireKind.contextCompaction.rawValue,
                HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue,
                HarnessCheckpointWireKind.toolResultTrim.rawValue,
                HarnessCheckpointWireKind.systemPromptAssembly.rawValue,
            ]
            for kind in kinds {
                try await app.testing().test(.GET, "/api/conversations/\(convID.uuidString)/checkpoints/latest?kind=\(kind)") { res async throws in
                    #expect(res.status == .ok)
                    let body = Data(res.body.readableBytesView)
                    let payload = try JSONDecoder().decode(LatestCheckpointResponse.self, from: body)
                    #expect(payload.kind == kind)
                }
            }
        }
    }

    @Test("GET /api/conversations/:id/checkpoints/latest returns notFound for unknown kind")
    func conversationLatestCheckpointInvalidKind() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "checkpoint-invalid-kind")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations/\(convID.uuidString)/checkpoints/latest?kind=bad_kind") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id/checkpoints/latest returns 304 when If-None-Match matches")
    func conversationLatestCheckpointIfNoneMatch() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "checkpoint-etag")
        let convID = try #require(await runtimeSession.currentConversationID)
        let derived = HarnessConversationTestFixtures.makeDerivedStore(container: container)
        try derived.appendSystemPromptAssemblyCheckpoint(
            conversationID: convID,
            wire: SystemPromptAssemblyCheckpointWire(
                schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                basedOnEventID: 0,
                assemblyFingerprint: "etag-fp",
                replaySpecDigest: "replay-digest",
                createdAt: Date()
            ),
            expectedDerivedSequence: nil
        )

        let modelProvider = APILayerRESTStubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            var etag = ""
            let url = "/api/conversations/\(convID.uuidString)/checkpoints/latest?kind=\(HarnessCheckpointWireKind.systemPromptAssembly.rawValue)"
            try await app.testing().test(.GET, url) { res async throws in
                #expect(res.status == .ok)
                etag = res.headers.first(name: .eTag) ?? ""
                #expect(etag.isEmpty == false)
            }
            try await app.testing().test(.GET, url, beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("GET /api/conversations/:id?includeDerived=true returns conversation plus raw/derived arrays")
    func conversationGetIncludeDerivedSuccess() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "include-derived-test")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations/\(convID.uuidString)?includeDerived=true") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let conversation = json?["conversation"] as? [String: Any]
                #expect(conversation?["id"] as? String == convID.uuidString)
                #expect(json?["rawEvents"] is [[String: Any]])
                #expect(json?["derivedEvents"] is [[String: Any]])
            }
        }
    }

    @Test("POST /api/conversations/:id/projection returns projected messages and metadata")
    func conversationProjectionEndpointSuccess() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "projection-test")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.POST, "/api/conversations/\(convID.uuidString)/projection", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"config":{"options":{"debug":"rest"}}}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["projectedMessages"] is [[String: Any]])
                let metadata = json?["metadata"] as? [String: Any]
                #expect(metadata?["frontierEventID"] is NSNumber)
                #expect(metadata?["rawEventCount"] is NSNumber)
                #expect(metadata?["derivedEventCount"] is NSNumber)
            })
        }
    }

    @Test("GET /api/conversations/:id/server-metadata returns conversation server metadata (incl. context compaction gating)")
    func conversationGetServerMetadata() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "gating-test", topic: nil, description: nil)
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(
                .GET,
                "/api/conversations/\(convID.uuidString)/server-metadata"
            ) { res async throws in
                #expect(res.status == .ok)
                let data = Data(res.body.readableBytesView)
                let m = try JSONDecoder().decode(ConversationServerMetadata.self, from: data)
                let g = m.contextCompactionGating
                #expect(g.charactersPerToken > 0)
                #expect(g.proactiveThresholdTokens > 0)
                #expect(g.modelContextLimitTokens > 0)
                #expect(g.contextCompactionConfigEnabled == true)
                #expect(g.enableContextTransform == true)
            }
        }
    }

    @Test("GET /api/conversations/:id/slash-commands returns JSON autocomplete rows")
    func conversationSlashCommandsList() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "slash-api-test")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations/\(convID.uuidString)/slash-commands") { res async throws in
                #expect(res.status == .ok)
                let rows = try JSONDecoder().decode([SlashCommandAutocompleteEntry].self, from: Data(res.body.readableBytesView))
                #expect(rows.contains { $0.name == "/compact" })
            }
        }
    }

    @Test("POST /api/conversations/:id/checkpoints/invalidate is removed")
    func checkpointsInvalidateAliasRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
            )
            try await app.testing().test(.POST, "/api/conversations/\(UUID().uuidString)/checkpoints/invalidate") { response async throws in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id/events returns backfill shape")
    func conversationEventsBackfillRouteShape() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"events"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (json?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            try await app.testing().test(.GET, "/api/conversations/\(cid)/events?since=0") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["conversationID"] as? String == cid)
                #expect(json?["latestSeq"] as? Int != nil)
                #expect(json?["lagging"] as? Bool != nil)
                #expect(json?["events"] as? [String] != nil)
            }
        }
    }

    @Test("GET /api/conversations/:id/events returns 304 when If-None-Match matches ETag")
    func conversationEventsBackfillIfNoneMatchReturnsNotModified() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"events-etag"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (json?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            var etag = ""
            try await app.testing().test(.GET, "/api/conversations/\(cid)/events?since=0") { res async throws in
                #expect(res.status == .ok)
                etag = res.headers.first(name: .eTag) ?? ""
                #expect(etag.isEmpty == false)
            }

            try await app.testing().test(.GET, "/api/conversations/\(cid)/events?since=0", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

}
