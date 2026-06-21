import Foundation

enum SubAgentReferenceResolver {
    static func resolve(
        reference: SubAgentReference,
        in entries: [SubAgentRegistryEntry]
    ) -> SubAgentRegistryEntry? {
        if let identifier = reference.preferredIdentifier() {
            return entries.first {
                $0.agentID.caseInsensitiveCompare(identifier) == .orderedSame
                    || $0.delegateToolName.caseInsensitiveCompare(identifier) == .orderedSame
            }
        }
        if let query = reference.query {
            return rank(query: query, in: entries).first
        }
        return nil
    }

    static func rank(query: SubAgentQuery, in entries: [SubAgentRegistryEntry]) -> [SubAgentRegistryEntry] {
        let filtered = entries.filter { matches(query: query, entry: $0) }
        return filtered.sorted { lhs, rhs in
            let lhsScore = score(query: query, entry: lhs)
            let rhsScore = score(query: query, entry: rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.agentID < rhs.agentID
        }
    }

    private static func matches(query: SubAgentQuery, entry: SubAgentRegistryEntry) -> Bool {
        if let transportKinds = query.transportKinds, !transportKinds.isEmpty {
            let allowed = Set(transportKinds.map { $0.lowercased() })
            if !allowed.contains(entry.transportKind.lowercased()) { return false }
        }
        if let useClasses = query.useClasses, !useClasses.isEmpty {
            let expected = Set(useClasses.map { $0.lowercased() })
            let actual = Set(entry.useClasses.map { $0.lowercased() })
            if expected.intersection(actual).isEmpty { return false }
        }
        if let policies = query.permissionPolicies, !policies.isEmpty {
            let allowed = Set(policies.map { $0.lowercased() })
            if !allowed.contains(entry.permissionPolicy.rawValue.lowercased()) { return false }
        }
        if let trustLevels = query.trustLevels, !trustLevels.isEmpty {
            let allowed = Set(trustLevels.map { $0.lowercased() })
            if !allowed.contains(entry.defaultTrustLevel.rawValue.lowercased()) { return false }
        }
        if let requiresStreaming = query.requiresStreaming,
           (entry.streaming ?? false) != requiresStreaming {
            return false
        }
        if let requiresLongRunning = query.requiresLongRunning,
           (entry.longRunning ?? false) != requiresLongRunning {
            return false
        }
        if let hostPersonaID = query.hostPersonaID,
           !hostPersonaID.isEmpty {
            guard entry.hostingPolicy.hostPersonaID?.caseInsensitiveCompare(hostPersonaID) == .orderedSame else {
                return false
            }
        }
        if let routingDomain = query.routingDomain,
           !routingDomain.isEmpty {
            guard entry.hostingPolicy.routingDomain?.caseInsensitiveCompare(routingDomain) == .orderedSame else {
                return false
            }
        }
        if let tenantScope = query.tenantScope,
           !tenantScope.isEmpty {
            guard entry.hostingPolicy.tenantScope?.caseInsensitiveCompare(tenantScope) == .orderedSame else {
                return false
            }
        }
        if let authScopeTags = query.authScopeTags,
           !authScopeTags.isEmpty {
            let required = Set(authScopeTags.map { $0.lowercased() })
            let available = Set(entry.hostingPolicy.authScopeTags.map { $0.lowercased() })
            if !required.isSubset(of: available) {
                return false
            }
        }
        return true
    }

    private static func score(query: SubAgentQuery, entry: SubAgentRegistryEntry) -> Int {
        var total = 0
        if let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let token = text.lowercased()
            let haystack = [
                entry.agentID.lowercased(),
                entry.displayName.lowercased(),
                entry.description.lowercased(),
                entry.delegateToolName.lowercased(),
            ]
            if haystack.contains(where: { $0 == token }) {
                total += 100
            } else if haystack.contains(where: { $0.contains(token) }) {
                total += 40
            }
        }
        if let transports = query.transportKinds, transports.contains(where: { $0.caseInsensitiveCompare(entry.transportKind) == .orderedSame }) {
            total += 20
        }
        if let useClasses = query.useClasses, !useClasses.isEmpty {
            let expected = Set(useClasses.map { $0.lowercased() })
            let actual = Set(entry.useClasses.map { $0.lowercased() })
            total += expected.intersection(actual).count * 5
        }
        if query.requiresStreaming == true && entry.streaming == true {
            total += 5
        }
        if query.requiresLongRunning == true && entry.longRunning == true {
            total += 5
        }
        if let hostPersonaID = query.hostPersonaID,
           entry.hostingPolicy.hostPersonaID?.caseInsensitiveCompare(hostPersonaID) == .orderedSame {
            total += 20
        }
        if let authScopeTags = query.authScopeTags, !authScopeTags.isEmpty {
            let required = Set(authScopeTags.map { $0.lowercased() })
            let available = Set(entry.hostingPolicy.authScopeTags.map { $0.lowercased() })
            total += required.intersection(available).count * 3
        }
        return total
    }
}
