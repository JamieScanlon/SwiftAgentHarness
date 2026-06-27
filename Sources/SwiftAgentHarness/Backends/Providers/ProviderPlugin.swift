import Foundation
import Logging
import SwiftAgentKit

/// Text-inference provider runtime contract (spec: ProviderPlugin wire codec + hooks).
public protocol TextInferenceProviding: Sendable {
    var manifest: ProviderManifest { get }
    var modelProtocol: ModelProtocol { get }

    func staticCatalogEntries() -> [ProviderCatalogEntry]
    func resolveDynamicModel(_ context: ProviderDynamicModelContext) async -> ProviderCatalogEntry?
    func prepareDynamicModel(_ context: ProviderDynamicPrepareContext) async -> ProviderCatalogEntry?
    func preferRuntimeResolvedModel(_ context: ProviderDynamicModelPreferenceContext) -> Bool
    func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry]
    func normalizeProviderModelId(_ raw: String) -> String
    func makeAdapter(context: ProviderAdapterContext) -> any LLMProtocol
    func normalizeToolSchemas(_ tools: [ToolDefinition], context: ProviderToolNormalizationContext) -> [ToolDefinition]
    func transformMessages(_ messages: [Message], context: ProviderMessageTransformContext) -> [Message]
    func replayPolicy(_ context: ProviderMessageTransformContext) -> ProviderReplayPolicy
    func validateReplayTurns(_ messages: [Message], context: ProviderReplayTurnContext) -> [ProviderReplayValidationIssue]
    func resolveSystemPromptContribution(_ context: ProviderSystemPromptContext) -> ProviderSystemPromptContribution?
    func cacheTtlEligibility(_ context: ProviderSystemPromptContext) -> ProviderCacheTTLEligibility
    func failoverError(_ error: Error) -> ProviderFailoverClassification
}

public extension TextInferenceProviding {
    func normalizeProviderModelId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolveDynamicModel(_ context: ProviderDynamicModelContext) async -> ProviderCatalogEntry? {
        nil
    }

    func prepareDynamicModel(_ context: ProviderDynamicPrepareContext) async -> ProviderCatalogEntry? {
        context.catalogEntry
    }

    func preferRuntimeResolvedModel(_ context: ProviderDynamicModelPreferenceContext) -> Bool {
        false
    }

    func transformMessages(_ messages: [Message], context: ProviderMessageTransformContext) -> [Message] {
        let policy = replayPolicy(context)
        let envelopes = HarnessMessageEnvelopeStore.envelopes(for: messages)
        return ProviderMessageReplayTransformer.transform(
            messages,
            envelopes: envelopes,
            policy: policy,
            context: context
        )
    }

    func replayPolicy(_ context: ProviderMessageTransformContext) -> ProviderReplayPolicy {
        ProviderMessageReplayTransformer.defaultReplayPolicy(for: context)
    }

    func validateReplayTurns(
        _ messages: [Message],
        context: ProviderReplayTurnContext
    ) -> [ProviderReplayValidationIssue] {
        let envelopes = HarnessMessageEnvelopeStore.envelopes(for: messages)
        return ProviderMessageReplayTransformer.validate(messages, envelopes: envelopes, context: context)
    }

    func normalizeToolSchemas(
        _ tools: [ToolDefinition],
        context: ProviderToolNormalizationContext
    ) -> [ToolDefinition] {
        ProviderToolSchemaNormalizer.normalize(tools, providerID: manifest.id, strictMode: context.strictMode)
    }

    func resolveSystemPromptContribution(_ context: ProviderSystemPromptContext) -> ProviderSystemPromptContribution? {
        nil
    }

    func cacheTtlEligibility(_ context: ProviderSystemPromptContext) -> ProviderCacheTTLEligibility {
        .none
    }

    func failoverError(_ error: Error) -> ProviderFailoverClassification {
        DefaultProviderFailoverClassifier.classify(error)
    }

    func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry] {
        guard let endpoint = manifest.defaultEndpoint else { return [] }
        return staticCatalogEntries().map {
            $0.toRegistryEntry(providerID: manifest.id, serverURL: endpoint.baseURL)
        }
    }
}

