import CryptoKit
import Foundation

public enum AuthProfileStoreError: Error, Equatable, Sendable {
    case manifestNotFound(ProviderID)
    case credentialNotFound(ProviderID, profileLabel: String?)
    case credentialExpired(ProviderID, profileLabel: String?)
    case credentialRequiresOnboarding(ProviderID, profileLabel: String?)
    case refreshNotImplemented(ProviderID)
}

/// Resolves auth profiles from manifest-declared env vars and optional auth-profiles.json.
public struct AuthProfileStore: Sendable {
    public var environment: [String: String]
    public var defaultAuthProfileLabel: String?
    public var authProfilesFileURL: URL?
    public var authProfilesFileData: Data?
    public var oauthRefresher: (any ProviderOAuthTokenRefreshing)?
    public var seedProfiles: [AuthProfile]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultAuthProfileLabel: String? = nil,
        authProfilesFileURL: URL? = nil,
        authProfilesFileData: Data? = nil,
        oauthRefresher: (any ProviderOAuthTokenRefreshing)? = nil,
        seedProfiles: [AuthProfile] = []
    ) {
        self.environment = environment
        self.authProfilesFileURL = authProfilesFileURL
        self.authProfilesFileData = authProfilesFileData
        self.oauthRefresher = oauthRefresher
        self.seedProfiles = seedProfiles
        self.defaultAuthProfileLabel = defaultAuthProfileLabel
            ?? normalizedLabel(environment["SAH_SESSION_AUTH_PROFILE"])
    }

    public static func production() -> AuthProfileStore {
        AuthProfileStore(
            defaultAuthProfileLabel: SessionPersistenceConfiguration.sessionAuthProfileLabel
        )
    }

    /// Ordered, deduped credential pool for a single `(provider, profile)` scope.
    /// Sourcing only — no cooldown or selection. Excludes expired access tokens.
    public func resolveCredentialPool(
        providerID: ProviderID,
        authProfileLabel: String? = nil
    ) throws -> [AuthProfile] {
        guard ProviderRegistry.optionalManifest(for: providerID) != nil else {
            throw AuthProfileStoreError.manifestNotFound(providerID)
        }
        let label = normalizedLabel(authProfileLabel) ?? defaultAuthProfileLabel ?? "default"
        var candidates: [AuthProfile] = []
        candidates.append(contentsOf: seedProfiles.filter { $0.providerID == providerID })
        candidates.append(contentsOf: resolveConfigCredentials(providerID: providerID, label: label))
        candidates.append(contentsOf: resolveEnvCredentials(providerID: providerID, label: label))
        let merged = mergeCredentialPool(candidates)
        let filtered = filterExpiredAccessTokens(merged)
        if filtered.isEmpty {
            throw AuthProfileStoreError.credentialNotFound(providerID, profileLabel: label)
        }
        return filtered
    }

    public func resolveCredential(
        providerID: ProviderID,
        authProfileLabel: String? = nil
    ) throws -> ResolvedAuthCredential {
        let label = normalizedLabel(authProfileLabel) ?? defaultAuthProfileLabel ?? "default"
        let pool = try resolveCredentialPool(providerID: providerID, authProfileLabel: authProfileLabel)
        if let ready = pool.first(where: \.isDispatchReady) {
            if ready.authType == .local {
                return ResolvedAuthCredential(profile: ready, bearerToken: "")
            }
            if let bearer = ready.apiKey {
                return ResolvedAuthCredential(profile: ready, bearerToken: bearer)
            }
        }
        if pool.contains(where: \.requiresOnboarding) {
            throw AuthProfileStoreError.credentialRequiresOnboarding(providerID, profileLabel: label)
        }
        throw AuthProfileStoreError.credentialExpired(providerID, profileLabel: label)
    }

    public func resolveAPIKey(
        providerID: ProviderID,
        authProfileLabel: String? = nil
    ) throws -> ResolvedAuthCredential {
        try resolveCredential(providerID: providerID, authProfileLabel: authProfileLabel)
    }

    private func filterExpiredAccessTokens(_ profiles: [AuthProfile]) -> [AuthProfile] {
        profiles.compactMap { profile in
            var normalized = profile
            if normalized.apiKey != nil, normalized.isAccessTokenExpired() {
                if normalized.authType == .oauth, normalized.refreshToken != nil {
                    normalized.apiKey = nil
                } else {
                    return nil
                }
            }
            if normalized.isDispatchReady || normalized.requiresOnboarding {
                return normalized
            }
            return nil
        }
    }

    private func resolveConfigCredentials(providerID: ProviderID, label: String) -> [AuthProfile] {
        guard let providerEntry = loadProviderEntryFromFile(label: label, providerID: providerID) else {
            return []
        }
        if let keysArray = providerEntry["keys"] as? [[String: Any]] {
            return parseConfigKeyEntries(
                keysArray,
                providerID: providerID,
                label: label
            )
        }
        return parseConfigProfileEntry(
            providerEntry,
            providerID: providerID,
            label: label,
            suffix: "0"
        ).map { [$0] } ?? []
    }

    private func parseConfigProfileEntry(
        _ entry: [String: Any],
        providerID: ProviderID,
        label: String,
        suffix: String
    ) -> AuthProfile? {
        let authType = parseAuthType(entry) ?? .apiKey
        if authType == .local {
            guard let baseURL = parseBaseURL(entry) else { return nil }
            let id = (entry["id"] as? String).flatMap(normalizedLabel)
                ?? profileKey(providerID: providerID, label: label, suffix: suffix)
            return AuthProfile(
                id: id,
                providerID: providerID,
                authType: .local,
                baseURL: baseURL,
                priority: parsePriority(entry["priority"]) ?? 0,
                source: .config
            )
        }
        let accessToken = scalarAccessToken(from: entry)
        let refreshToken = scalarRefreshToken(from: entry)
        let expiresAt = parseExpiresAt(entry)
        guard accessToken != nil || refreshToken != nil else { return nil }
        let id = (entry["id"] as? String).flatMap(normalizedLabel)
            ?? profileKey(providerID: providerID, label: label, suffix: suffix)
        let priority = parsePriority(entry["priority"]) ?? 0
        let source: AuthProfileSource = authType == .oauth ? .oauthStore : .config
        return AuthProfile(
            id: id,
            providerID: providerID,
            authType: authType,
            apiKey: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            priority: priority,
            source: source
        )
    }

    private func parseConfigKeyEntries(
        _ entries: [[String: Any]],
        providerID: ProviderID,
        label: String
    ) -> [AuthProfile] {
        var profiles: [AuthProfile] = []
        for (index, entry) in entries.enumerated() {
            if let profile = parseConfigProfileEntry(
                entry,
                providerID: providerID,
                label: label,
                suffix: String(index)
            ) {
                profiles.append(profile)
                continue
            }
            guard let apiKey = scalarAPIKey(from: entry) else { continue }
            let id = (entry["id"] as? String).flatMap(normalizedLabel)
                ?? profileKey(providerID: providerID, label: label, suffix: String(index))
            let priority = parsePriority(entry["priority"]) ?? index
            profiles.append(
                AuthProfile(
                    id: id,
                    providerID: providerID,
                    authType: .apiKey,
                    apiKey: apiKey,
                    priority: priority,
                    source: .config
                )
            )
        }
        return profiles
    }

    private func resolveEnvCredentials(providerID: ProviderID, label: String) -> [AuthProfile] {
        guard let manifest = ProviderRegistry.optionalManifest(for: providerID) else { return [] }
        var profiles: [AuthProfile] = []
        for choice in manifest.providerAuthChoices {
            guard choice.resolvedAuthType == .apiKey else { continue }
            for base in choice.envVars {
                profiles.append(contentsOf: enumerateEnvVarCredentials(
                    providerID: providerID,
                    label: label,
                    baseEnvVar: base
                ))
            }
        }
        return profiles
    }

    private func enumerateEnvVarCredentials(
        providerID: ProviderID,
        label: String,
        baseEnvVar: String
    ) -> [AuthProfile] {
        var profiles: [AuthProfile] = []
        let suffix = envKeySuffix(forAuthProfile: label)
        let profileScopedBase = "\(baseEnvVar)_\(suffix)"
        profiles.append(contentsOf: numberedEnvCredentials(
            providerID: providerID,
            label: label,
            envVarPrefix: profileScopedBase,
            profileScoped: true
        ))
        if label != "default" {
            profiles.append(contentsOf: numberedEnvCredentials(
                providerID: providerID,
                label: label,
                envVarPrefix: baseEnvVar,
                profileScoped: false,
                priorityOffset: 10_000
            ))
        } else {
            profiles.append(contentsOf: numberedEnvCredentials(
                providerID: providerID,
                label: label,
                envVarPrefix: baseEnvVar,
                profileScoped: false
            ))
        }
        profiles.append(contentsOf: delimitedEnvCredentials(
            providerID: providerID,
            label: label,
            envVarName: "\(baseEnvVar)S"
        ))
        if label != "default" {
            profiles.append(contentsOf: delimitedEnvCredentials(
                providerID: providerID,
                label: label,
                envVarName: "\(profileScopedBase)S"
            ))
        }
        return profiles
    }

    private func numberedEnvCredentials(
        providerID: ProviderID,
        label: String,
        envVarPrefix: String,
        profileScoped: Bool,
        priorityOffset: Int = 0
    ) -> [AuthProfile] {
        var profiles: [AuthProfile] = []
        if let value = normalizedEnvValue(environment[envVarPrefix]) {
            profiles.append(
                AuthProfile(
                    id: profileKey(
                        providerID: providerID,
                        label: label,
                        suffix: envVarPrefix
                    ),
                    providerID: providerID,
                    authType: .apiKey,
                    apiKey: value,
                    priority: priorityOffset,
                    source: .env
                )
            )
        }
        var index = 1
        while index <= 64 {
            let envVarName = "\(envVarPrefix)_\(index)"
            guard let value = normalizedEnvValue(environment[envVarName]) else { break }
            profiles.append(
                AuthProfile(
                    id: profileKey(
                        providerID: providerID,
                        label: label,
                        suffix: envVarName
                    ),
                    providerID: providerID,
                    authType: .apiKey,
                    apiKey: value,
                    priority: priorityOffset + index,
                    source: .env
                )
            )
            index += 1
        }
        let _ = profileScoped
        return profiles
    }

    private func delimitedEnvCredentials(
        providerID: ProviderID,
        label: String,
        envVarName: String
    ) -> [AuthProfile] {
        guard let raw = normalizedEnvValue(environment[envVarName]) else { return [] }
        let parts = raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.enumerated().map { index, apiKey in
            AuthProfile(
                id: profileKey(
                    providerID: providerID,
                    label: label,
                    suffix: "\(envVarName)#\(index)"
                ),
                providerID: providerID,
                authType: .apiKey,
                apiKey: apiKey,
                priority: index,
                source: .env
            )
        }
    }

    private func mergeCredentialPool(_ candidates: [AuthProfile]) -> [AuthProfile] {
        var byFingerprint: [String: AuthProfile] = [:]
        for candidate in candidates {
            guard let fingerprintMaterial = credentialFingerprintMaterial(for: candidate) else { continue }
            let fingerprint = credentialFingerprint(for: fingerprintMaterial)
            if let existing = byFingerprint[fingerprint] {
                if sourceRank(existing.source) <= sourceRank(candidate.source) {
                    continue
                }
            }
            byFingerprint[fingerprint] = candidate
        }
        return byFingerprint.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            let lhsRank = sourceRank(lhs.source)
            let rhsRank = sourceRank(rhs.source)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.id < rhs.id
        }
    }

    private func credentialFingerprintMaterial(for profile: AuthProfile) -> String? {
        if let apiKey = profile.apiKey { return apiKey }
        if let refreshToken = profile.refreshToken { return refreshToken }
        return profile.id
    }

    private func loadProviderEntryFromFile(label: String, providerID: ProviderID) -> [String: Any]? {
        let profileData: Data?
        if let authProfilesFileData {
            profileData = SessionAuthProfilesFile.dataForProfile(from: authProfilesFileData, name: label)
        } else if let authProfilesFileURL {
            profileData = try? SessionAuthProfilesFile.loadProfile(fromFileAt: authProfilesFileURL, name: label)
        } else {
            return nil
        }
        guard let profileData,
              let obj = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any]
        else {
            return nil
        }
        return obj[providerID] as? [String: Any] ?? obj
    }

    private func parseBaseURL(_ entry: [String: Any]) -> URL? {
        let raw = (entry["baseURL"] as? String)
            ?? (entry["baseUrl"] as? String)
            ?? (entry["base_url"] as? String)
        guard let raw, let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return url
    }

    private func parseAuthType(_ entry: [String: Any]) -> AuthProfileType? {
        let raw = (entry["authType"] as? String)
            ?? (entry["auth_type"] as? String)
        guard let raw else { return nil }
        return AuthProfileType(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? AuthProfileType.inferred(fromChoiceID: raw)
    }

    private func scalarAccessToken(from entry: [String: Any]) -> String? {
        let raw = (entry["accessToken"] as? String)
            ?? (entry["access_token"] as? String)
            ?? scalarAPIKey(from: entry)
        return normalizedEnvValue(raw)
    }

    private func scalarRefreshToken(from entry: [String: Any]) -> String? {
        let raw = (entry["refreshToken"] as? String)
            ?? (entry["refresh_token"] as? String)
        return normalizedEnvValue(raw)
    }

    private func parseExpiresAt(_ entry: [String: Any]) -> Date? {
        if let seconds = entry["expiresAt"] as? TimeInterval {
            return Date(timeIntervalSince1970: seconds)
        }
        if let seconds = entry["expires_at"] as? TimeInterval {
            return Date(timeIntervalSince1970: seconds)
        }
        if let seconds = entry["expiresAt"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        if let seconds = entry["expires_at"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        if let raw = entry["expiresAt"] as? String, let parsed = Double(raw) {
            return Date(timeIntervalSince1970: parsed)
        }
        return nil
    }

    private func scalarAPIKey(from entry: [String: Any]) -> String? {
        let raw = (entry["apiKey"] as? String)
            ?? (entry["api_key"] as? String)
            ?? (entry["key"] as? String)
        return normalizedEnvValue(raw)
    }

    private func parsePriority(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String, let parsed = Int(value) { return parsed }
        return nil
    }

    private func profileKey(providerID: ProviderID, label: String, suffix: String) -> String {
        "\(providerID)#\(label)#\(suffix)"
    }

    private func sourceRank(_ source: AuthProfileSource) -> Int {
        switch source {
        case .config: 0
        case .oauthStore: 1
        case .env: 2
        }
    }

    private func credentialFingerprint(for secret: String) -> String {
        let digest = SHA256.hash(data: Data(secret.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedEnvValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func envKeySuffix(forAuthProfile profile: String) -> String {
        let upper = profile.uppercased()
        let mappedScalars = upper.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "_"
        }
        return String(mappedScalars)
    }
}
