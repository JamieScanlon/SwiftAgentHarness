import Foundation
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("APILayer computer-use routes")
struct APILayerComputerUseRouteTests {
    private let conversationID = UUID()

    private func withRoutes(
        _ installation: ComputerUseInstallation?,
        _ body: (Application) async throws -> Void
    ) async throws {
        let conversation = ProtocolOnlyConversationGatewayStub(computerUse: installation.map(ComputerUseControlService.init))
        let api = APILayer(port: 0)
        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: ProtocolOnlyRuntimeGatewayStub(),
                modelProvider: APILayerRESTStubModelProvider(models: [APILayerRESTRouteTestSupport.makeTestModel()])
            )
            try await body(app)
        }
    }

    private func json(_ res: TestingHTTPResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any])
    }

    private var base: String { "/api/conversations/\(conversationID.uuidString)/computer-use" }

    @Test("GET …/computer-use lists pending requests and live sessions")
    func status() async throws {
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        try await ComputerUseFixtures.registerLiveSession(in: installation, parent: conversationID, lifecycleID: "call-1")
        let (request, asking) = try await ComputerUseFixtures.pendingQuestion(
            "Which file?", coordinator: try #require(installation.coordinator), conversationID: conversationID, lifecycleID: "call-1"
        )
        defer { asking.cancel() }

        try await withRoutes(installation) { app in
            try await app.testing().test(.GET, base) { res async throws in
                #expect(res.status == .ok)
                let body = try json(res)
                let pending = try #require(body["pending"] as? [[String: Any]])
                #expect(pending.first?["id"] as? String == request.id)
                #expect(pending.first?["kind"] as? String == "question")
                let sessions = try #require(body["sessions"] as? [[String: Any]])
                #expect(sessions.first?["lifecycleID"] as? String == "call-1")
                #expect(sessions.first?["takenOver"] as? Bool == false)
            }
        }
    }

    @Test("POST …/requests/{id} answers a question, and rejects bad bodies, unknown ids, and the wrong action")
    func answer() async throws {
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        let (request, asking) = try await ComputerUseFixtures.pendingQuestion(
            "Which file?", coordinator: try #require(installation.coordinator), conversationID: conversationID, lifecycleID: "call-1"
        )

        try await withRoutes(installation) { app in
            func post(_ path: String, _ body: String, expect status: HTTPStatus) async throws {
                try await app.testing().test(.POST, path, beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(string: body)
                }, afterResponse: { res async throws in
                    #expect(res.status == status, "\(path) \(body)")
                    if status != .ok { #expect(try json(res)["type"] as? String == "error") }
                })
            }
            try await post("\(base)/requests/\(request.id)", #"{"action":"answer"}"#, expect: .badRequest)
            try await post("\(base)/requests/\(request.id)", #"{"action":"shrug"}"#, expect: .badRequest)
            try await post("\(base)/requests/cu-q-unknown", #"{"action":"decline"}"#, expect: .notFound)
            try await post("\(base)/requests/\(request.id)", #"{"action":"hand-back"}"#, expect: .conflict)
            try await post("\(base)/requests/\(request.id)", #"{"action":"answer","answer":"The second"}"#, expect: .ok)
        }
        #expect(await asking.value == .answered("The second"))
    }

    @Test("POST …/requests/{id} hands a handoff back with a note")
    func handBack() async throws {
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        let coordinator = try #require(installation.coordinator)
        let handoff = Task { [conversationID] in
            await coordinator.handoff(
                conversationID: conversationID,
                lifecycleID: "call-1",
                target: "Fake host desktop",
                request: ComputerUseHandoffRequest(reason: .login, prompt: "Sign in", target: FakeDisplayTarget.hostManifest.id)
            )
        }
        var pending: [ComputerUsePendingRequest] = []
        for _ in 0..<500 where pending.isEmpty {
            await Task.yield()
            pending = await coordinator.pending(conversationID: conversationID)
        }
        let request = try #require(pending.first)

        try await withRoutes(installation) { app in
            try await app.testing().test(.POST, "\(base)/requests/\(request.id)", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"action":"hand-back","note":"signed in"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
        #expect(await handoff.value == .handedBack(note: "signed in"))
    }

    @Test("POST …/stop ends the conversation's sessions and reports which")
    func stop() async throws {
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        let (session, _) = try await ComputerUseFixtures.registerLiveSession(in: installation, parent: conversationID, lifecycleID: "call-1")

        try await withRoutes(installation) { app in
            try await app.testing().test(.POST, "\(base)/stop") { res async throws in
                #expect(res.status == .ok)
                #expect(try json(res)["lifecycleIDs"] as? [String] == ["call-1"])
            }
        }
        #expect(await session.terminalReason == .killSwitch)
    }

    @Test("POST …/takeover toggles takeover, and 404s when nothing is running")
    func takeover() async throws {
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        let (session, _) = try await ComputerUseFixtures.registerLiveSession(in: installation, parent: conversationID, lifecycleID: "call-1")

        try await withRoutes(installation) { app in
            try await app.testing().test(.POST, "\(base)/takeover", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"on":true}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try json(res)["lifecycleIDs"] as? [String] == ["call-1"])
            })
            try await app.testing().test(.POST, "\(base)/takeover", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"on":false,"lifecycleID":"call-missing"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
        #expect(await session.isTakeoverActive)
    }

    @Test("Routes 404 when the host has no computer use, and 400 on a bad conversation id")
    func unavailable() async throws {
        try await withRoutes(nil) { app in
            try await app.testing().test(.GET, base) { res async throws in
                #expect(res.status == .notFound)
                #expect(try json(res)["type"] as? String == "error")
            }
            try await app.testing().test(.POST, "\(base)/stop") { res async throws in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "/api/conversations/not-a-uuid/computer-use") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }
}
