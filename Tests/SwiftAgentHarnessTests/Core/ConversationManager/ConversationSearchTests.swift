import Foundation
import SwiftAgentKit
import SwiftData
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

private enum ConversationSearchTestSupport {
    static func makeModel() -> Model {
        HarnessConversationTestFixtures.makeTestModel(name: "search-test-model")
    }

    static func makeLocalStack(label: String) throws -> (stack: ConversationPersistenceStack, root: URL) {
        let (stack, _, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: label)
        return (stack, root)
    }
}

@Suite("ConversationManager cross-conversation search")
struct ConversationSearchTests {

    @Test("fulltext finds persisted message and returns excerpt")
    func fulltextHit() async throws {
        let (stack, root) = try ConversationSearchTestSupport.makeLocalStack(label: "search-fulltext")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConversationSearchTestSupport.makeModel()
        let needle = "uniqueAlphaBravoToken918273"
        let ids = try await HarnessConversationTestFixtures.seedSearchableConversation(
            stack: stack,
            model: model,
            userContent: "prefix \(needle) suffix"
        )

        let req = ConversationSearchRequest(query: needle, kind: .fulltext, limit: 10, offset: 0)
        let res = stack.conversationManager.searchConversations(request: req)

        #expect(res.totalHitCount == 1)
        #expect(res.hits.count == 1)
        #expect(res.hits[0].conversationID == ids.conversationID)
        #expect(res.hits[0].messageID == ids.messageID)
        #expect(res.hits[0].excerpt.contains(needle))
        #expect(res.hits[0].conversationTopic == "Topic")
        #expect(res.warning == nil)
    }

    @Test("semantic kind returns warning and empty hits")
    func semanticNotImplemented() throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let manager = ConversationManager(container: container)
        let res = manager.searchConversations(
            request: ConversationSearchRequest(query: "hello", kind: .semantic, limit: 10, offset: 0)
        )
        #expect(res.hits.isEmpty)
        #expect(res.totalHitCount == 0)
        #expect(res.warning != nil)
    }

    @Test("AND of whitespace-separated terms")
    func multiTermAnd() async throws {
        let (stack, root) = try ConversationSearchTestSupport.makeLocalStack(label: "search-and")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConversationSearchTestSupport.makeModel()
        _ = try await HarnessConversationTestFixtures.seedSearchableConversation(
            stack: stack,
            model: model,
            userContent: "onlyFirstTermHere"
        )
        let expected = try await HarnessConversationTestFixtures.seedSearchableConversation(
            stack: stack,
            model: model,
            userContent: "onlyFirstTermHere secondTermMatch"
        )

        let res = stack.conversationManager.searchConversations(
            request: ConversationSearchRequest(query: "onlyFirstTermHere secondTermMatch", kind: .fulltext, limit: 10, offset: 0)
        )
        #expect(res.totalHitCount == 1)
        #expect(res.hits.first?.conversationID == expected.conversationID)
    }

    @Test("deleted conversations excluded unless includeDeleted")
    func deletedLifecycleFilter() async throws {
        let (stack, root) = try ConversationSearchTestSupport.makeLocalStack(label: "search-deleted")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConversationSearchTestSupport.makeModel()
        let token = "deletedLifecycleToken4477"
        _ = try await HarnessConversationTestFixtures.seedSearchableConversation(
            stack: stack,
            model: model,
            userContent: token,
            lifecycle: .deleted
        )

        let excluded = stack.conversationManager.searchConversations(
            request: ConversationSearchRequest(query: token, kind: .fulltext, limit: 10, offset: 0, includeDeleted: false)
        )
        #expect(excluded.totalHitCount == 0)

        let included = stack.conversationManager.searchConversations(
            request: ConversationSearchRequest(query: token, kind: .fulltext, limit: 10, offset: 0, includeDeleted: true)
        )
        #expect(included.totalHitCount == 1)
    }

    @Test("owner query filters by ownerAccountID")
    func ownerFilter() async throws {
        let (stack, root) = try ConversationSearchTestSupport.makeLocalStack(label: "search-owner")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConversationSearchTestSupport.makeModel()
        let owner = UUID()
        let token = "ownerScopedToken5566"
        _ = try await HarnessConversationTestFixtures.seedSearchableConversation(
            stack: stack,
            model: model,
            userContent: token,
            ownerAccountID: owner
        )

        let miss = stack.conversationManager.searchConversations(
            request: ConversationSearchRequest(query: token, kind: .fulltext, limit: 10, offset: 0, ownerAccountID: UUID())
        )
        #expect(miss.totalHitCount == 0)

        let hit = stack.conversationManager.searchConversations(
            request: ConversationSearchRequest(query: token, kind: .fulltext, limit: 10, offset: 0, ownerAccountID: owner)
        )
        #expect(hit.totalHitCount == 1)
    }
}

