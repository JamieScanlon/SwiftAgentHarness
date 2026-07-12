import Foundation
import NIOCore
import Vapor
import VaporTesting

struct EmbeddedLoopbackHTTPResponse: Sendable {
    var status: HTTPResponseStatus
    var headers: HTTPHeaders
    var body: ByteBuffer

    init(testingResponse: TestingHTTPResponse) {
        status = testingResponse.status
        headers = testingResponse.headers
        body = testingResponse.body
    }
}

public actor EmbeddedHarnessAPIClient: HarnessMutationTransporting {
    private let app: Application

    init(app: Application) {
        self.app = app
    }

    @discardableResult
    func send(
        method: HTTPMethod,
        path: String,
        session: EmbeddedHarnessAPISession,
        headers additionalHeaders: HTTPHeaders = [:],
        body: ByteBuffer? = nil
    ) async throws -> EmbeddedLoopbackHTTPResponse {
        let normalizedPath = Self.normalizeAPIPath(path)
        var captured: EmbeddedLoopbackHTTPResponse?
        try await app.testing().test(method, normalizedPath, beforeRequest: { req in
            var headers = additionalHeaders
            if let namespace = session.connectionNamespace {
                headers.replaceOrAdd(name: "X-SAH-Client-Session", value: namespace.uuidString)
            }
            if let authorization = session.authorizationHeader {
                headers.replaceOrAdd(name: .authorization, value: authorization)
            }
            req.headers = headers
            if let body {
                req.body = .init(buffer: body)
            }
        }, afterResponse: { response in
            captured = EmbeddedLoopbackHTTPResponse(testingResponse: response)
        })
        guard let captured else {
            throw HarnessMutationTransportError.invalidResponse
        }
        return captured
    }

    public func createConversation(
        session: EmbeddedHarnessAPISession,
        request: EmbeddedCreateConversationRequest
    ) async throws -> UUID {
        let payload: [String: Any?] = [
            "modelRef": request.modelRef,
            "userSystemPrompt": request.userSystemPrompt,
            "topic": request.topic,
            "description": request.description,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        var headers = HTTPHeaders()
        headers.contentType = .json
        let response = try await send(
            method: .POST,
            path: "/api/conversations",
            session: session,
            headers: headers,
            body: ByteBuffer(data: data)
        )
        guard response.status == .ok else {
            throw HarnessMutationTransportError.unexpectedStatus(response.status)
        }
        let body = Data(response.body.readableBytesView)
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let idString = json["conversationID"] as? String,
              let id = UUID(uuidString: idString)
        else {
            throw HarnessMutationTransportError.invalidResponse
        }
        return id
    }

    public func sendMessage(
        session: EmbeddedHarnessAPISession,
        conversationID: UUID,
        request: EmbeddedSendMessageRequest
    ) async throws -> EmbeddedSendMessageResult {
        var headers = HTTPHeaders()
        headers.contentType = .json
        var ifMatch = request.ifMatch
        if ifMatch == nil {
            ifMatch = try await EmbeddedHarnessAPIPreconditionSupport.messageTailIfMatch(
                client: self,
                session: session,
                conversationID: conversationID
            )
        }
        if let ifMatch {
            headers.replaceOrAdd(name: .ifMatch, value: ifMatch)
        }
        let effectiveInputTrust = request.inputTrust ?? MessageInputTrust.directUserEntry.rawValue
        let chatRequest = ChatRequest(
            conversationID: conversationID.uuidString,
            message: request.message,
            imageNames: request.imageNames,
            includeTools: request.includeTools,
            includeAgents: request.includeAgents,
            expectedPreviousTailHarnessMessageID: request.expectedPreviousTailHarnessMessageID,
            inputTrust: effectiveInputTrust,
            originSurface: request.originSurface ?? InteractiveSurfaceID.cli,
            originSenderID: request.originSenderID
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(chatRequest)
        let response = try await send(
            method: .POST,
            path: "/api/conversations/\(conversationID.uuidString)/messages",
            session: session,
            headers: headers,
            body: ByteBuffer(data: data)
        )
        guard response.status == .created || response.status == .ok else {
            throw HarnessMutationTransportError.unexpectedStatus(response.status)
        }
        let body = Data(response.body.readableBytesView)
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let runString = json["runId"] as? String ?? json["runID"] as? String,
              let messageString = json["messageId"] as? String ?? json["messageID"] as? String,
              let runID = UUID(uuidString: runString),
              let messageID = UUID(uuidString: messageString)
        else {
            throw HarnessMutationTransportError.invalidResponse
        }
        return EmbeddedSendMessageResult(runID: runID, messageID: messageID)
    }

    public func patchConversation(
        session: EmbeddedHarnessAPISession,
        conversationID: UUID,
        patch: ConversationPatch,
        ifMatch: String?
    ) async throws {
        let data = try JSONEncoder().encode(patch)
        var headers = HTTPHeaders()
        headers.contentType = .json
        var ifMatch = ifMatch
        if ifMatch == nil {
            ifMatch = try await EmbeddedHarnessAPIPreconditionSupport.conversationControlPlaneIfMatch(
                client: self,
                session: session,
                conversationID: conversationID
            )
        }
        if let ifMatch {
            headers.replaceOrAdd(name: .ifMatch, value: ifMatch)
        }
        let response = try await send(
            method: .PATCH,
            path: "/api/conversations/\(conversationID.uuidString)",
            session: session,
            headers: headers,
            body: ByteBuffer(data: data)
        )
        guard response.status == .ok else {
            throw HarnessMutationTransportError.unexpectedStatus(response.status)
        }
    }

    public func resolveExecApproval(
        session: EmbeddedHarnessAPISession,
        approvalID: String,
        approved: Bool,
        durable: Bool,
        reason: String?
    ) async throws {
        var payload: [String: Any] = [
            "approved": approved,
            "durable": durable,
        ]
        if let reason {
            payload["reason"] = reason
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        var headers = HTTPHeaders()
        headers.contentType = .json
        let response = try await send(
            method: .POST,
            path: "/api/exec-approvals/\(approvalID)",
            session: session,
            headers: headers,
            body: ByteBuffer(data: data)
        )
        guard response.status == .ok else {
            throw HarnessMutationTransportError.unexpectedStatus(response.status)
        }
    }

    public func cancelRun(
        session: EmbeddedHarnessAPISession,
        conversationID: UUID,
        runID: UUID,
        ifMatch: String?
    ) async throws {
        let payload = ["runId": runID.uuidString]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var headers = HTTPHeaders()
        headers.contentType = .json
        if let ifMatch {
            headers.replaceOrAdd(name: .ifMatch, value: ifMatch)
        }
        let response = try await send(
            method: .POST,
            path: "/api/conversations/\(conversationID.uuidString)/cancel",
            session: session,
            headers: headers,
            body: ByteBuffer(data: data)
        )
        guard response.status == .ok else {
            throw HarnessMutationTransportError.unexpectedStatus(response.status)
        }
    }

    private static func normalizeAPIPath(_ path: String) -> String {
        if path.hasPrefix("/api/") || path == "/api" {
            return path
        }
        if path.hasPrefix("/") {
            return "/api\(path)"
        }
        return "/api/\(path)"
    }

    func shutdown() async throws {
        try await app.asyncShutdown()
    }
}
