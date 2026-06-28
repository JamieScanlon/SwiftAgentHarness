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
