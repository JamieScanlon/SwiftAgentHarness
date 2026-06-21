import CryptoKit
import Foundation

/// Wire resume cursor for ``conversation/{id}/events`` dual replay (harness-style opaque token).
public struct ConversationEventsResumeTokenPayload: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    /// Schema version (currently 1).
    public var v: Int
    /// Conversation the token is bound to.
    public var conv: UUID
    /// Last processed message-stream seq (same semantics as subscribe `sinceMessageSeq`).
    public var msg: Int
    /// Last processed checkpoint-stream seq (`sinceCheckpointSeq`).
    public var chk: Int
    /// Last observed **persisted** transcript head (`latestTranscriptSequence` / envelope `seq` for transcript-backed rows).
    /// Dual subscribe/replay uses `msg` / `chk`; keep `tot` aligned with store head for diagnostics and total-order cursor parity.
    public var tot: Int
    /// UTC expiry (Unix seconds).
    public var exp: Int

    public init(v: Int, conv: UUID, msg: Int, chk: Int, tot: Int, exp: Int) {
        self.v = v
        self.conv = conv
        self.msg = msg
        self.chk = chk
        self.tot = tot
        self.exp = exp
    }
}

public enum ConversationEventsResumeTokenError: Error, Equatable {
    case malformed
    case badVersion
    case badSignature
    case expired
    case conversationMismatch
}

/// HMAC-SHA256 signed resume tokens (`sah.ce.1.<base64 payload>.<base64 sig>`).
public enum ConversationEventsResumeToken {
    public static let prefix = "sah.ce.1."
    /// Default token lifetime for server-minted subscribe handshake tokens.
    public static let defaultTTLSeconds = 86_400

    /// Mint a token. `secret` should be high-entropy (e.g. env `SAH_WS_RESUME_TOKEN_SECRET`).
    public static func mint(payload: ConversationEventsResumeTokenPayload, secret: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        let bodyB64 = base64urlEncode(body)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: padSecret(secret)))
        let sigB64 = base64urlEncode(Data(mac))
        return prefix + bodyB64 + "." + sigB64
    }

    /// Parse and verify. Returns decoded payload when valid.
    public static func parse(
        _ token: String,
        secret: Data,
        conversationID: UUID,
        now: Date = Date()
    ) throws -> ConversationEventsResumeTokenPayload {
        guard token.hasPrefix(prefix) else { throw ConversationEventsResumeTokenError.malformed }
        let rest = token.dropFirst(prefix.count)
        let parts = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { throw ConversationEventsResumeTokenError.malformed }
        let body = try base64urlDecode(parts[0])
        let sig = try base64urlDecode(parts[1])
        let expected = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: padSecret(secret)))
        guard constantTimeEquals(Data(expected), sig) else { throw ConversationEventsResumeTokenError.badSignature }

        let payload = try JSONDecoder().decode(ConversationEventsResumeTokenPayload.self, from: body)
        guard payload.v == ConversationEventsResumeTokenPayload.schemaVersion else { throw ConversationEventsResumeTokenError.badVersion }
        guard payload.conv == conversationID else { throw ConversationEventsResumeTokenError.conversationMismatch }
        let nowEpoch = Int(now.timeIntervalSince1970)
        guard payload.exp >= nowEpoch else { throw ConversationEventsResumeTokenError.expired }
        return payload
    }

    private static func padSecret(_ secret: Data) -> Data {
        // HKDF-style simple stretch for short secrets: hash once to 32-byte key.
        if secret.count >= 32 { return secret }
        return Data(SHA256.hash(data: secret))
    }

    private static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64urlDecode(_ s: String) throws -> Data {
        var base64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = 4 - (base64.count % 4)
        if pad < 4 { base64.append(String(repeating: "=", count: pad)) }
        guard let data = Data(base64Encoded: base64) else { throw ConversationEventsResumeTokenError.malformed }
        return data
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
