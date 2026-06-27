import Foundation

/// Scaffold protocols for non-text provider capability slots (spec: parallel registration).
public protocol SpeechProviding: Sendable {
    var manifest: ProviderManifest { get }
}

public protocol RealtimeTranscriptionProviding: Sendable {
    var manifest: ProviderManifest { get }
}

public protocol RealtimeVoiceProviding: Sendable {
    var manifest: ProviderManifest { get }
}

public protocol MediaUnderstandingProviding: Sendable {
    var manifest: ProviderManifest { get }
}

public protocol ImageGenerationProviding: Sendable {
    var manifest: ProviderManifest { get }
}

public protocol VideoGenerationProviding: Sendable {
    var manifest: ProviderManifest { get }
}

public protocol MusicGenerationProviding: Sendable {
    var manifest: ProviderManifest { get }
}

public protocol WebFetchProviding: Sendable {
    var manifest: ProviderManifest { get }
}

public protocol WebSearchProviding: Sendable {
    var manifest: ProviderManifest { get }
}

public protocol CLIInferenceBackendProviding: Sendable {
    var manifest: ProviderManifest { get }
    var cliBackendID: String { get }
}

public struct StubSpeechProvider: SpeechProviding {
    public let manifest: ProviderManifest
    public init(manifest: ProviderManifest) { self.manifest = manifest }
}

public struct StubRealtimeTranscriptionProvider: RealtimeTranscriptionProviding {
    public let manifest: ProviderManifest
    public init(manifest: ProviderManifest) { self.manifest = manifest }
}

public struct StubRealtimeVoiceProvider: RealtimeVoiceProviding {
    public let manifest: ProviderManifest
    public init(manifest: ProviderManifest) { self.manifest = manifest }
}

public struct StubMediaUnderstandingProvider: MediaUnderstandingProviding {
    public let manifest: ProviderManifest
    public init(manifest: ProviderManifest) { self.manifest = manifest }
}

public struct StubImageGenerationProvider: ImageGenerationProviding {
    public let manifest: ProviderManifest
    public init(manifest: ProviderManifest) { self.manifest = manifest }
}

public struct StubVideoGenerationProvider: VideoGenerationProviding {
    public let manifest: ProviderManifest
    public init(manifest: ProviderManifest) { self.manifest = manifest }
}

public struct StubMusicGenerationProvider: MusicGenerationProviding {
    public let manifest: ProviderManifest
    public init(manifest: ProviderManifest) { self.manifest = manifest }
}

public struct StubWebFetchProvider: WebFetchProviding {
    public let manifest: ProviderManifest
    public init(manifest: ProviderManifest) { self.manifest = manifest }
}

public struct StubWebSearchProvider: WebSearchProviding {
    public let manifest: ProviderManifest
    public init(manifest: ProviderManifest) { self.manifest = manifest }
}

public struct StubCLIInferenceBackendProvider: CLIInferenceBackendProviding {
    public let manifest: ProviderManifest
    public let cliBackendID: String
    public init(manifest: ProviderManifest, cliBackendID: String) {
        self.manifest = manifest
        self.cliBackendID = cliBackendID
    }
}