private final class SearchRESTModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]
    init(models: [Model]) { self.models = models }
    func getAvailableModels() async -> [Model] { models }
}

@Suite("GET /api/search", .serialized)
struct ConversationSearchRESTTests {

    @Test("returns 400 when q is missing")
    func badRequestWithoutQuery() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ConversationSearchTestSupport.makeModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: SearchRESTModelProvider(models: [model]))
            try await app.testing().test(.GET, "/api/search") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("returns JSON envelope when q present")
    func okWithQuery() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: SearchRESTModelProvider(models: []))
            try await app.testing().test(.GET, "/api/search?q=hello") { res async throws in
                #expect(res.status == .ok)
                let decoded = try JSONDecoder().decode(ConversationSearchResponse.self, from: Data(res.body.readableBytesView))
                #expect(decoded.hits.isEmpty)
                #expect(decoded.totalHitCount == 0)
            }
        }
    }

    @Test("strict tenancy auto-scopes search hits to bearer owner")
    func strictTenancySearchAutoScopesToBearerOwner() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "search-strict-tenant")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = ConversationSearchTestSupport.makeModel()
        let ownerA = UUID()
        let ownerB = UUID()
        let tokenA = "strictSearchOwnerAToken918273"
        let tokenB = "strictSearchOwnerBToken918273"
        _ = try await HarnessConversationTestFixtures.seedSearchableConversation(
            stack: fixture.stack,
            model: model,
            userContent: tokenA,
            ownerAccountID: ownerA
        )
        _ = try await HarnessConversationTestFixtures.seedSearchableConversation(
            stack: fixture.stack,
            model: model,
            userContent: tokenB,
            ownerAccountID: ownerB
        )

        let api = APILayer(port: 0)
        await api.setTenancyPolicySettings(TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true))
        await api.setAPIAccessTokenAuthenticationSettings(
            APIAccessTokenAuthenticationSettings(hs256Secret: "search-strict-tenant-secret")
        )
        let authA = try await HarnessAPIAccessTokenFactory.authorizationHeaderValue(
            ownerAccountID: ownerA,
            settings: APIAccessTokenAuthenticationSettings(hs256Secret: "search-strict-tenant-secret")
        )

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                runtimeSession: fixture.host,
                modelProvider: SearchRESTModelProvider(models: [model])
            )

            try await app.testing().test(
                .GET,
                "/api/search?q=\(tokenA)",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .authorization, value: authA)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let decoded = try JSONDecoder().decode(ConversationSearchResponse.self, from: Data(res.body.readableBytesView))
                    #expect(decoded.totalHitCount == 1)
                }
            )

            try await app.testing().test(
                .GET,
                "/api/search?q=\(tokenB)",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .authorization, value: authA)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let decoded = try JSONDecoder().decode(ConversationSearchResponse.self, from: Data(res.body.readableBytesView))
                    #expect(decoded.totalHitCount == 0)
                }
            )

            try await app.testing().test(
                .GET,
                "/api/search?q=\(tokenA)&owner=\(ownerB.uuidString)",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .authorization, value: authA)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .forbidden)
                }
            )

            try await app.testing().test(.GET, "/api/search?q=\(tokenA)") { res async throws in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
