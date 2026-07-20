import Foundation
import NIOCore
import Vapor

enum EmbeddedHarnessAPIPreconditionSupport {
    static func conversationControlPlaneIfMatch(
        client: EmbeddedHarnessAPIClient,
        session: EmbeddedHarnessAPISession,
        conversationID: UUID
    ) async throws -> String? {
        let response = try await client.send(
            method: .GET,
            path: "/api/conversations/\(conversationID.uuidString)",
            session: session
        )
        guard response.status == .ok else { return nil }
        return response.headers.first(name: .eTag)
    }

    static func conversationControlPlaneRevision(
        client: EmbeddedHarnessAPIClient,
        session: EmbeddedHarnessAPISession,
        conversationID: UUID
    ) async throws -> UInt64? {
        let response = try await client.send(
            method: .GET,
            path: "/api/conversations/\(conversationID.uuidString)",
            session: session
        )
        guard response.status == .ok else { return nil }
        let data = Data(response.body.readableBytesView)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = json["controlPlaneRevision"] as? UInt64
                ?? (json["controlPlaneRevision"] as? Int).map(UInt64.init)
        else {
            return nil
        }
        return revision
    }

    static func messageTailIfMatch(
        client: EmbeddedHarnessAPIClient,
        session: EmbeddedHarnessAPISession,
        conversationID: UUID
    ) async throws -> String? {
        let response = try await client.send(
            method: .GET,
            path: "/api/conversations/\(conversationID.uuidString)",
            session: session
        )
        guard response.status == .ok else { return nil }
        let data = Data(response.body.readableBytesView)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]],
              let last = messages.last,
              let idString = last["id"] as? String,
              let tailID = UUID(uuidString: idString)
        else {
            return response.headers.first(name: .eTag)
        }
        return APILayer.messageTailETag(lastMessageID: tailID)
    }
}
