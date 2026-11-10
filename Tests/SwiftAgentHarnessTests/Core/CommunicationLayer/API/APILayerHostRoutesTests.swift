import Foundation
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

private final class HostRouteModels: APILayerModelManaging, Sendable {
    func getAvailableModels() async -> [Model] { [] }
}

@Suite("API layer: routes a host adds under /api")
struct APILayerHostRoutesTests {
    private static let settings = APIAccessTokenAuthenticationSettings(hs256Secret: APIAccessTokenTestSecrets.primary)

    private static func api(
        tenancy: TenancyPolicySettings = .disabled,
        register: @escaping @Sendable (any RoutesBuilder) -> Void
    ) async -> APILayer {
        let api = APILayer(port: 0)
        await api.setModelProvider(HostRouteModels())
        await api.setChatGatewayServices(APILayerChatGatewayServices(
            conversation: ProtocolOnlyConversationGatewayStub(),
            runtime: ProtocolOnlyRuntimeGatewayStub()
        ))
        await api.setTenancyPolicySettings(tenancy)
        await api.setAPIAccessTokenAuthenticationSettings(settings)
        await api.setHostRouteRegistrar(register)
        return api
    }

    private static func pushDevices(_ api: any RoutesBuilder) {
        api.grouped("push").post("devices") { _ async -> Response in
            Response(status: .noContent)
        }
    }

    private static func configure(_ api: APILayer, on app: Application) async {
        await api.configureRoutesForTesting(
            app: app,
            conversation: ProtocolOnlyConversationGatewayStub(),
            runtime: ProtocolOnlyRuntimeGatewayStub(),
            modelProvider: HostRouteModels()
        )
    }

    @Test("A host route is served under /api behind the client session middleware")
    func served() async throws {
        let api = await Self.api(register: Self.pushDevices)
        try await withApp { app in
            await Self.configure(api, on: app)
            try await app.testing().test(.POST, "/api/push/devices") { res async in
                #expect(res.status == .noContent)
                #expect(res.headers.setCookie?["sah_client_session"] != nil)
            }
        }
    }

    @Test("With no host registrar, the route doesn't exist")
    func absentWithoutRegistrar() async throws {
        let api = await Self.api(register: { _ in })
        await api.setHostRouteRegistrar(nil)
        try await withApp { app in
            await Self.configure(api, on: app)
            try await app.testing().test(.POST, "/api/push/devices") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Under strict tenancy a host route needs an authenticated owner, and its handler sees who that is")
    func strictTenancy() async throws {
        let owner = UUID()
        let api = await Self.api(tenancy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)) { api in
            api.get("push", "owner") { _ async -> String in
                APIRequestCaller.authenticatedOwnerAccountID?.uuidString ?? "none"
            }
        }
        let token = try await HarnessAPIAccessTokenFactory.mint(ownerAccountID: owner, settings: Self.settings)
        try await withApp { app in
            await Self.configure(api, on: app)
            try await app.testing().test(.GET, "/api/push/owner") { res async in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(.GET, "/api/push/owner", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == owner.uuidString)
            }
        }
    }

    @Test("Without strict tenancy a host route is open, and the caller is unknown without a token")
    func openTenancy() async throws {
        let api = await Self.api { api in
            api.get("push", "owner") { _ async -> String in
                APIRequestCaller.authenticatedOwnerAccountID?.uuidString ?? "none"
            }
        }
        try await withApp { app in
            await Self.configure(api, on: app)
            try await app.testing().test(.GET, "/api/push/owner") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "none")
            }
        }
    }

    @Test("A host route that would answer a harness route's requests isn't registered")
    func noShadowing() async throws {
        let api = await Self.api { api in
            api.post("approvals", "grant-1") { _ async -> String in "host" }
            api.post("approvals", ":other") { _ async -> String in "host" }
            api.get("approvals", "grant-1") { _ async -> String in "host-get" }
            Self.pushDevices(api)
        }
        try await withApp { app in
            await Self.configure(api, on: app)
            try await app.testing().test(.POST, "/api/approvals/grant-1", beforeRequest: { req in
                try req.content.encode(["decision": "allowOnce"])
            }) { res async in
                #expect(res.body.string != "host")
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "/api/approvals/grant-1") { res async in
                #expect(res.body.string == "host-get")
            }
            try await app.testing().test(.POST, "/api/push/devices") { res async in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("Paths overlap when every segment could match the same request")
    func overlap() {
        func path(_ raw: String) -> [PathComponent] { raw.pathComponents }
        #expect(HostRoutesBuilder.overlaps(path("api/approvals/:id"), path("api/approvals/grant-1")))
        #expect(HostRoutesBuilder.overlaps(path("api/approvals/:id"), path("api/approvals/:other")))
        #expect(HostRoutesBuilder.overlaps(path("api/Approvals/x"), path("api/approvals/x")))
        #expect(HostRoutesBuilder.overlaps(path("api/files/**"), path("api/files/a/b")))
        #expect(HostRoutesBuilder.overlaps(path("api/*/devices"), path("api/push/devices")))
        #expect(!HostRoutesBuilder.overlaps(path("api/approvals/:id"), path("api/push/devices")))
        #expect(!HostRoutesBuilder.overlaps(path("api/approvals/:id"), path("api/approvals/:id/extra")))
        #expect(!HostRoutesBuilder.overlaps(path("api/approvals"), path("api/approvals/:id")))
    }

    @Test("The embedded application serves host routes too")
    func embedded() async throws {
        let api = await Self.api(register: Self.pushDevices)
        let app = try await api.makeEmbeddedApplication()
        do {
            try await app.testing().test(.POST, "/api/push/devices") { res async in
                #expect(res.status == .noContent)
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
        await api.stop()
    }
}
