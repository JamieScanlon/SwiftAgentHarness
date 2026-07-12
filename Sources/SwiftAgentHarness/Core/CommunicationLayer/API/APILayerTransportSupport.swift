import CryptoKit
import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import Vapor

/// Canonical REST failure envelope: `{"type":"error","message":"..."}` (`ErrorEnvelope` in OpenAPI).
enum APILayerRESTErrorResponse {
    private struct Body: Encodable {
        var type: String = "error"
        var message: String
    }

    static func error(status: HTTPStatus, message: String) -> Response {
        let data = (try? JSONEncoder().encode(Body(message: message))) ?? Data()
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    static func invalidConversationID() -> Response {
        error(status: .badRequest, message: "Invalid conversation ID")
    }
}

protocol APILayerRESTConflictRepresenting: Error {
    var apiLayerRESTConflictBody: Data? { get }
}

// MARK: - Streaming transport (Phase 4 seam)
// Entry points call ``APILayerChatRuntimeManaging`` for streams; delivery uses ``APILayerConversationManaging``
// for message snapshots (`apiListMessagesThrowing`, explicit ``conversationID`` routing).

extension APILayer {
    struct HTTPPreconditionFailureBody: Codable, Sendable, Equatable {
        var error: String
        var currentVersion: String
        var yourVersion: String?
        var resourceUrl: String
    }

    struct HTTPPreconditionRequiredBody: Codable, Sendable, Equatable {
        var error: String
        var resourceUrl: String
    }

    static func conversationETag(revision: UInt64) -> String {
        "\"conv-v\(revision)\""
    }

    static func messageTailETag(lastMessageID: UUID?) -> String {
        "\"msg-\(lastMessageID?.uuidString.lowercased() ?? "none")\""
    }

    static func checkpointETag(kind: String, lastCheckpointID: Int?) -> String {
        "\"ckpt-\(kind)-\(lastCheckpointID.map(String.init) ?? "none")\""
    }

    static func runETag(runID: UUID?) -> String {
        "\"run-\(runID?.uuidString.lowercased() ?? "none")\""
    }

    static func registryETag(payloadData: Data) -> String {
        let digest = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        return "\"reg-\(digest)\""
    }

    static func searchETag(payloadData: Data) -> String {
        let digest = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        return "\"search-\(digest)\""
    }

    static func modelQueryETag(payloadData: Data) -> String {
        let digest = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        return "\"model-query-\(digest)\""
    }

    static func conversationEventsBackfillETag(conversationID: UUID, latestSeq: Int, since: Int?) -> String {
        "\"conv-events-\(conversationID.uuidString.lowercased())-\(since ?? -1)-\(latestSeq)\""
    }

    static func ifMatchHeader(from headers: HTTPHeaders) -> String? {
        firstETagToken(headers.first(name: .ifMatch))
    }

    static func ifNoneMatchHeader(from headers: HTTPHeaders) -> String? {
        firstETagToken(headers.first(name: .ifNoneMatch))
    }

    static func parseConversationRevisionIfMatch(_ headerValue: String?) -> UInt64? {
        guard let normalized = normalizedETagToken(headerValue),
              normalized.hasPrefix("conv-v")
        else { return nil }
        return UInt64(normalized.dropFirst("conv-v".count))
    }

    static func parseMessageTailIfMatch(_ headerValue: String?) -> UUID? {
        guard let normalized = normalizedETagToken(headerValue),
              normalized.hasPrefix("msg-")
        else { return nil }
        return UUID(uuidString: String(normalized.dropFirst("msg-".count)))
    }

    static func parseCheckpointIfMatch(_ headerValue: String?) -> (kind: String, eventID: Int?)? {
        guard let normalized = normalizedETagToken(headerValue),
              normalized.hasPrefix("ckpt-")
        else { return nil }
        let parts = normalized.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let kind = String(parts[1])
        let eventIDPart = String(parts[2])
        let eventID: Int? = eventIDPart == "none" ? nil : Int(eventIDPart)
        return (kind: kind, eventID: eventID)
    }

    static func ifNoneMatchSatisfied(currentETag: String, headerValue: String?) -> Bool {
        guard let headerValue else { return false }
        let rawTokens = headerValue.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let current = normalizedETagToken(currentETag)
        return rawTokens.contains { token in
            if token == "*" { return true }
            return normalizedETagToken(token) == current
        }
    }

