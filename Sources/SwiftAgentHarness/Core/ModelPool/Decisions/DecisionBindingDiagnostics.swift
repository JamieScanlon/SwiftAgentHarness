import Foundation

/// Load-time check that a `decide` role's policy bands line up with the versions its candidates serve.
public struct DecisionBindingValidation: Sendable, Equatable {
    public enum Problem: Sendable, Equatable {
        /// The role is unbound, so its consuming layer is off.
        case roleUnbound
        /// The role is bound but no registry entry can serve it.
        case noCandidates
        /// No candidate serves a version the policy has bands for: every verdict resolves to `onUnavailable`.
        case noTunedVersionServed(tuned: [String], served: [String])
        /// Some candidates (fallbacks, escalation target) have no bands and will answer as untuned.
        case candidatesWithoutBands([String])
        /// Bands are keyed by a moving alias. Bands follow pinned versions only, so these never match.
        case bandsKeyedByAlias(alias: String, pinnedVersion: String?)
        /// A candidate is addressed by a moving-alias id instead of a pinned version.
        case movingAliasEndpoint(String)

        /// Problems that leave a threshold-bearing role unable to act.
        public var isError: Bool {
            if case .noTunedVersionServed = self { return true }
            return false
        }
    }

    public var role: ModelRole
    /// Versions the role's candidates serve (their wire ids), including the escalation target.
    public var servedVersions: [String]
    public var tunedVersions: [String]
    public var problems: [Problem]

    public init(role: ModelRole, servedVersions: [String], tunedVersions: [String], problems: [Problem]) {
        self.role = role
        self.servedVersions = servedVersions
        self.tunedVersions = tunedVersions
        self.problems = problems
    }

    /// `true` when the policy can produce an `act` verdict from at least one candidate.
    public var canAct: Bool {
        !problems.contains { $0.isError || $0 == .roleUnbound || $0 == .noCandidates }
    }
}

/// Result of probing one configured alias for drift at warm-up.
public struct DecisionAliasProbe: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// The alias still serves the pinned version.
        case matches
        /// The alias moved. Adopting the new version is an explicit config change with a re-tuning step.
        case drifted(servedVersion: String)
        /// The server echoed the alias, so the version behind it cannot be confirmed.
        case unverifiable
        /// The probe call failed.
        case failed(String)
        /// The provider cannot probe this binding (for example, the server ignores `model`).
        case unsupported
    }

    public var role: ModelRole
    public var alias: String
    public var pinnedVersion: String
    public var bindingID: String
    public var status: Status

    public init(role: ModelRole, alias: String, pinnedVersion: String, bindingID: String, status: Status) {
        self.role = role
        self.alias = alias
        self.pinnedVersion = pinnedVersion
        self.bindingID = bindingID
        self.status = status
    }
}
