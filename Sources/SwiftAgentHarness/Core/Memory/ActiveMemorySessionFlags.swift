import Foundation
import EasyJSON
import SwiftAgentKit

/// Conversation-metadata keys for active-memory soft toggles and observability flags.
enum ActiveMemorySessionFlags {
    static let enabledKey = "sah.activeMemory.enabled"
    static let verboseKey = "sah.verbose"
    static let traceKey = "sah.trace"

    /// Absent key ⇒ enabled.
    static func isSessionEnabled(metadata: JSON?) -> Bool {
        boolFlag(metadata: metadata, key: enabledKey, default: true)
    }

    /// Absent key ⇒ off.
    static func isVerbose(metadata: JSON?) -> Bool {
        boolFlag(metadata: metadata, key: verboseKey, default: false)
    }

    /// Absent key ⇒ off.
    static func isTrace(metadata: JSON?) -> Bool {
        boolFlag(metadata: metadata, key: traceKey, default: false)
    }

    static func withSessionEnabled(_ enabled: Bool, metadata: JSON?) -> JSON {
        merging(metadata, key: enabledKey, value: enabled ? "true" : "false")
    }

    static func withVerbose(_ enabled: Bool, metadata: JSON?) -> JSON {
        merging(metadata, key: verboseKey, value: enabled ? "true" : "false")
    }

    static func withTrace(_ enabled: Bool, metadata: JSON?) -> JSON {
        merging(metadata, key: traceKey, value: enabled ? "true" : "false")
    }

    private static func boolFlag(metadata: JSON?, key: String, default defaultValue: Bool) -> Bool {
        guard let metadata, case .object(let object) = metadata, let value = object[key] else {
            return defaultValue
        }
        switch value {
        case .string(let text):
            let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered == "true" || lowered == "1" || lowered == "on" { return true }
            if lowered == "false" || lowered == "0" || lowered == "off" { return false }
            return defaultValue
        case .boolean(let flag):
            return flag
        default:
            return defaultValue
        }
    }

    private static func merging(_ metadata: JSON?, key: String, value: String) -> JSON {
        var object: [String: JSON] = [:]
        if let metadata, case .object(let existing) = metadata {
            object = existing
        }
        object[key] = .string(value)
        return .object(object)
    }
}
