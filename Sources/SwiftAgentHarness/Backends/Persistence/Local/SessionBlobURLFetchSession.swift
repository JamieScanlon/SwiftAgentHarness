//
//  SSRF-guarded synchronous URL fetch: resolve+vet once, pinned NIO dial to vetted IP (TLS SNI = hostname).
//

import Foundation

enum SessionBlobURLFetchGuard {
    static func validate(url: URL) throws {
        try validatePreResolve(url: url)
    }

    /// Resolves `url`'s host, rejects blocked addresses, and returns the original URL unchanged (TLS SNI uses this host).
    static func validateResolvedAddresses(
        url: URL,
        resolver: any SessionBlobHostResolving = SessionBlobSystemHostResolver()
    ) throws -> URL {
        _ = try pickVettedAddress(url: url, resolver: resolver)
        return url
    }

    /// Fetches bytes via pinned NIO transport (no connect-time DNS re-resolve).
    static func fetchData(
        url: URL,
        maxBytes: Int,
        resolver: any SessionBlobHostResolving = SessionBlobSystemHostResolver(),
        maxRedirects: Int = 5,
        transport: any SessionBlobPinnedHTTPTransport = SessionBlobNIOHTTPTransport()
    ) throws -> Data {
        var currentURL = url
        var redirects = 0
        while true {
            let vetted = try pickVettedAddress(url: currentURL, resolver: resolver)
            let isHTTPS = currentURL.scheme == "https"
            let response = try transport.get(
                url: currentURL,
                vettedAddress: vetted,
                maxBytes: maxBytes,
                isHTTPS: isHTTPS
            )
            if let next = redirectURL(from: response, base: currentURL) {
                guard redirects < maxRedirects else {
                    throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url redirect blocked")
                }
                try validatePreResolve(url: next)
                currentURL = next
                redirects += 1
                continue
            }
            guard (200 ... 299).contains(response.statusCode) else {
                throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url fetch status \(response.statusCode)")
            }
            guard !response.body.isEmpty else {
                throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url fetch empty")
            }
            guard response.body.count <= maxBytes else {
                throw SessionPersistenceError.blobTooLarge(size: response.body.count, maxBytes: maxBytes)
            }
            return response.body
        }
    }

    static func pickVettedAddress(
        url: URL,
        resolver: any SessionBlobHostResolving
    ) throws -> SessionBlobResolvedAddress {
        try validatePreResolve(url: url)
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url host missing")
        }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let resolved = try resolver.resolve(host: host, port: port)
        for address in resolved where SessionBlockedIPAddress.isBlockedSockaddr(address.sockaddrData) {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url host blocked")
        }
        guard let first = resolved.first else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url host unresolvable")
        }
        return first
    }

    private static func redirectURL(from response: SessionBlobHTTPResponse, base: URL) -> URL? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode) else { return nil }
        guard let location = response.headers["location"], !location.isEmpty else { return nil }
        guard let next = URL(string: location, relativeTo: base)?.absoluteURL else { return nil }
        guard next.scheme == "http" || next.scheme == "https" else { return nil }
        return next
    }

    private static func validatePreResolve(url: URL) throws {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url scheme not allowed")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url host missing")
        }
        if SessionBlockedIPAddress.isBlocked(host: host) {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url host blocked")
        }
        if let allowlist = allowedHosts(), !allowlist.isEmpty, !allowlist.contains(host) {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url host not allowlisted")
        }
    }

    private static func allowedHosts() -> Set<String>? {
        let raw = ProcessInfo.processInfo.environment["SAH_SESSION_BLOB_FETCH_ALLOWED_HOSTS"] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Set(trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }
}
