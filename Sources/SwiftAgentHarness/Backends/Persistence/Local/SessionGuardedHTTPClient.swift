//
//  SSRF-guarded outbound HTTP (resolve → vet → pinned connect → redirect re-vet).
//

import Foundation

enum SessionGuardedHTTPClient {
    static let defaultTimeoutSeconds: TimeInterval = 30
    static let defaultMaxResponseBytes = 1_048_576

    static func post(
        url: URL,
        body: Data,
        headers: [String: String] = ["Content-Type": "application/json"],
        maxResponseBytes: Int = defaultMaxResponseBytes,
        maxRedirects: Int = 5,
        resolver: any SessionBlobHostResolving = SessionBlobSystemHostResolver(),
        transport: any SessionBlobPinnedHTTPTransport = SessionBlobNIOHTTPTransport()
    ) throws -> SessionBlobHTTPResponse {
        try request(
            url: url,
            method: .post,
            body: body,
            headers: headers,
            maxResponseBytes: maxResponseBytes,
            maxRedirects: maxRedirects,
            resolver: resolver,
            transport: transport
        )
    }

    static func get(
        url: URL,
        maxResponseBytes: Int = defaultMaxResponseBytes,
        maxRedirects: Int = 5,
        resolver: any SessionBlobHostResolving = SessionBlobSystemHostResolver(),
        transport: any SessionBlobPinnedHTTPTransport = SessionBlobNIOHTTPTransport()
    ) throws -> SessionBlobHTTPResponse {
        try request(
            url: url,
            method: .get,
            body: nil,
            headers: [:],
            maxResponseBytes: maxResponseBytes,
            maxRedirects: maxRedirects,
            resolver: resolver,
            transport: transport
        )
    }

    private enum Method {
        case get
        case post
    }

    private static func request(
        url: URL,
        method: Method,
        body: Data?,
        headers: [String: String],
        maxResponseBytes: Int,
        maxRedirects: Int,
        resolver: any SessionBlobHostResolving,
        transport: any SessionBlobPinnedHTTPTransport
    ) throws -> SessionBlobHTTPResponse {
        var currentURL = url
        var redirects = 0
        while true {
            let vetted = try SessionBlobURLFetchGuard.pickVettedAddress(url: currentURL, resolver: resolver)
            let isHTTPS = currentURL.scheme == "https"
            let response: SessionBlobHTTPResponse
            switch method {
            case .get:
                response = try transport.get(
                    url: currentURL,
                    vettedAddress: vetted,
                    maxBytes: maxResponseBytes,
                    isHTTPS: isHTTPS
                )
            case .post:
                response = try transport.post(
                    url: currentURL,
                    vettedAddress: vetted,
                    body: body ?? Data(),
                    headers: headers,
                    maxBytes: maxResponseBytes,
                    isHTTPS: isHTTPS
                )
            }
            if let next = redirectURL(from: response, base: currentURL) {
                guard redirects < maxRedirects else {
                    throw SessionPersistenceError.transcriptPayloadInvalid(reason: "redirect blocked")
                }
                try SessionBlobURLFetchGuard.validate(url: next)
                currentURL = next
                redirects += 1
                continue
            }
            return response
        }
    }

    private static func redirectURL(from response: SessionBlobHTTPResponse, base: URL) -> URL? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode) else { return nil }
        guard let location = response.headers["location"], !location.isEmpty else { return nil }
        guard let next = URL(string: location, relativeTo: base)?.absoluteURL else { return nil }
        guard next.scheme == "http" || next.scheme == "https" else { return nil }
        return next
    }
}
