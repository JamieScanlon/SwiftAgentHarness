import Foundation

/// Parallel capability registration slots for provider plugins (spec: capability scope).
public enum ProviderCapabilitySlot: String, Sendable, Codable, CaseIterable, Hashable {
    case textInference = "text-inference"
    case cliInferenceBackend = "cli-inference-backend"
    case speech
    case realtimeTranscription = "realtime-transcription"
    case realtimeVoice = "realtime-voice"
    case mediaUnderstanding = "media-understanding"
    case imageGeneration = "image-generation"
    case videoGeneration = "video-generation"
    case musicGeneration = "music-generation"
    case webFetch = "web-fetch"
    case webSearch = "web-search"
}
