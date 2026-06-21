import Foundation
@testable import SwiftAgentHarness
import Testing

private struct StubSessionBlobHostResolver: SessionBlobHostResolving {
    var addresses: [SessionBlobResolvedAddress]

    func resolve(host: String, port: Int) throws -> [SessionBlobResolvedAddress] {
        addresses
    }
}

private final class RecordingBlobHTTPTransport: SessionBlobPinnedHTTPTransport, @unchecked Sendable {
    var lastVettedLiteral: String?
    var lastURLHost: String?
    var body = Data("ok".utf8)

    func get(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        lastVettedLiteral = vettedAddress.hostLiteral
        lastURLHost = url.host
        return SessionBlobHTTPResponse(statusCode: 200, headers: [:], body: body)
    }

    func post(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        body: Data,
        headers: [String: String],
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        try get(url: url, vettedAddress: vettedAddress, maxBytes: maxBytes, isHTTPS: isHTTPS)
    }
}

private struct RedirectBlobHTTPTransport: SessionBlobPinnedHTTPTransport, Sendable {
    func get(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        redirectResponse()
    }

    func post(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        body: Data,
        headers: [String: String],
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        redirectResponse()
    }

    private func redirectResponse() -> SessionBlobHTTPResponse {
        SessionBlobHTTPResponse(
            statusCode: 302,
            headers: ["location": "http://169.254.169.254/latest/meta-data"],
            body: Data()
        )
    }
}

private struct OversizeBlobHTTPTransport: SessionBlobPinnedHTTPTransport, Sendable {
    func get(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        oversize(maxBytes: maxBytes)
    }

    func post(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        body: Data,
        headers: [String: String],
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        oversize(maxBytes: maxBytes)
    }

    private func oversize(maxBytes: Int) -> SessionBlobHTTPResponse {
        SessionBlobHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(repeating: 0x41, count: maxBytes + 1)
        )
    }
}

private func sockaddrIPv4(_ literal: String, port: UInt16 = 443) -> SessionBlobResolvedAddress {
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    _ = literal.withCString { inet_pton(AF_INET, $0, &sin.sin_addr) }
    let data = withUnsafeBytes(of: &sin) { Data($0) }
    return SessionBlobResolvedAddress(sockaddrData: data, hostLiteral: literal)
}

@Suite("Session blob URL fetch guard")
struct SessionBlobURLFetchGuardTests {
    @Test func blocksLocalhost() {
        let url = URL(string: "http://127.0.0.1/image.png")!
        do {
            try SessionBlobURLFetchGuard.validate(url: url)
            Issue.record("expected blocked host")
        } catch SessionPersistenceError.transcriptPayloadInvalid {
            #expect(Bool(true))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func blocksMetadataEndpointLiteral() {
        let url = URL(string: "http://169.254.169.254/latest/meta-data")!
        do {
            try SessionBlobURLFetchGuard.validate(url: url)
            Issue.record("expected blocked host")
        } catch SessionPersistenceError.transcriptPayloadInvalid {
            #expect(Bool(true))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func allowsPublicHostWhenNotAllowlisted() throws {
        let url = URL(string: "https://example.com/image.png")!
        try SessionBlobURLFetchGuard.validate(url: url)
    }

    @Test func blocksHostnameResolvingToPrivateIP() {
        let url = URL(string: "https://evil.example/image.png")!
        let resolver = StubSessionBlobHostResolver(addresses: [sockaddrIPv4("127.0.0.1")])
        do {
            _ = try SessionBlobURLFetchGuard.validateResolvedAddresses(url: url, resolver: resolver)
            Issue.record("expected blocked resolved address")
        } catch SessionPersistenceError.transcriptPayloadInvalid {
            #expect(Bool(true))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func validateResolvedAddressesPreservesOriginalHostnameForTLS() throws {
        let url = URL(string: "https://example.com/path?q=1")!
        let resolver = StubSessionBlobHostResolver(addresses: [sockaddrIPv4("93.184.216.34")])
        let validated = try SessionBlobURLFetchGuard.validateResolvedAddresses(url: url, resolver: resolver)
        #expect(validated.host == "example.com")
        #expect(validated.scheme == "https")
        #expect(validated.path == "/path")
    }

    @Test func fetchUsesVettedAddressNotHostnameConnect() throws {
        let url = URL(string: "https://example.com/image.png")!
        let resolver = StubSessionBlobHostResolver(addresses: [sockaddrIPv4("93.184.216.34")])
        let transport = RecordingBlobHTTPTransport()
        let data = try SessionBlobURLFetchGuard.fetchData(
            url: url,
            maxBytes: 1024,
            resolver: resolver,
            transport: transport
        )
        #expect(data == Data("ok".utf8))
        #expect(transport.lastVettedLiteral == "93.184.216.34")
        #expect(transport.lastURLHost == "example.com")
    }

    @Test func fetchRejectsBlockedRedirectTarget() {
        let url = URL(string: "https://evil.example/start")!
        let resolver = StubSessionBlobHostResolver(addresses: [sockaddrIPv4("93.184.216.34")])
        do {
            _ = try SessionBlobURLFetchGuard.fetchData(
                url: url,
                maxBytes: 1024,
                resolver: resolver,
                transport: RedirectBlobHTTPTransport()
            )
            Issue.record("expected blocked redirect")
        } catch SessionPersistenceError.transcriptPayloadInvalid {
            #expect(Bool(true))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func fetchRejectsOversizeBodyFromTransport() {
        let url = URL(string: "https://example.com/big")!
        let resolver = StubSessionBlobHostResolver(addresses: [sockaddrIPv4("93.184.216.34")])
        do {
            _ = try SessionBlobURLFetchGuard.fetchData(
                url: url,
                maxBytes: 8,
                resolver: resolver,
                transport: OversizeBlobHTTPTransport()
            )
            Issue.record("expected blobTooLarge")
        } catch SessionPersistenceError.blobTooLarge {
            #expect(Bool(true))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func fetchDataSucceedsForPublicHTTPSHost() throws {
        let url = URL(string: "https://example.com/")!
        let data = try SessionBlobURLFetchGuard.fetchData(url: url, maxBytes: 512_000)
        #expect(!data.isEmpty)
    }
}
