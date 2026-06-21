import Foundation

public enum ModelState: String, Codable, Sendable {
    case idle
    case loading
    case generating
}

public enum ModelProtocol: String, Codable, Sendable {
    case ollama
    case openAIAPI
    case lmStudio
    case anthropic
}

