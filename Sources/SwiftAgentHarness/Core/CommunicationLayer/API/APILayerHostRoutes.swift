import Foundation
import Logging
import Vapor

/// The caller of the `/api` request being served, for handlers a host adds with
/// ``APILayer/setHostRouteRegistrar(_:)``.
public enum APIRequestCaller {
    /// The owner account a valid `Authorization: Bearer` token on the request authenticates, or `nil` when the
    /// request carries no token or an invalid one.
    public static var authenticatedOwnerAccountID: UUID? {
        APISessionContext.authenticatedOwnerAccountID
    }
}

/// Mounts a host's routes under `/api`, refusing any that would answer requests a harness route answers.
struct HostRoutesBuilder: RoutesBuilder {
    let base: any RoutesBuilder
    /// Method and full path of every route registered before the host's.
    let harnessRoutes: [(method: HTTPMethod, path: [PathComponent])]
    let logger: Logger

    func add(_ route: Route) {
        let path = [PathComponent.constant("api")] + route.path
        if let harness = harnessRoutes.first(where: { $0.method == route.method && Self.overlaps($0.path, path) }) {
            logger.error(
                "Host route \(route.method.rawValue) /\(path.string) not registered: it would answer requests for \(harness.method.rawValue) /\(harness.path.string)"
            )
            return
        }
        base.add(route)
    }

    /// Whether some request path could match both. Errs toward overlap: constants compare case-insensitively, and a
    /// catch-all overlaps whatever follows.
    static func overlaps(_ lhs: [PathComponent], _ rhs: [PathComponent]) -> Bool {
        overlaps(lhs[...], rhs[...])
    }

    private static func overlaps(_ lhs: ArraySlice<PathComponent>, _ rhs: ArraySlice<PathComponent>) -> Bool {
        switch (lhs.first, rhs.first) {
        case (nil, nil), (.catchall?, _), (_, .catchall?):
            return true
        case (nil, _), (_, nil):
            return false
        case let (.constant(left)?, .constant(right)?):
            return left.lowercased() == right.lowercased() && overlaps(lhs.dropFirst(), rhs.dropFirst())
        default:
            return overlaps(lhs.dropFirst(), rhs.dropFirst())
        }
    }
}

/// Under strict tenancy, refuses any request to a host route that carries no authenticated owner. The harness
/// can't tell which host routes read and which write, so it holds them all to the mutation rule.
struct HostRouteTenancyMiddleware: AsyncMiddleware {
    let tenancyPolicy: TenancyPolicySettings

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if tenancyPolicy.requireAuthenticatedOwnerOnMutations, APISessionContext.authenticatedOwnerAccountID == nil {
            return APILayerTenancyResponses.unauthorizedMissingOwner()
        }
        return try await next.respond(to: request)
    }
}
