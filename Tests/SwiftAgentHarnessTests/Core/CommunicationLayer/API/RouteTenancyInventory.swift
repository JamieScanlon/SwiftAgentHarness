import Foundation

enum RouteTenancyGuard: String, Codable, Sendable {
    case conversationAccess
    case createMutation
    case collectionScope
    case none
}

struct RouteTenancyInventoryEntry: Codable, Sendable, Hashable {
    let method: String
    let path: String
    let tenancyGuard: RouteTenancyGuard
    let sourceFile: String
    let handlerAnchor: String

    enum CodingKeys: String, CodingKey {
        case method
        case path
        case tenancyGuard = "tenancy_guard"
        case sourceFile = "source_file"
        case handlerAnchor = "handler_anchor"
    }

    var routeLabel: String { "\(method) \(path)" }
}

struct RouteTenancyInventory: Codable, Sendable {
    let routes: [RouteTenancyInventoryEntry]
}

enum RouteTenancyInventoryLoader {
    static let allTenancyHelperSubstrings: [String] = [
        "tenancyRespondIfConversationAccessForbidden",
        "tenancyRespondIfCreateMutationForbidden",
        "tenancyResolveCollectionOwnerScope",
        "tenancyEnsureConversationTenant",
        "tenancyEnsureAuthenticatedOwnerForMutation",
    ]

    static func repositoryRoot(from testFilePath: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: testFilePath)
        for _ in 0..<6 {
            url.deleteLastPathComponent()
        }
        return url
    }

    static func load(from repositoryRoot: URL) throws -> RouteTenancyInventory {
        let inventoryURL = repositoryRoot
            .appending(path: "openapi/route-tenancy-inventory.json")
        let data = try Data(contentsOf: inventoryURL)
        return try JSONDecoder().decode(RouteTenancyInventory.self, from: data)
    }

    static func requiredGuardSubstrings(for guardKind: RouteTenancyGuard) -> [String] {
        switch guardKind {
        case .conversationAccess:
            return [
                "tenancyRespondIfConversationAccessForbidden",
                "tenancyEnsureConversationTenant",
            ]
        case .createMutation:
            return [
                "tenancyRespondIfCreateMutationForbidden",
                "tenancyEnsureAuthenticatedOwnerForMutation",
            ]
        case .collectionScope:
            return ["tenancyResolveCollectionOwnerScope"]
        case .none:
            return []
        }
    }

    static func sourceText(for entry: RouteTenancyInventoryEntry, repositoryRoot: URL) throws -> String {
        let fileURL = repositoryRoot.appending(path: entry.sourceFile)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    static func handlerRegion(in source: String, anchor: String) -> String? {
        if isStaticFunctionAnchor(anchor) {
            guard let openingBrace = openingBraceOfStaticFunction(in: source, functionName: anchor) else {
                return nil
            }
            return extractBraceDelimitedRegion(in: source, openingBraceIndex: openingBrace)
        }
        guard let openingBrace = openingBraceAfterAnchor(in: source, anchor: anchor) else {
            return nil
        }
        return extractBraceDelimitedRegion(in: source, openingBraceIndex: openingBrace)
    }

    static func regionContainsRequiredGuard(_ region: String, guardKind: RouteTenancyGuard) -> Bool {
        let required = requiredGuardSubstrings(for: guardKind)
        guard !required.isEmpty else { return true }
        return required.contains { region.contains($0) }
    }

    static func regionContainsAnyTenancyHelper(_ region: String) -> Bool {
        allTenancyHelperSubstrings.contains { region.contains($0) }
    }

    private static func isStaticFunctionAnchor(_ anchor: String) -> Bool {
        !anchor.contains("Path.") && !anchor.hasPrefix("api.")
    }

    private static func openingBraceAfterAnchor(in source: String, anchor: String) -> String.Index? {
        guard let anchorRange = source.range(of: anchor) else { return nil }
        if anchor.hasSuffix("{") {
            return source.index(before: anchorRange.upperBound)
        }
        var index = anchorRange.upperBound
        while index < source.endIndex {
            if source[index] == "{" {
                return index
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func openingBraceOfStaticFunction(in source: String, functionName: String) -> String.Index? {
        guard let signatureStart = source.range(of: "static func \(functionName)(")?.upperBound else {
            return nil
        }
        var depth = 1
        var index = signatureStart
        while index < source.endIndex {
            let character = source[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    var bodySearch = source.index(after: index)
                    while bodySearch < source.endIndex {
                        if source[bodySearch] == "{" {
                            return bodySearch
                        }
                        bodySearch = source.index(after: bodySearch)
                    }
                    return nil
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func extractBraceDelimitedRegion(
        in source: String,
        openingBraceIndex: String.Index
    ) -> String? {
        guard source[openingBraceIndex] == "{" else { return nil }
        var depth = 0
        var index = openingBraceIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = source.index(after: index)
                    return String(source[openingBraceIndex..<end])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