    static func ifMatchSatisfied(currentETag: String, headerValue: String?) -> Bool {
        guard let headerValue else { return false }
        let rawTokens = headerValue.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let current = normalizedETagToken(currentETag)
        return rawTokens.contains { token in
            if token == "*" { return true }
            return normalizedETagToken(token) == current
        }
    }

    static func preconditionFailedResponse(
        currentETag: String,
        yourVersion: String?,
        resourceUrl: String
    ) -> Response {
        let body = HTTPPreconditionFailureBody(
            error: "precondition_failed",
            currentVersion: normalizedETagToken(currentETag) ?? currentETag,
            yourVersion: normalizedETagToken(yourVersion ?? ""),
            resourceUrl: resourceUrl
        )
        do {
            let data = try JSONEncoder().encode(body)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            headers.replaceOrAdd(name: .eTag, value: currentETag)
            return Response(status: .preconditionFailed, headers: headers, body: .init(data: data))
        } catch {
            return Response(status: .internalServerError)
        }
    }

    static func preconditionRequiredResponse(resourceUrl: String, currentETag: String?) -> Response {
        let body = HTTPPreconditionRequiredBody(
            error: "precondition_required",
            resourceUrl: resourceUrl
        )
        do {
            let data = try JSONEncoder().encode(body)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            if let currentETag {
                headers.replaceOrAdd(name: .eTag, value: currentETag)
            }
            return Response(status: .preconditionRequired, headers: headers, body: .init(data: data))
        } catch {
            return Response(status: .internalServerError)
        }
    }

    static func notModifiedResponse(etag: String) -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .eTag, value: etag)
        return Response(status: .notModified, headers: headers)
    }

    static func addETag(_ etag: String, to headers: inout HTTPHeaders) {
        headers.replaceOrAdd(name: .eTag, value: etag)
    }

    private static func firstETagToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    private static func normalizedETagToken(_ token: String?) -> String? {
        guard let token else { return nil }
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("W/") {
            value.removeFirst(2)
        }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }

    static func harnessErrorPayload(message: String, code: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "kind": "error",
            "message": message,
        ]
        if let code, !code.isEmpty {
            payload["code"] = code
        }
        return payload
    }

    static func harnessDedupeResultPayload(firstSighting: Bool) -> [String: Any] {
        [
            "kind": "dedupe_result",
            "firstSighting": firstSighting,
        ]
    }

    static func acquireChatStream(
        message: String,
        images: [Message.Image],
        chatRuntime: APILayerChatRuntimeManaging,
        conversationID: UUID,
        configuration: AgentRuntimeTurnConfiguration = .init()
    ) async throws -> ChatStreamResponse {
        try await chatRuntime.apiSendMessageAndStreamResponse(
            conversationID: conversationID,
            message,
            images: images,
            enableTools: configuration.enableTools,
            enableAgents: configuration.enableAgents,
            expectedPreviousTailHarnessMessageID: configuration.expectedPreviousTailHarnessMessageID,
            inputTrustRaw: configuration.inputTrustRaw,
            resolvedInputTrustClass: configuration.resolvedInputTrustClass,
            systemReminder: configuration.ephemeralSystemReminder,
            originSurface: configuration.originSurface,
            originSenderID: configuration.originSenderID
        )
    }

    static func restConflictResponse(for error: Error) -> Response? {
        guard let representable = error as? any APILayerRESTConflictRepresenting,
              let data = representable.apiLayerRESTConflictBody else {
            return nil
        }
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: .conflict, headers: headers, body: .init(data: data))
    }

    /// Chunked **200** stream of assistant text after successful stream acquisition.
    static func streamingChatResponse(
        stream: ChatStreamResponse
    ) async throws -> Response {
        let response = Response(status: .ok)

        response.body = .init(stream: { writer in
            Task {
                for await partial in stream.partialContent {
                    guard let utf8 = partial.chunkedTransferUTF8, !utf8.isEmpty else { continue }
                    let data = utf8.data(using: .utf8)!
                    let buffer = ByteBuffer(data: data)
                    _ = writer.write(.buffer(buffer))
                }
                _ = writer.write(.end)
            }
        })

        return response
    }
}
