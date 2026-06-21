import Foundation
import Testing
@testable import SwiftAgentHarness

private struct StubSessionBlobHostResolver: SessionBlobHostResolving {
    var addresses: [SessionBlobResolvedAddress]

    func resolve(host: String, port: Int) throws -> [SessionBlobResolvedAddress] {
        addresses
    }
}

private final class RecordingGuardedHTTPTransport: SessionBlobPinnedHTTPTransport, @unchecked Sendable {
    var lastVettedLiteral: String?
    var statusCode = 200

    func get(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        lastVettedLiteral = vettedAddress.hostLiteral
        return SessionBlobHTTPResponse(statusCode: statusCode, headers: [:], body: Data("ok".utf8))
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

private func sockaddrIPv4(_ literal: String, port: UInt16 = 443) -> SessionBlobResolvedAddress {
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    _ = literal.withCString { inet_pton(AF_INET, $0, &sin.sin_addr) }
    let data = withUnsafeBytes(of: &sin) { Data($0) }
    return SessionBlobResolvedAddress(sockaddrData: data, hostLiteral: literal)
}

@Suite("SessionGuardedHTTPClient")
struct SessionGuardedHTTPClientTests {
    @Test func blocksLiteralPrivateIP() {
        let url = URL(string: "http://127.0.0.1/hook")!
        #expect(throws: SessionPersistenceError.self) {
            _ = try SessionGuardedHTTPClient.post(url: url, body: Data("{}".utf8), transport: RecordingGuardedHTTPTransport())
        }
    }

    @Test func blocksHostnameResolvingToPrivateIP() {
        let url = URL(string: "http://metadata.internal/hook")!
        let resolver = StubSessionBlobHostResolver(addresses: [sockaddrIPv4("127.0.0.1", port: 80)])
        #expect(throws: SessionPersistenceError.self) {
            _ = try SessionGuardedHTTPClient.post(
                url: url,
                body: Data("{}".utf8),
                resolver: resolver,
                transport: RecordingGuardedHTTPTransport()
            )
        }
    }

    @Test func postReturnsStatusCodeViaGuardedTransport() throws {
        let url = URL(string: "http://example.com/hook")!
        let resolver = StubSessionBlobHostResolver(addresses: [sockaddrIPv4("93.184.216.34", port: 80)])
        var transport = RecordingGuardedHTTPTransport()
        transport.statusCode = 204
        let response = try SessionGuardedHTTPClient.post(
            url: url,
            body: Data("{}".utf8),
            resolver: resolver,
            transport: transport
        )
        #expect(response.statusCode == 204)
        #expect(transport.lastVettedLiteral == "93.184.216.34")
    }
}

@Suite("WebhookOutboundDelivery")
struct WebhookOutboundDeliveryTests {
    @Test func postUsesGuardedClient() async throws {
        let payload = WebhookOutboundPayload(
            triggerID: "t1",
            routeName: "r1",
            status: .completed,
            text: "done",
            childSessionID: UUID().uuidString
        )
        await #expect(throws: SessionPersistenceError.self) {
            _ = try await WebhookOutboundDelivery.post(urlString: "http://127.0.0.1/hook", payload: payload)
        }
    }
}
