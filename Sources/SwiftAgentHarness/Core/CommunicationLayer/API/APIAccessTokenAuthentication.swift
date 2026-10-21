import CryptoKit
import Foundation
import JWTKit
import Vapor

/// HS256 JWT settings for REST/WebSocket authenticated tenancy (`Authorization: Bearer`).
public struct APIAccessTokenAuthenticationSettings: Sendable, Equatable {
    /// Smallest accepted ``hs256Secret`` size in UTF-8 bytes (RFC 7518 §3.2: the HS256 key must be at
    /// least as large as the 256-bit hash output).
    public static let minimumHS256SecretByteCount = 32

    /// Shared secret for verifying harness access JWTs (HS256). Must be at least
    /// ``minimumHS256SecretByteCount`` UTF-8 bytes; shorter secrets authenticate nothing.
    public var hs256Secret: String
    /// When non-nil, JWT `iss` must match.
    public var issuer: String?
    /// When non-nil, JWT `aud` must match.
    public var audience: String?

    public init(hs256Secret: String, issuer: String? = nil, audience: String? = nil) {
        self.hs256Secret = hs256Secret
        self.issuer = issuer
        self.audience = audience
    }

    /// Whether ``hs256Secret`` is long enough to be used for HS256.
    public var meetsMinimumHS256SecretLength: Bool {
        hs256Secret.utf8.count >= Self.minimumHS256SecretByteCount
    }
}

public enum APIAccessTokenValidationError: Error, Equatable, Sendable {
    case validatorNotConfigured
    case missingBearerToken
    case malformedBearerToken
    case invalidToken
    case invalidOwnerSubject
}

/// Validates inbound bearer tokens and resolves the authenticated owner account id.
public protocol APIAccessTokenValidating: Sendable {
    func validatedOwnerAccountID(bearerToken: String) throws -> UUID
}

struct HarnessAPIAccessTokenPayload: JWTPayload {
    var sub: SubjectClaim
    var exp: ExpirationClaim
    var iss: IssuerClaim?
    var aud: AudienceClaim?

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}

private struct DecodedHarnessAccessTokenPayload: Decodable {
    let sub: String
    let exp: TimeInterval
    let iss: String?
    let aud: AudienceValue?

    enum AudienceValue: Decodable {
        case single(String)
        case multiple([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .single(value)
            } else {
                self = .multiple(try container.decode([String].self))
            }
        }

        func contains(_ audience: String) -> Bool {
            switch self {
            case .single(let value):
                return value == audience
            case .multiple(let values):
                return values.contains(audience)
            }
        }
    }
}

public struct JWTAPIAccessTokenValidator: APIAccessTokenValidating {
    let settings: APIAccessTokenAuthenticationSettings

    public init(settings: APIAccessTokenAuthenticationSettings) {
        self.settings = settings
    }

    public func validatedOwnerAccountID(bearerToken: String) throws -> UUID {
        try Self.verify(token: bearerToken, settings: settings)
    }

    static func verify(token: String, settings: APIAccessTokenAuthenticationSettings) throws -> UUID {
        guard settings.meetsMinimumHS256SecretLength else {
            throw APIAccessTokenValidationError.validatorNotConfigured
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw APIAccessTokenValidationError.invalidToken }

        let signedData = Data("\(parts[0]).\(parts[1])".utf8)
        let signature = try base64URLDecode(String(parts[2]))
        let key = SymmetricKey(data: Data(settings.hs256Secret.utf8))
        let expected = HMAC<SHA256>.authenticationCode(for: signedData, using: key)
        guard constantTimeEquals(Data(expected), signature) else {
            throw APIAccessTokenValidationError.invalidToken
        }

        let payloadData = try base64URLDecode(String(parts[1]))
        let decoded = try JSONDecoder().decode(DecodedHarnessAccessTokenPayload.self, from: payloadData)
        let expiry = Date(timeIntervalSince1970: decoded.exp)
        if expiry <= Date() {
            throw APIAccessTokenValidationError.invalidToken
        }
        if let expectedIssuer = settings.issuer {
            guard decoded.iss == expectedIssuer else {
                throw APIAccessTokenValidationError.invalidToken
            }
        }
        if let expectedAudience = settings.audience {
            guard let aud = decoded.aud, aud.contains(expectedAudience) else {
                throw APIAccessTokenValidationError.invalidToken
            }
        }
        guard let owner = UUID(uuidString: decoded.sub) else {
            throw APIAccessTokenValidationError.invalidOwnerSubject
        }
        return owner
    }

    private static func base64URLDecode(_ value: String) throws -> Data {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        guard let data = Data(base64Encoded: base64) else {
            throw APIAccessTokenValidationError.invalidToken
        }
        return data
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}

/// Shared REST/WebSocket authenticated-owner resolution from `Authorization: Bearer` JWT.
enum APISessionAuthenticatedOwnerResolver {
    static func resolve(from headers: HTTPHeaders, validator: (any APIAccessTokenValidating)?) -> UUID? {
        guard let validator else { return nil }
        guard let bearerToken = parseBearerToken(from: headers) else { return nil }
        return try? validator.validatedOwnerAccountID(bearerToken: bearerToken)
    }

    static func parseBearerToken(from headers: HTTPHeaders) -> String? {
        guard let authorization = headers.first(name: .authorization)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !authorization.isEmpty
        else { return nil }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return nil }
        let token = authorization.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

#if DEBUG
/// Test/dev helper for minting harness access JWTs with the same shape as ``JWTAPIAccessTokenValidator``.
public enum HarnessAPIAccessTokenFactory {
    public static func mint(
        ownerAccountID: UUID,
        settings: APIAccessTokenAuthenticationSettings,
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) async throws -> String {
        // JWTKit asserts on undersized HMAC keys; refuse them as the validator would.
        guard settings.meetsMinimumHS256SecretLength else {
            throw APIAccessTokenValidationError.validatorNotConfigured
        }
        var payload = HarnessAPIAccessTokenPayload(
            sub: SubjectClaim(value: ownerAccountID.uuidString),
            exp: ExpirationClaim(value: expiresAt)
        )
        if let issuer = settings.issuer {
            payload.iss = IssuerClaim(value: issuer)
        }
        if let audience = settings.audience {
            payload.aud = AudienceClaim(value: [audience])
        }
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: settings.hs256Secret), digestAlgorithm: .sha256)
        return try await keys.sign(payload)
    }

    public static func authorizationHeaderValue(
        ownerAccountID: UUID,
        settings: APIAccessTokenAuthenticationSettings,
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) async throws -> String {
        let token = try await mint(ownerAccountID: ownerAccountID, settings: settings, expiresAt: expiresAt)
        return "Bearer \(token)"
    }
}
#endif
