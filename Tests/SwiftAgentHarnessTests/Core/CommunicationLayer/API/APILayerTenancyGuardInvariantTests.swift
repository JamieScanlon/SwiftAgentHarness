import Foundation
import Testing

@Suite("APILayer tenancy guard route inventory invariants (MT4)")
struct APILayerTenancyGuardInvariantTests {
    private static let repositoryRoot = RouteTenancyInventoryLoader.repositoryRoot()
    private static let inventory = try! RouteTenancyInventoryLoader.load(from: repositoryRoot)

    @Test("route tenancy inventory loads and is non-empty")
    func inventoryLoads() {
        #expect(!Self.inventory.routes.isEmpty)
    }

    @Test("every handler anchor resolves in its source file", arguments: Self.inventory.routes)
    func handlerAnchorResolves(entry: RouteTenancyInventoryEntry) throws {
        let source = try RouteTenancyInventoryLoader.sourceText(for: entry, repositoryRoot: Self.repositoryRoot)
        let region = RouteTenancyInventoryLoader.handlerRegion(in: source, anchor: entry.handlerAnchor)
        #expect(
            region != nil,
            "Missing handler region for \(entry.routeLabel) anchor=\(entry.handlerAnchor) file=\(entry.sourceFile)"
        )
    }

    @Test("every guarded route exercises a tenancy helper in its handler region", arguments: Self.guardedRoutes)
    func guardedRouteHasTenancyHelper(entry: RouteTenancyInventoryEntry) throws {
        let source = try RouteTenancyInventoryLoader.sourceText(for: entry, repositoryRoot: Self.repositoryRoot)
        guard let region = RouteTenancyInventoryLoader.handlerRegion(in: source, anchor: entry.handlerAnchor) else {
            Issue.record("Missing handler region for \(entry.routeLabel) anchor=\(entry.handlerAnchor)")
            return
        }
        let required = RouteTenancyInventoryLoader.requiredGuardSubstrings(for: entry.tenancyGuard)
        let satisfied = RouteTenancyInventoryLoader.regionContainsRequiredGuard(region, guardKind: entry.tenancyGuard)
        let preview = String(region.prefix(240))
        #expect(
            satisfied,
            """
            \(entry.routeLabel) expected guard=\(entry.tenancyGuard.rawValue) \
            (one of: \(required.joined(separator: ", "))) in anchor=\(entry.handlerAnchor). \
            Region head: \(preview)
            """
        )
    }

    @Test("exempt routes do not call tenancy helpers in their handler region", arguments: Self.exemptRoutes)
    func exemptRouteHasNoTenancyHelper(entry: RouteTenancyInventoryEntry) throws {
        let source = try RouteTenancyInventoryLoader.sourceText(for: entry, repositoryRoot: Self.repositoryRoot)
        guard let region = RouteTenancyInventoryLoader.handlerRegion(in: source, anchor: entry.handlerAnchor) else {
            Issue.record("Missing handler region for \(entry.routeLabel) anchor=\(entry.handlerAnchor)")
            return
        }
        let preview = String(region.prefix(240))
        #expect(
            !RouteTenancyInventoryLoader.regionContainsAnyTenancyHelper(region),
            """
            \(entry.routeLabel) is exempt (tenancy_guard=none) but handler region contains a tenancy helper. \
            Anchor=\(entry.handlerAnchor). Region head: \(preview)
            """
        )
    }

    private static var guardedRoutes: [RouteTenancyInventoryEntry] {
        inventory.routes.filter { $0.tenancyGuard != .none }
    }

    private static var exemptRoutes: [RouteTenancyInventoryEntry] {
        inventory.routes.filter { $0.tenancyGuard == .none }
    }
}
