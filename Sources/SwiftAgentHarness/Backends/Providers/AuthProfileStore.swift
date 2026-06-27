import Foundation

public enum AuthProfileStoreError: Error, Equatable, Sendable {
    case manifestNotFound(ProviderID)
    case credentialNotFound(ProviderID, profileLabel: String?)
}

/// Resolves auth profiles from manifest-declared env vars and optional auth-profiles.json.
public struct AuthProfileStore: Sendable {
    public var environment: [String: String]
    public var defaultAuthProfileLabel: String?
    public var authProfilesFileURL: URL?
    public var authProfilesFileData: Data?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultAuthProfileLabel: String? = nil,
        authProfilesFileURL: URL? = nil,
        authProfilesFileData: Data? = nil
    ) {
        self.environment = environment
        self.defaultAuthProfileLabel = defaultAuthProfileLabel
            ?? normalizedLabel(environment["SAH_SESSION_AUTH_PROFILE"])
        self.authProfilesFileURL = authProfilesFileURL
        self.authProfilesFileData = authProfilesFileData
    }

    public static func production() -> AuthProfileStore {
        AuthProfileStore(
            defaultAuthProfileLabel: SessionPersistenceConfiguration.sessionAuthProfileLabel
        )
    }

    public func resolveAPIKey(
        providerID: ProviderID,
        authProfileLabel: String? = nil
    ) throws -> ResolvedAuthCredential {
        guard let manifest = ProviderManifests.manifest(for: providerID) else {
            throw AuthProfileStoreError.manifestNotFound(providerID)
        }
        let label = normalizedLabel(authProfileLabel) ?? defaultAuthProfileLabel ?? "default"

        if let fromFile = try resolveFromAuthProfilesFile(providerID: providerID, label: label) {
            return fromFile
        }

        for choice in manifest.providerAuthChoices {
            if let key = resolveEnvKey(from: choice.envVars, profileLabel: label) {
                let profile = AuthProfile(
                    id: profileKey(providerID: providerID, label: label),
                    providerID: providerID,
                    authType: .apiKey,
                    apiKey: key,
                    priority: 0,
                    source: .env
                )
                return ResolvedAuthCredential(profile: profile, apiKey: key)
            }
        }

        throw AuthProfileStoreError.credentialNotFound(providerID, profileLabel: label)
    }

    public func resolveAPIKeyOrDummy(
        providerID: ProviderID,
        authProfileLabel: String? = nil
    ) -> String {
        (try? resolveAPIKey(providerID: providerID, authProfileLabel: authProfileLabel))?.apiKey ?? "dummy_key"
    }

    private func resolveFromAuthProfilesFile(
        providerID: ProviderID,
        label: String
    ) throws -> ResolvedAuthCredential? {
        let profileData: Data?
        if let authProfilesFileData {
            profileData = SessionAuthProfilesFile.dataForProfile(from: authProfilesFileData, name: label)
        } else if let authProfilesFileURL {
            profileData = try SessionAuthProfilesFile.loadProfile(fromFileAt: authProfilesFileURL, name: label)
        } else {
            return nil
        }
        guard let profileData,
              let obj = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any]
        else {
            return nil
        }
        let providerEntry = obj[providerID] as? [String: Any] ?? obj
        let apiKey = (providerEntry["apiKey"] as? String)
            ?? (providerEntry["api_key"] as? String)
            ?? (providerEntry["key"] as? String)
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let profile = AuthProfile(
            id: profileKey(providerID: providerID, label: label),
            providerID: providerID,
            authType: .apiKey,
            apiKey: apiKey,
            priority: 0,
            source: .config
        )
        return ResolvedAuthCredential(profile: profile, apiKey: apiKey)
    }

    private func resolveEnvKey(from envVars: [String], profileLabel: String?) -> String? {
        if let profileLabel, !profileLabel.isEmpty {
            let suffix = envKeySuffix(forAuthProfile: profileLabel)
            for base in envVars {
                if let value = normalizedEnvValue(environment["\(base)_\(suffix)"]) {
                    return value
                }
            }
        }
        for key in envVars {
            if let value = normalizedEnvValue(environment[key]) {
                return value
            }
        }
        return nil
    }

    private func profileKey(providerID: ProviderID, label: String) -> String {
        "\(providerID)#\(label)"
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
