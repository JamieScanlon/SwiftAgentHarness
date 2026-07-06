//
//  Vocabulary for persisted user-message trust (SwiftAgentKit `Message.inputTrustRaw` / JSON `inputTrust`).
//

import Foundation

/// Runtime policy class resolved from trust vocab/raw values.
public enum TrustPolicyClass: String, Sendable, CaseIterable, Codable {
    case trusted
    case lowTrust = "low_trust"
}

/// Known trust classes for user-originated chat input. The wire and database also allow arbitrary
/// non-empty strings for forward compatibility; use ``sanitizedInputTrustRaw(_:)`` at API boundaries.
public enum MessageInputTrust: String, Sendable, CaseIterable, Codable {
    /// Typed in the first-party UI or otherwise strongly attributed to the end user.
    case directUserEntry = "direct_user_entry"
    /// Automation, scheduled jobs, or non-interactive senders.
    case automation
    /// Scripted or injected content with known provenance.
    case scripted
}

/// Known trust classes for attachment/resource provenance.
public enum AttachmentInputTrust: String, Sendable, CaseIterable, Codable {
    case directUserEntry = "direct_user_entry"
    case automation
    case scripted
}

public enum MessageInputTrustCodec {
    /// Trims whitespace; returns `nil` if empty (caller treats omitted vs invalid).
    public static func sanitizedInputTrustRaw(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func typedTrust(from raw: String?) -> MessageInputTrust? {
        guard let raw = sanitizedInputTrustRaw(raw) else { return nil }
        return MessageInputTrust(rawValue: raw)
    }

    /// Known values map to deterministic classes; unknown non-empty values use the safe fallback.
    public static func safePolicyClass(
        raw: String?,
        unknownFallback: TrustPolicyClass = .lowTrust
    ) -> TrustPolicyClass {
        let sanitized = sanitizedInputTrustRaw(raw)
        guard let sanitized else {
            // Omitted trust remains trusted for backward compatibility.
            return .trusted
        }
        if let originTrustClass = CommEnvelopeTrustTag.executionPolicyClass(forOriginTrustRaw: sanitized) {
            return originTrustClass
        }
        guard let typed = MessageInputTrust(rawValue: sanitized) else {
            return unknownFallback
        }
        switch typed {
        case .directUserEntry:
            return .trusted
        case .automation, .scripted:
            return .lowTrust
        }
    }
}

public enum AttachmentInputTrustCodec {
    /// Trims whitespace; returns `nil` if empty (caller treats omitted vs invalid).
    public static func sanitizedInputTrustRaw(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func typedTrust(from raw: String?) -> AttachmentInputTrust? {
        guard let raw = sanitizedInputTrustRaw(raw) else { return nil }
        return AttachmentInputTrust(rawValue: raw)
    }

    /// Known values map to deterministic classes; unknown non-empty values use the safe fallback.
    public static func safePolicyClass(
        raw: String?,
        unknownFallback: TrustPolicyClass = .lowTrust
    ) -> TrustPolicyClass {
        let sanitized = sanitizedInputTrustRaw(raw)
        guard let sanitized else {
            // Omitted trust remains trusted for backward compatibility.
            return .trusted
        }
        guard let typed = AttachmentInputTrust(rawValue: sanitized) else {
            return unknownFallback
        }
        switch typed {
        case .directUserEntry:
            return .trusted
        case .automation, .scripted:
            return .lowTrust
        }
    }
}
