import EasyJSON
import Foundation

enum AnthropicPromptCacheWire {
    static func systemPayload(systemText: String, additionalParameters: JSON?) -> Any {
        guard let cacheControlType = cacheControlType(from: additionalParameters),
              includesStableSystemBreakpoint(from: additionalParameters)
        else {
            return systemText
        }

        let stable = SystemPromptStablePrefixAnalyzer.stablePrefixText(in: systemText)
        guard !stable.isEmpty else { return systemText }

        let volatile = SystemPromptStablePrefixAnalyzer.volatileSuffixText(in: systemText)
        let stableBlock: [String: Any] = [
            "type": "text",
            "text": stable,
            "cache_control": ["type": cacheControlType],
        ]
        if volatile.isEmpty {
            return [stableBlock]
        }
        return [
            stableBlock,
            ["type": "text", "text": volatile],
        ]
    }

    private static func cacheControlType(from additionalParameters: JSON?) -> String? {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              case .string(let mode)? = root[PromptCacheKnobKey.mode]
        else { return nil }
        switch mode {
        case "ephemeral":
            return "ephemeral"
        case "persistent":
            return "persistent"
        default:
            return nil
        }
    }

    private static func includesStableSystemBreakpoint(from additionalParameters: JSON?) -> Bool {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              case .array(let entries)? = root[PromptCacheKnobKey.breakpoints]
        else { return false }
        return entries.contains { entry in
            guard case .object(let object) = entry,
                  case .string(let kind)? = object["kind"]
            else { return false }
            return kind == PromptCacheBreakpointKind.stableSystemPrefixEnd.rawValue
        }
    }
}
