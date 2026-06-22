import Foundation
import OllamaKit
import Testing
@testable import SwiftAgentHarness

struct ModleManagerTests {

    @Test("parseNumCtx extracts num_ctx from parameters string")
    func parseNumCtx() async throws {
        #expect(ModelManager.parseNumCtx(from: "temperature 0.7\nnum_ctx 2048") == 2048)
        #expect(ModelManager.parseNumCtx(from: "num_ctx 4096") == 4096)
        #expect(ModelManager.parseNumCtx(from: "num_ctx  131072") == 131072)
    }

    @Test("parseNumCtx returns nil when num_ctx absent")
    func parseNumCtxMissing() async throws {
        #expect(ModelManager.parseNumCtx(from: "temperature 0.7") == nil)
        #expect(ModelManager.parseNumCtx(from: "") == nil)
    }
    
    /// Decoder matching OllamaKit's (convertFromSnakeCase + date strategy) for decoding OKModelInfoResponse in tests.
    private static var ollamaModelInfoDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        return decoder
    }

    /// Ollama: `vision` = image input (VLM); `image` = image output (generation). Silenia maps those to `LLMCapability.vision` vs `.imageGeneration` in ``ModelManager``.
    @Test("OKModelInfoResponse decodes Ollama vision, image output, and audio capabilities")
    func modelInfoDecodesVisionImageAndAudioCapabilities() throws {
        let json = """
        {
          "modelfile": "",
          "parameters": "",
          "template": "",
          "details": {
            "parent_model": "",
            "format": "gguf",
            "family": "gemma3",
            "parameter_size": "4.0B",
            "quantization_level": "Q4_0",
            "families": ["gemma3"]
          },
          "model_info": {
            "general.architecture": "gemma3",
            "general.file_type": 2,
            "general.parameter_count": 4000000000,
            "general.quantization_version": 2
          },
          "capabilities": ["completion", "vision", "image", "audio", "tools"]
        }
        """
        let data = Data(json.utf8)
        let response = try Self.ollamaModelInfoDecoder.decode(OKModelInfoResponse.self, from: data)
        #expect(response.capabilities.contains(.vision))
        #expect(response.capabilities.contains(.image))
        #expect(response.capabilities.contains(.audio))
        #expect(response.capabilities.contains(.completion))
        #expect(response.capabilities.contains(.tools))
    }
    
    @Test("contextLength(from:) returns context_length from model_info")
    func contextLengthFromModelInfo() throws {
        let json = """
        {
          "modelfile": "",
          "parameters": "temperature 0.7",
          "template": "",
          "details": {
            "parent_model": "",
            "format": "gguf",
            "family": "llama",
            "parameter_size": "8.0B",
            "quantization_level": "Q4_0",
            "families": ["llama"]
          },
          "model_info": {
            "general.architecture": "llama",
            "general.file_type": 2,
            "general.parameter_count": 8030261248,
            "general.quantization_version": 2,
            "llama.context_length": 8192
          },
          "capabilities": ["completion"]
        }
        """
        let data = Data(json.utf8)
        let response = try Self.ollamaModelInfoDecoder.decode(OKModelInfoResponse.self, from: data)
        let ctx = ModelManager.contextLength(from: response)
        #expect(ctx == 8192)
    }
    
    @Test("contextLength(from:) falls back to num_ctx in parameters when model_info has no context_length")
    func contextLengthFallbackToParameters() throws {
        let json = """
        {
          "modelfile": "",
          "parameters": "temperature 0.7\\nnum_ctx 4096",
          "template": "",
          "details": {
            "parent_model": "",
            "format": "gguf",
            "family": "custom",
            "parameter_size": "7B",
            "quantization_level": "Q4_0",
            "families": ["custom"]
          },
          "model_info": {
            "general.architecture": "custom",
            "general.file_type": 2,
            "general.parameter_count": 7000000000,
            "general.quantization_version": 2
          },
          "capabilities": ["completion"]
        }
        """
        let data = Data(json.utf8)
        let response = try Self.ollamaModelInfoDecoder.decode(OKModelInfoResponse.self, from: data)
        let ctx = ModelManager.contextLength(from: response)
        #expect(ctx == 4096)
    }
    
}
