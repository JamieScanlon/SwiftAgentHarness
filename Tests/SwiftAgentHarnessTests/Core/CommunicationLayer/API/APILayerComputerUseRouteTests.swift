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

    @Test("GET …/images/{blobID} serves an image a live run of this conversation stored, and nothing else")
    func runImages() async throws {
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        let child = UUID()
        try await ComputerUseFixtures.registerLiveSession(in: installation, parent: conversationID, lifecycleID: "call-1", childID: child)
        let held = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        _ = await installation.blobs.hold([held], childConversationID: child, until: Date().addingTimeInterval(600))
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        installation.readBlob = { _ in png }

        try await withRoutes(installation) { app in
            try await app.testing().test(.GET, "\(base)/images/\(held)") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.serialize() == "image/png")
                #expect(res.headers.first(name: .cacheControl) == "no-store")
                #expect(Data(res.body.readableBytesView) == png)
            }
            try await app.testing().test(.GET, "\(base)/images/\(other)") { res async throws in
                #expect(res.status == .notFound, "a blob no live run of this conversation stored")
            }
            try await app.testing().test(.GET, "/api/conversations/\(UUID().uuidString)/computer-use/images/\(held)") { res async throws in
                #expect(res.status == .notFound, "another conversation's run")
            }
        }
    }

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

    @Test("Replays list newest first, open as a document, and serve only their own thumbnails")
    func replays() async throws {
        let installation = ComputerUseInstallation()
        let store = ReplayBlobStore()
        let png = try ComputerUseFixtures.pngScreenshot(width: 32, height: 20)
        var replay = ComputerUseReplay.fixture(parent: conversationID, lifecycleID: "call-1", endedAt: Date(timeIntervalSince1970: 1_800_000_000))
        replay.thumbnails = [ComputerUseReplayThumbnail(
            observationID: "o_1", at: replay.startedAt, app: "com.apple.TextEdit", width: 32, height: 20, mediaType: "image/png", blobID: store.put(png)
        )]
        await installation.replays.record(.fixture(replay, store: store))

        try await withRoutes(installation) { app in
            try await app.testing().test(.GET, "\(base)/replays") { res async throws in
                #expect(res.status == .ok)
                let rows = try #require(try json(res)["replays"] as? [[String: Any]])
                #expect(rows.map { $0["lifecycleID"] as? String } == ["call-1"])
                #expect(rows.first?["thumbnailCount"] as? Int == 1)
                #expect(rows.first?["endedAt"] as? String == "2027-01-15T08:00:00Z")
            }
            try await app.testing().test(.GET, "\(base)/replays/call-1") { res async throws in
                #expect(res.status == .ok)
                let body = try json(res)
                #expect(body["target"] as? String == "Fake VM")
                let thumbnails = try #require(body["thumbnails"] as? [[String: Any]])
                #expect(thumbnails.first?["observationID"] as? String == "o_1")
            }
            try await app.testing().test(.GET, "\(base)/replays/call-1/thumbnails/o_1") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.serialize() == "image/png")
                #expect(Data(res.body.readableBytesView) == png)
            }
            try await app.testing().test(.GET, "\(base)/replays/call-1/thumbnails/o_9") { res async throws in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "\(base)/replays/call-9") { res async throws in
                #expect(res.status == .notFound)
                #expect(try json(res)["type"] as? String == "error")
            }
        }
    }

    @Test("POST …/runs/{lifecycleID}/audit marks a live or released run, and 404s for an unknown one")
    func audit() async throws {
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        try await ComputerUseFixtures.registerLiveSession(in: installation, parent: conversationID, lifecycleID: "call-live")
        let store = ReplayBlobStore()
        var entry = ComputerUseReplayIndexEntry.fixture(.fixture(parent: conversationID, lifecycleID: "call-done", endedAt: Date()), store: store)
        entry.expiresAt = Date().addingTimeInterval(3_600)
        await installation.replays.record(entry)

        try await withRoutes(installation) { app in
            func post(_ lifecycleID: String, _ body: String, _ check: @escaping (TestingHTTPResponse) throws -> Void) async throws {
                try await app.testing().test(.POST, "\(base)/runs/\(lifecycleID)/audit", beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(string: body)
                }, afterResponse: { res async throws in try check(res) })
            }
            try await post("call-live", #"{"marked":true}"#) { res in
                #expect(res.status == .ok)
                let body = try json(res)
                #expect(body["auditMarked"] as? Bool == true)
                #expect(body["released"] as? Bool == false)
            }
            try await post("call-done", #"{"marked":true}"#) { res in
                #expect(res.status == .ok)
                let body = try json(res)
                #expect(body["released"] as? Bool == true)
                #expect(body["expiresAt"] is String, "the default audit retention is a fixed length")
            }
            try await post("call-nope", #"{"marked":true}"#) { res in #expect(res.status == .notFound) }
            try await post("call-done", #"{"mark":1}"#) { res in #expect(res.status == .badRequest) }
        }
        #expect(await installation.blobs.takeAuditMark(parent: conversationID, lifecycleID: "call-live"))
        let held = try #require(store.expiries["doc"] ?? nil)
        #expect(held.timeIntervalSince(entry.releasedAt) > 29 * 86_400)
    }

    @Test("POST …/runs/{lifecycleID}/live-view mints a user or observer link, DELETE …/observers ends observers, and both 404 without a run")
    func liveView() async throws {
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        let (_, target) = try await ComputerUseFixtures.registerLiveSession(in: installation, parent: conversationID, lifecycleID: "call-1")
        try await ComputerUseFixtures.registerLiveSession(in: installation, parent: conversationID, lifecycleID: "call-blind")
        await target.setLiveViewLink(DisplayLiveView(url: "http://127.0.0.1:9/view#secret", viewOnly: true, expiresAt: Date(timeIntervalSince1970: 1_800_000_000)))

        try await withRoutes(installation) { app in
            try await app.testing().test(.POST, "\(base)/runs/call-1/live-view") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == "no-store")
                let body = try json(res)
                #expect(body["url"] as? String == "http://127.0.0.1:9/view#secret")
                #expect(body["viewOnly"] as? Bool == true)
                #expect(body["expiresAt"] as? String == "2027-01-15T08:00:00Z")
                #expect(body["role"] as? String == "user")
            }
            try await app.testing().test(.POST, "\(base)/runs/call-1/live-view", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"role":"observer"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try json(res)["role"] as? String == "observer")
            })
            try await app.testing().test(.POST, "\(base)/runs/call-1/live-view", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"role":"admin"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
            #expect(await target.liveViewRoles == [.user, .observer])
            try await app.testing().test(.DELETE, "\(base)/runs/call-1/live-view/observers") { res async throws in
                #expect(res.status == .noContent)
            }
            #expect(await target.observerEnds == 1)
            try await app.testing().test(.DELETE, "\(base)/runs/call-nope/live-view/observers") { res async throws in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.POST, "\(base)/runs/call-blind/live-view") { res async throws in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.POST, "\(base)/runs/call-nope/live-view") { res async throws in
                #expect(res.status == .notFound)
            }
        }
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
