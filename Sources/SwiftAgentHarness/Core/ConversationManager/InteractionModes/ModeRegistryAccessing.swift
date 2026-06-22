import Foundation
import Logging

enum ModeRegistryError: Error, Sendable, Equatable {
    case duplicateRegistration(id: String)
    case unknownMode(id: String)
}

public struct ModeProfileSummary: Sendable, Equatable, Codable {
    public let toolPolicy: String?
    public let compaction: String?
    public let maxIterations: Int?
    public let modelTier: String?

    public init(
        toolPolicy: String? = nil,
        compaction: String? = nil,
        maxIterations: Int? = nil,
        modelTier: String? = nil
    ) {
        self.toolPolicy = toolPolicy
        self.compaction = compaction
        self.maxIterations = maxIterations
        self.modelTier = modelTier
    }
}

/// Row for REST/UI mode pickers (`modes.md` registry `list()` parity).
public struct ModeProfilePickerRow: Sendable, Equatable {
    public let id: String
    public let label: String
    public let description: String?
    public let symbol: String?
    public let summary: ModeProfileSummary?

    public init(id: String, label: String, description: String?, symbol: String?, summary: ModeProfileSummary? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.symbol = symbol
        self.summary = summary
    }
}

public protocol ModeRegistryAccessing: Sendable {
    func register(_ profile: ResolvedModeProfile, replacing: Bool) async throws
    func reloadProjectConfig() async -> Bool
    func resolve(modeId: String) async throws -> ResolvedModeProfile
    func resolveReportingFallback(
        modeId: String,
        logger: Logger?,
        fallbackModeId: String
    ) async -> (profile: ResolvedModeProfile, didFallback: Bool)
    func registeredModeIDs() async -> [String]
    func profilesForPicker() async -> [ModeProfilePickerRow]
    func configurationDiagnostics() async -> [String]
}

/// Forwards ``ModeRegistryAccessing`` calls to ``ModeRegistryService``.
final class ModeRegistryPortAdapter: ModeRegistryAccessing, Sendable {
    private let service: ModeRegistryService

    init(service: ModeRegistryService) {
        self.service = service
    }

    func register(_ profile: ResolvedModeProfile, replacing: Bool) async throws {
        try await service.register(profile, replacing: replacing)
    }

    func reloadProjectConfig() async -> Bool {
        await service.reloadProjectConfig()
    }

    func resolve(modeId: String) async throws -> ResolvedModeProfile {
        try await service.resolve(modeId: modeId)
    }

    func resolveReportingFallback(
        modeId: String,
        logger: Logger?,
        fallbackModeId: String
    ) async -> (profile: ResolvedModeProfile, didFallback: Bool) {
        await service.resolveReportingFallback(modeId: modeId, logger: logger, fallbackModeId: fallbackModeId)
    }

    func registeredModeIDs() async -> [String] {
        await service.registeredModeIDs()
    }

    func profilesForPicker() async -> [ModeProfilePickerRow] {
        await service.profilesForPicker()
    }

    func configurationDiagnostics() async -> [String] {
        await service.configurationDiagnostics()
    }
}

enum ModeRegistryTestSupport {
    static func makeService(
        seedingBuiltIns: Bool = true,
        modeProfileConfiguration: ModeProfileConfiguration? = nil,
        projectConfigDirectory: URL? = nil,
        additionalProfiles: [ResolvedModeProfile] = []
    ) -> ModeRegistryService {
        ModeRegistryService(
            seedingBuiltIns: seedingBuiltIns,
            modeProfileConfiguration: modeProfileConfiguration,
            projectConfigDirectory: projectConfigDirectory,
            additionalProfiles: additionalProfiles
        )
    }

    static func makePort(
        seedingBuiltIns: Bool = true,
        modeProfileConfiguration: ModeProfileConfiguration? = nil,
        projectConfigDirectory: URL? = nil,
        additionalProfiles: [ResolvedModeProfile] = []
    ) -> ModeRegistryPortAdapter {
        ModeRegistryPortAdapter(
            service: makeService(
                seedingBuiltIns: seedingBuiltIns,
                modeProfileConfiguration: modeProfileConfiguration,
                projectConfigDirectory: projectConfigDirectory,
                additionalProfiles: additionalProfiles
            )
        )
    }
}
