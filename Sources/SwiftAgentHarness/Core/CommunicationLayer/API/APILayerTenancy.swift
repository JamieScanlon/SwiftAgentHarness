import Foundation
import Vapor

/// When ``requireAuthenticatedOwnerOnMutations`` is true, REST/WS mutations require
/// ``APISessionContext/authenticatedOwnerAccountID`` (typically from ``X-SAH-Authenticated-Owner``)
/// and conversation rows must carry the same ``ModelConversation/ownerAccountID``.
struct TenancyPolicySettings: Sendable {
    var requireAuthenticatedOwnerOnMutations: Bool

    static let disabled = TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: false)
}

enum APILayerTenancyResponses {
    static let unauthorizedMissingOwnerJSON = #"{"type":"error","message":"Authenticated owner required (set X-SAH-Authenticated-Owner)"}"#
    static let forbiddenTenantJSON = #"{"type":"error","message":"Conversation not accessible for this owner"}"#

    static func unauthorizedMissingOwner() -> Response {
        Response(
            status: .unauthorized,
            headers: HTTPHeaders([("Content-Type", "application/json")]),
            body: .init(string: unauthorizedMissingOwnerJSON)
        )
    }

    static func forbiddenTenant() -> Response {
        Response(
            status: .forbidden,
            headers: HTTPHeaders([("Content-Type", "application/json")]),
            body: .init(string: forbiddenTenantJSON)
        )
    }
}

extension APILayerRouteDependencies {
    /// Returns a response when strict tenancy requires an authenticated owner but none is present.
    func tenancyEnsureAuthenticatedOwnerForMutation() -> Response? {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else { return nil }
        guard APISessionContext.authenticatedOwnerAccountID != nil else {
            return APILayerTenancyResponses.unauthorizedMissingOwner()
        }
        return nil
    }

    /// Loads the conversation and verifies ``ownerAccountID`` matches the authenticated owner (strict mode only).
    func tenancyEnsureConversationTenant(conversationID: UUID) async -> Response? {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else { return nil }
        guard let scope = APISessionContext.authenticatedOwnerAccountID else {
            return APILayerTenancyResponses.unauthorizedMissingOwner()
        }
        guard let conv = await conversation.apiGetConversation(id: conversationID) else {
            return Response(status: .notFound)
        }
        if conv.ownerAccountID != scope {
            return APILayerTenancyResponses.forbiddenTenant()
        }
        return nil
    }
}

extension APILayerWebSocketDependencies {
    func tenancyEnsureAuthenticatedOwnerForMutation() -> String? {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else { return nil }
        guard APISessionContext.authenticatedOwnerAccountID != nil else {
            return "Authenticated owner required (set X-SAH-Authenticated-Owner on WebSocket handshake)"
        }
        return nil
    }

    func tenancyEnsureConversationTenant(conversationID: UUID) async -> String? {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else { return nil }
        guard let scope = APISessionContext.authenticatedOwnerAccountID else {
            return "Authenticated owner required (set X-SAH-Authenticated-Owner on WebSocket handshake)"
        }
        guard let conv = await conversation.apiGetConversation(id: conversationID) else {
            return "Conversation not found"
        }
        if conv.ownerAccountID != scope {
            return "Conversation not accessible for this owner"
        }
        return nil
    }

    /// Strict tenancy guard for ``create_conversation`` / owner-only mutations where no target row exists yet.
    func tenancyFailureMessageIfCreateMutationForbidden() -> String? {
        tenancyEnsureAuthenticatedOwnerForMutation()
    }

    /// Owner header + persisted ``ModelConversation/ownerAccountID`` gate for conversation-scoped reads and writes.
    func tenancyFailureMessageIfConversationAccessForbidden(conversationID: UUID) async -> String? {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else { return nil }
        guard let scope = APISessionContext.authenticatedOwnerAccountID else {
            return "Authenticated owner required (set X-SAH-Authenticated-Owner on WebSocket handshake)"
        }
        guard let conv = await conversation.apiGetConversation(id: conversationID) else {
            return "Conversation not found"
        }
        if conv.ownerAccountID != scope {
            return "Conversation not accessible for this owner"
        }
        return nil
    }
}

extension APILayerRouteDependencies {
    /// Strict tenancy: authenticated owner header required for REST creates/copies when enabled.
    func tenancyRespondIfCreateMutationForbidden() -> Response? {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else { return nil }
        guard APISessionContext.authenticatedOwnerAccountID != nil else {
            return APILayerTenancyResponses.unauthorizedMissingOwner()
        }
        return nil
    }

    /// Strict tenancy: header + conversation owner row must match (404 when missing conversation).
    func tenancyRespondIfConversationAccessForbidden(conversationID: UUID) async -> Response? {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else { return nil }
        guard let scope = APISessionContext.authenticatedOwnerAccountID else {
            return APILayerTenancyResponses.unauthorizedMissingOwner()
        }
        guard let conv = await conversation.apiGetConversation(id: conversationID) else {
            return Response(status: .notFound)
        }
        if conv.ownerAccountID != scope {
            return APILayerTenancyResponses.forbiddenTenant()
        }
        return nil
    }
}
