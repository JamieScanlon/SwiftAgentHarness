import Foundation

struct WebhookRouteStore: Sendable {
    private let staticRoutes: [WebhookRoute]
    private let dynamicStore: WebhookDynamicRouteStore

    init(staticRoutes: [WebhookRoute] = [], dynamicStore: WebhookDynamicRouteStore) {
        self.staticRoutes = staticRoutes
        self.dynamicStore = dynamicStore
    }

    func route(named name: String) throws -> WebhookRoute? {
        if let s = staticRoutes.first(where: { $0.name == name }) {
            return s
        }
        return try dynamicStore.route(named: name)
    }

    func allRoutes() throws -> [WebhookRoute] {
        let dynamic = try dynamicStore.load()
        let staticNames = Set(staticRoutes.map(\.name))
        return staticRoutes + dynamic.filter { !staticNames.contains($0.name) }
    }
}

struct WebhookDynamicRouteStore: Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [WebhookRoute] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return (try? JSONDecoder().decode([WebhookRoute].self, from: data)) ?? []
    }

    func save(_ routes: [WebhookRoute]) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(routes)
        try data.write(to: fileURL, options: .atomic)
    }

    func route(named name: String) throws -> WebhookRoute? {
        try load().first { $0.name == name }
    }

    func upsert(_ route: WebhookRoute) throws {
        var routes = try load()
        if let idx = routes.firstIndex(where: { $0.name == route.name }) {
            routes[idx] = route
        } else {
            routes.append(route)
        }
        try save(routes)
    }
}