public struct ProviderRegistration: Sendable {
    public let manifest: ProviderManifest
    public let textInference: (any TextInferenceProviding)?
    public let cliInferenceBackends: [any CLIInferenceBackendProviding]
    public let speech: (any SpeechProviding)?
    public let realtimeTranscription: (any RealtimeTranscriptionProviding)?
    public let realtimeVoice: (any RealtimeVoiceProviding)?
    public let mediaUnderstanding: (any MediaUnderstandingProviding)?
    public let imageGeneration: (any ImageGenerationProviding)?
    public let videoGeneration: (any VideoGenerationProviding)?
    public let musicGeneration: (any MusicGenerationProviding)?
    public let webFetch: (any WebFetchProviding)?
    public let webSearch: (any WebSearchProviding)?

    public init(
        manifest: ProviderManifest,
        textInference: (any TextInferenceProviding)? = nil,
        cliInferenceBackends: [any CLIInferenceBackendProviding] = [],
        speech: (any SpeechProviding)? = nil,
        realtimeTranscription: (any RealtimeTranscriptionProviding)? = nil,
        realtimeVoice: (any RealtimeVoiceProviding)? = nil,
        mediaUnderstanding: (any MediaUnderstandingProviding)? = nil,
        imageGeneration: (any ImageGenerationProviding)? = nil,
        videoGeneration: (any VideoGenerationProviding)? = nil,
        musicGeneration: (any MusicGenerationProviding)? = nil,
        webFetch: (any WebFetchProviding)? = nil,
        webSearch: (any WebSearchProviding)? = nil
    ) {
        self.manifest = manifest
        self.textInference = textInference
        self.cliInferenceBackends = cliInferenceBackends
        self.speech = speech
        self.realtimeTranscription = realtimeTranscription
        self.realtimeVoice = realtimeVoice
        self.mediaUnderstanding = mediaUnderstanding
        self.imageGeneration = imageGeneration
        self.videoGeneration = videoGeneration
        self.musicGeneration = musicGeneration
        self.webFetch = webFetch
        self.webSearch = webSearch
    }

    public func implementation(for slot: ProviderCapabilitySlot) -> (any Sendable)? {
        switch slot {
        case .textInference:
            return textInference
        case .cliInferenceBackend:
            return cliInferenceBackends.isEmpty ? nil : cliInferenceBackends as any Sendable
        case .speech:
            return speech
        case .realtimeTranscription:
            return realtimeTranscription
        case .realtimeVoice:
            return realtimeVoice
        case .mediaUnderstanding:
            return mediaUnderstanding
        case .imageGeneration:
            return imageGeneration
        case .videoGeneration:
            return videoGeneration
        case .musicGeneration:
            return musicGeneration
        case .webFetch:
            return webFetch
        case .webSearch:
            return webSearch
        }
    }

    public func registeredSlots() -> Set<ProviderCapabilitySlot> {
        var slots = Set<ProviderCapabilitySlot>()
        if textInference != nil { slots.insert(.textInference) }
        if !cliInferenceBackends.isEmpty { slots.insert(.cliInferenceBackend) }
        if speech != nil { slots.insert(.speech) }
        if realtimeTranscription != nil { slots.insert(.realtimeTranscription) }
        if realtimeVoice != nil { slots.insert(.realtimeVoice) }
        if mediaUnderstanding != nil { slots.insert(.mediaUnderstanding) }
        if imageGeneration != nil { slots.insert(.imageGeneration) }
        if videoGeneration != nil { slots.insert(.videoGeneration) }
        if musicGeneration != nil { slots.insert(.musicGeneration) }
        if webFetch != nil { slots.insert(.webFetch) }
        if webSearch != nil { slots.insert(.webSearch) }
        return slots
    }

    public var registeredCLIBackendIDs: [String] {
        cliInferenceBackends.map(\.cliBackendID)
    }
}

public enum ProviderRegistryError: Error, Equatable, Sendable {
    case notRegistered(ProviderID)
    case slotUnavailable(ProviderCapabilitySlot, providerID: ProviderID)
    case cliBackendNotFound(providerID: ProviderID, cliBackendID: String)
}
