import Foundation

public enum AuthProfileType: String, Sendable, Codable, Hashable {
    case apiKey = "api-key"
    case oauth
    case iam
    case adc
}

public enum AuthProfileStatus: String, Sendable, Codable, Hashable {
    case ok
    case exhausted
    case authError = "auth-error"
    case rateLimited = "rate-limited"
}

public enum AuthProfileSource: String, Sendable, Codable, Hashable {
    case env
    case config
    case oauthStore = "oauth-store"
}

/// Named credential record bound to a provider (spec: AuthProfile / PooledCredential).
public struct AuthProfile: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var providerID: ProviderID
    public var authType: AuthProfileType
    public var apiKey: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var baseURL: URL?
    public var priority: Int
    public var lastStatus: AuthProfileStatus
    public var lastErrorResetAt: Date?
    public var source: AuthProfileSource

    public init(
        id: String,
        providerID: ProviderID,
        authType: AuthProfileType,
        apiKey: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        baseURL: URL? = nil,
        priority: Int = 0,
        lastStatus: AuthProfileStatus = .ok,
        lastErrorResetAt: Date? = nil,
        source: AuthProfileSource = .env
    ) {
        self.id = id
        self.providerID = providerID
        self.authType = authType
        self.apiKey = apiKey
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.baseURL = baseURL
        self.priority = priority
        self.lastStatus = lastStatus
        self.lastErrorResetAt = lastErrorResetAt
        self.source = source
    }

    public func isAvailable(at now: Date = Date()) -> Bool {
        guard lastStatus == .exhausted || lastStatus == .rateLimited else { return true }
        guard let resetAt = lastErrorResetAt else { return true }
        return now >= resetAt
    }
}

public enum AuthProfileRotationStrategy: String, Sendable, Codable, Hashable {
    case fillFirst = "fill_first"
    case roundRobin = "round_robin"
    case random
    case leastUsed = "least_used"
}

public struct AuthProfileSelectionContext: Sendable {
    public var providerID: ProviderID
    public var authProfileLabel: String?
    public var now: Date

    public init(providerID: ProviderID, authProfileLabel: String? = nil, now: Date = Date()) {
        self.providerID = providerID
        self.authProfileLabel = authProfileLabel
        self.now = now
    }
}

public struct ResolvedAuthCredential: Sendable, Equatable {
    public var profile: AuthProfile
    public var apiKey: String

    public init(profile: AuthProfile, apiKey: String) {
        self.profile = profile
        self.apiKey = apiKey
    }
}
