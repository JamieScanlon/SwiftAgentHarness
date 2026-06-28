import Foundation
import SwiftAgentHarness

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
