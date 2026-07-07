import Foundation

public enum ProviderManifestValidationError: Error, Equatable, Sendable {
    case emptyID
    case emptyLabel
    case missingEndpoints
    case invalidEndpointURL(String)
    case duplicateEndpointID(String, providerID: ProviderID)
    case duplicateModelPrefix(String, existingProvider: ProviderID, newProvider: ProviderID)
    case emptyAuthChoiceID(providerID: ProviderID)
    case emptyAuthChoiceEnvVars(choiceID: String, providerID: ProviderID)
    case emptyOAuthScope(choiceID: String, providerID: ProviderID)
    case duplicateManifestID(ProviderID)
    case emptyCLIBackendID(providerID: ProviderID)
    case duplicateCLIBackendID(String, providerID: ProviderID)
    case cliInferenceBackendSlotWithoutBackends(providerID: ProviderID)
    case undeclaredSlotRegistration(ProviderCapabilitySlot, providerID: ProviderID)
    case missingCLIBackendRegistration(String, providerID: ProviderID)
}

/// Static manifest validation for pluginsInspect-style offline checks.
public enum ProviderManifestValidation {
    public static func validate(_ manifest: ProviderManifest) throws {
        let trimmedID = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw ProviderManifestValidationError.emptyID }
        guard !manifest.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderManifestValidationError.emptyLabel
        }
        guard !manifest.providerEndpoints.isEmpty else {
            throw ProviderManifestValidationError.missingEndpoints
        }
        var endpointIDs = Set<String>()
        for endpoint in manifest.providerEndpoints {
            guard endpoint.baseURL.scheme != nil, endpoint.baseURL.host != nil else {
                throw ProviderManifestValidationError.invalidEndpointURL(endpoint.id)
            }
            if endpointIDs.contains(endpoint.id) {
                throw ProviderManifestValidationError.duplicateEndpointID(endpoint.id, providerID: manifest.id)
            }
            endpointIDs.insert(endpoint.id)
        }
        for choice in manifest.providerAuthChoices {
            guard !choice.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderManifestValidationError.emptyAuthChoiceID(providerID: manifest.id)
            }
            let authType = choice.resolvedAuthType
            if authType == .apiKey, choice.envVars.isEmpty {
                throw ProviderManifestValidationError.emptyAuthChoiceEnvVars(
                    choiceID: choice.id,
                    providerID: manifest.id
                )
            }
            if authType == .oauth {
                for scope in choice.onboardingScopes {
                    guard !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderManifestValidationError.emptyOAuthScope(
                            choiceID: choice.id,
                            providerID: manifest.id
                        )
                    }
                }
            }
        }
        var cliBackendIDs = Set<String>()
        for backend in manifest.cliBackends {
            let trimmed = backend.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ProviderManifestValidationError.emptyCLIBackendID(providerID: manifest.id)
            }
            if cliBackendIDs.contains(trimmed) {
                throw ProviderManifestValidationError.duplicateCLIBackendID(trimmed, providerID: manifest.id)
            }
            cliBackendIDs.insert(trimmed)
        }
        if manifest.capabilitySlots.contains(.cliInferenceBackend), manifest.cliBackends.isEmpty {
            throw ProviderManifestValidationError.cliInferenceBackendSlotWithoutBackends(providerID: manifest.id)
        }
    }

    public static func validateRegistrationConsistency(_ registration: ProviderRegistration) throws {
        try validate(registration.manifest)
        let declared = Set(registration.manifest.capabilitySlots)
        for slot in registration.registeredSlots() {
            guard declared.contains(slot) else {
                throw ProviderManifestValidationError.undeclaredSlotRegistration(slot, providerID: registration.manifest.id)
            }
        }
        guard registration.manifest.capabilitySlots.contains(.cliInferenceBackend) else { return }
        let registeredCLIIDs = Set(registration.registeredCLIBackendIDs)
        for backend in registration.manifest.cliBackends {
            guard registeredCLIIDs.contains(backend.id) else {
                throw ProviderManifestValidationError.missingCLIBackendRegistration(
                    backend.id,
                    providerID: registration.manifest.id
                )
            }
        }
    }

    public static func validateAll(_ manifests: [ProviderManifest]) throws {
        var seenIDs = Set<ProviderID>()
        for manifest in manifests {
            if seenIDs.contains(manifest.id) {
                throw ProviderManifestValidationError.duplicateManifestID(manifest.id)
            }
            seenIDs.insert(manifest.id)
            try validate(manifest)
        }
        try validateModelPrefixCollisions(manifests)
    }

    public static func validateModelPrefixCollisions(_ manifests: [ProviderManifest]) throws {
        var prefixOwners: [String: ProviderID] = [:]
        for manifest in manifests {
            for prefix in manifest.modelSupport.modelPrefixes {
                let normalized = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                if let existing = prefixOwners[normalized], existing != manifest.id {
                    throw ProviderManifestValidationError.duplicateModelPrefix(
                        normalized,
                        existingProvider: existing,
                        newProvider: manifest.id
                    )
                }
                prefixOwners[normalized] = manifest.id
            }
        }
    }

    public static func inspect(_ manifests: [ProviderManifest]) -> [ProviderManifest] {
        (try? validateAll(manifests)) != nil ? manifests.sorted { $0.id < $1.id } : []
    }
}
