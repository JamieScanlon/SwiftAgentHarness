import EasyJSON
import SwiftAgentKit

/// Key in ``LLMRequestConfig/additionalParameters``; read by ``OllamaLLM`` / ``LMStudioLLM`` for log correlation.
enum LLMRequestPurposeKey {
    static let requestPurpose = "requestPurpose"
}

enum LLMRequestPurposeReader {
    static func label(from config: LLMRequestConfig) -> String? {
        guard let additionalParameters = config.additionalParameters,
              case .object(let root) = additionalParameters,
              case .string(let purpose) = root[LLMRequestPurposeKey.requestPurpose],
              !purpose.isEmpty
        else {
            return nil
        }
        return purpose
    }

    /// Suffix fragment for log lines, e.g. `", purpose: transform…"` or empty.
    static func logSuffix(from config: LLMRequestConfig) -> String {
        guard let label = label(from: config) else { return "" }
        return ", purpose: \(label)"
    }
}
