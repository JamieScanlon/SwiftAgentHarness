import Foundation
import Logging

struct WebhookOutboundPayload: Codable, Sendable, Equatable {
    var triggerID: String
    var routeName: String
    var status: TriggerCompletionStatus
    var text: String
    var childSessionID: String
}

enum WebhookOutboundDelivery {
    static func post(
        urlString: String,
        payload: WebhookOutboundPayload,
        maxResponseBytes: Int = SessionGuardedHTTPClient.defaultMaxResponseBytes
    ) async throws -> Int {
        guard let url = URL(string: urlString) else {
            throw WebhookOutboundDeliveryError.invalidURL
        }
        let body = try JSONEncoder().encode(payload)
        let response = try SessionGuardedHTTPClient.post(url: url, body: body, maxResponseBytes: maxResponseBytes)
        return response.statusCode
    }

    static func postRawJSON(
        urlString: String,
        body: Data,
        maxResponseBytes: Int = SessionGuardedHTTPClient.defaultMaxResponseBytes
    ) async throws -> Int {
        guard let url = URL(string: urlString) else {
            throw WebhookOutboundDeliveryError.invalidURL
        }
        let response = try SessionGuardedHTTPClient.post(url: url, body: body, maxResponseBytes: maxResponseBytes)
        return response.statusCode
    }
}

enum WebhookOutboundDeliveryError: Error, Equatable {
    case invalidURL
    case blockedHost
    case invalidResponse
}
