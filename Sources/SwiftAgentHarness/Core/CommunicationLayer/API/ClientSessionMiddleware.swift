import Foundation
import Logging
import Vapor

private let clientSessionCookieName = "sah_client_session"
private let clientSessionHeaderName = "X-SAH-Client-Session"
private let authenticatedOwnerHeaderName = "X-SAH-Authenticated-Owner"

/// Assigns ``APISessionContext/connectionNamespace`` for each `/api` request so implicit REST routes resolve the correct selection.
///
/// Priority: ``X-SAH-Client-Session`` header → ``sah_client_session`` cookie → mint a new UUID (Set-Cookie on response).
///
/// Browsers therefore isolate tabs **after** the first response carries distinct cookies per browser profile; clients needing
/// deterministic isolation without cookies should send ``X-SAH-Client-Session`` on every request (see docs / openapi).
struct ClientSessionMiddleware: AsyncMiddleware {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let requestID = request.headers.first(name: "request-id")
            ?? request.headers.first(name: "x-request-id")
            ?? "unknown"
        logger.warning("ClientSessionMiddleware entered. method=\(request.method.rawValue) path=\(request.url.path) query=\(request.url.query ?? "") request-id=\(requestID)")
        let namespace: UUID
        if let raw = request.headers.first(name: clientSessionHeaderName)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = UUID(uuidString: raw) {
            namespace = parsed
        } else if let cookie = request.cookies[clientSessionCookieName],
                  let parsed = UUID(uuidString: cookie.string) {
            namespace = parsed
        } else {
            namespace = UUID()
        }

        let ownerUUID: UUID? = {
            guard let raw = request.headers.first(name: authenticatedOwnerHeaderName)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty
            else { return nil }
            return UUID(uuidString: raw)
        }()

        let response = try await APISessionContext.$connectionNamespace.withValue(namespace) {
            try await APISessionContext.$authenticatedOwnerAccountID.withValue(ownerUUID) {
                try await next.respond(to: request)
            }
        }

        let shouldAttachCookie =
            request.headers.first(name: clientSessionHeaderName) == nil
                && request.cookies[clientSessionCookieName] == nil

        if shouldAttachCookie {
            let copy = response
            copy.cookies[clientSessionCookieName] = HTTPCookies.Value(
                string: namespace.uuidString,
                expires: Date().addingTimeInterval(60 * 60 * 24 * 400),
                maxAge: nil,
                domain: nil,
                path: "/",
                isSecure: false,
                isHTTPOnly: true,
                sameSite: .lax
            )
            return copy
        }
        return response
    }
}
