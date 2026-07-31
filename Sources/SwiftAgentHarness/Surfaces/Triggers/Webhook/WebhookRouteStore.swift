import Foundation

/// One place that decides what a route name *is*.
///
/// Names were normalized on write but not on read, so `subscribe(name: "GitHub-Push")` stored
/// `github-push` and every subsequent lookup with the name the caller just used returned not-found.
enum WebhookRouteNaming {
    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct WebhookRouteStore: Sendable {
    private let staticRoutes: [WebhookRoute]
    private let dynamicStore: WebhookDynamicRouteStore

    public init(staticRoutes: [WebhookRoute] = [], dynamicStore: WebhookDynamicRouteStore) {
        self.staticRoutes = staticRoutes
        self.dynamicStore = dynamicStore
    }

    public func route(named name: String) throws -> WebhookRoute? {
        let normalized = WebhookRouteNaming.normalize(name)
        if let s = staticRoutes.first(where: { $0.name == normalized }) {
            return s
        }
        return try dynamicStore.route(named: normalized)
    }

    public func allRoutes() throws -> [WebhookRoute] {
        let dynamicRoutes = try dynamicStore.load()
        return staticRoutes + dynamicRoutes.filter { !staticRouteNames.contains($0.name) }
    }

    /// Config is authoritative: a runtime registration may not take one of these names.
    var staticRouteNames: Set<String> {
        Set(staticRoutes.map(\.name))
    }

    var dynamicRouteStore: WebhookDynamicRouteStore { dynamicStore }
}

public enum WebhookRouteStoreError: Error, Equatable {
    case corruptSubscriptionsFile(path: String)
}

public struct WebhookDynamicRouteStore: Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [WebhookRoute] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    private func loadUnlocked() throws -> [WebhookRoute] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let routes = try? JSONDecoder().decode([WebhookRoute].self, from: data) else {
            // Never `?? []`: the next write would read the empty array, round-modify-write it, and
            // delete every other subscription. A downgrade that cannot decode a newer field is a
            // refusal, not a reset.
            throw WebhookRouteStoreError.corruptSubscriptionsFile(path: fileURL.path)
        }
        // Rows in this file are dynamic by definition. The stored value used to default to
        // `.static`, which inverted the collision rule and mislabelled every route's provenance.
        return routes.map { route in
            var normalized = route
            normalized.source = .dynamic
            return normalized
        }
    }

    private func saveUnlocked(_ routes: [WebhookRoute]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(routes).write(to: fileURL, options: .atomic)
    }

    func route(named name: String) throws -> WebhookRoute? {
        let normalized = WebhookRouteNaming.normalize(name)
        return try load().first { $0.name == normalized }
    }

    /// The only create/update path. A `ValidatedWebhookRoute` cannot be constructed outside
    /// `ValidatedWebhookRoute.validate(...)`, so there is no signature here that accepts a
    /// caller-built route.
    @discardableResult
    func upsert(_ validated: ValidatedWebhookRoute) throws -> WebhookRoute {
        lock.lock()
        defer { lock.unlock() }
        var routes = try loadUnlocked()
        let route = validated.route
        if let idx = routes.firstIndex(where: { $0.name == route.name }) {
            routes[idx] = route
        } else {
            routes.append(route)
        }
        try saveUnlocked(routes)
        return route
    }

    @discardableResult
    func delete(named name: String) throws -> Bool {
        let normalized = WebhookRouteNaming.normalize(name)
        lock.lock()
        defer { lock.unlock() }
        var routes = try loadUnlocked()
        let before = routes.count
        routes.removeAll { $0.name == normalized }
        guard routes.count != before else { return false }
        try saveUnlocked(routes)
        return true
    }
}
