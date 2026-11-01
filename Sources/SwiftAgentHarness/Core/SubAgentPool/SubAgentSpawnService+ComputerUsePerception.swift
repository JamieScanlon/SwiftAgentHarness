import Foundation
import SwiftAgentKit

/// The helper models one specialist run perceives through.
struct ComputerUsePerceptionModels: Sendable {
    var describer: ComputerUseDescriber?
    var grounder: ComputerUseGrounder?
}

struct ComputerUsePerceptionBindingError: Error, Sendable {
    var reason: String
}

extension SubAgentSpawnService {
    /// Binds the `grounder` role, and the `vision-describe` role when the computer-use model can't see images. A role
    /// the profile names must resolve to a model that can see images, or the run is blocked. An unnamed
    /// `vision-describe` falls back to any registered model that can; with none, `describer` is `nil`.
    func computerUsePerception(
        _ profile: ComputerUseSpecialistProfile,
        seesImages: Bool,
        conversationID: UUID
    ) async throws(ComputerUsePerceptionBindingError) -> ComputerUsePerceptionModels {
        var models = ComputerUsePerceptionModels()
        if let ref = profile.grounderModelRef {
            let entry = try await visionEntry(ref, role: .grounder)
            models.grounder = ComputerUseGrounder(
                model: try await imageAsker(entry, role: .grounder, conversationID: conversationID),
                coordinateMode: entry.profile(for: .generate).flatMap(ComputerUseModelSupport.init(profile:))?.coordinateMode ?? .imagePixels
            )
        }
        guard !seesImages else { return models }
        let entry: ModelRegistryEntry
        if let ref = profile.visionDescribeModelRef {
            entry = try await visionEntry(ref, role: .visionDescribe)
        } else if let any = await deps.rankedRegistryEntriesProvider?(.query(ModelQuery(mustIncludeCapabilities: [.vision])))
            .first(where: { $0.capabilities.contains(.vision) }) {
            entry = any
        } else {
            return models
        }
        models.describer = ComputerUseDescriber(model: try await imageAsker(entry, role: .visionDescribe, conversationID: conversationID))
        return models
    }

    private func visionEntry(_ ref: String, role: ModelRole) async throws(ComputerUsePerceptionBindingError) -> ModelRegistryEntry {
        guard let reference = ModelReference.parse(ref),
              let entry = await deps.rankedRegistryEntriesProvider?(reference).first
        else { throw ComputerUsePerceptionBindingError(reason: "the \(role) model '\(ref)' did not resolve") }
        guard entry.capabilities.contains(.vision) else {
            throw ComputerUsePerceptionBindingError(reason: "the \(role) model '\(ref)' cannot see images")
        }
        return entry
    }

    private func imageAsker(
        _ entry: ModelRegistryEntry,
        role: ModelRole,
        conversationID: UUID
    ) async throws(ComputerUsePerceptionBindingError) -> any ComputerUseImageAsking {
        let systemPrompt: SystemPrompt
        do {
            systemPrompt = try await SystemPrompt(skillLoader: nil, logger: nil)
        } catch {
            throw ComputerUsePerceptionBindingError(reason: "the \(role) model could not be prepared: \(error)")
        }
        return ComputerUseLLMImageAsker(llm: deps.llmFactory.makeBaseLLM(
            model: entry.toModel(),
            providerBindings: entry.providers,
            conversationID: conversationID,
            ownerAccountID: nil,
            systemPrompt: systemPrompt,
            logger: nil,
            attemptObserver: nil
        ))
    }
}
