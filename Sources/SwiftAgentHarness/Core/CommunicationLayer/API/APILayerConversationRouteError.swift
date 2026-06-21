//
//  HTTP façade–safe errors for conversation routes.
//

import Foundation

protocol APILayerConversationRouteErrorRepresenting: Error {
    var apiLayerConversationRouteError: APILayerConversationRouteError? { get }
}

/// Errors the REST gateway maps to status codes without depending on ``HarnessRuntimeSession`` / ``ConversationServiceError``.
enum APILayerConversationRouteError: Error, Sendable, Equatable {
    /// No conversation exists for the requested id (or it is not visible to this session).
    case conversationNotFound
    /// Revert/branch anchor is invalid for the current conversation timeline.
    case invalidRevertTarget
    /// Cancel was requested for a run that is no longer active.
    case cancelRunNotActive
}

extension APILayerConversationRouteError {
    /// Whether `error` represents a missing conversation for HTTP/tool mapping.
    /// Accepts API-scoped errors and any error that exposes a mapped conversation route error.
    static func representsConversationNotFound(_ error: Error) -> Bool {
        represents(error, routeError: .conversationNotFound)
    }

    static func representsInvalidRevertTarget(_ error: Error) -> Bool {
        represents(error, routeError: .invalidRevertTarget)
    }

    static func representsCancelRunNotActive(_ error: Error) -> Bool {
        represents(error, routeError: .cancelRunNotActive)
    }

    private static func represents(_ error: Error, routeError: APILayerConversationRouteError) -> Bool {
        if let r = error as? APILayerConversationRouteError, r == routeError {
            return true
        }
        if let mapped = error as? any APILayerConversationRouteErrorRepresenting,
           mapped.apiLayerConversationRouteError == routeError {
            return true
        }
        return false
    }
}
