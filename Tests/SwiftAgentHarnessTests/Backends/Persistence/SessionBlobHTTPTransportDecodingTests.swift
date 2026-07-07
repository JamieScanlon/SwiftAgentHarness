import Foundation
@testable import SwiftAgentHarness
import Testing

private final class StubSessionBlobHTTPTransport: @unchecked Sendable, SessionBlobPinnedHTTPTransport {
    let canned: SessionBlobHTTPResponse
    private let lock = NSLock()
    private var _lastMaxBytes: Int?

    init(canned: SessionBlobHTTPResponse) {
        self.canned = canned
    }

    var lastMaxBytes: Int? {
        lock.lock()
        defer { lock.unlock() }
        return _lastMaxBytes
    }

    func get(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        let _ = (url, vettedAddress, isHTTPS)
        lock.lock()
        _lastMaxBytes = maxBytes
        lock.unlock()
        if canned.body.count > maxBytes {
            throw SessionPersistenceError.blobTooLarge(size: canned.body.count, maxBytes: maxBytes)
        }
        return canned
    }

    func post(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        body: Data,
        headers: [String: String],
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        let _ = (url, vettedAddress, body, headers, maxBytes, isHTTPS)
        return canned
    }
}

@Suite("Session blob HTTP transport decoding")
struct SessionBlobHTTPTransportDecodingTests {
    @Test func stubTransportReturnsBinaryBodyWithHeaders() throws {
        let bodyBytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0x00]
        let transport = StubSessionBlobHTTPTransport(
            canned: SessionBlobHTTPResponse(
                statusCode: 200,
                headers: ["Content-Length": "\(bodyBytes.count)"],
                body: Data(bodyBytes)
            )
        )
        let url = URL(string: "https://example.test/blob.bin")!
        let address = SessionBlobResolvedAddress(sockaddrData: Data(), hostLiteral: "127.0.0.1")
        let response = try transport.get(url: url, vettedAddress: address, maxBytes: 64, isHTTPS: true)
        #expect(response.statusCode == 200)
        #expect(Array(response.body) == bodyBytes)
        #expect(response.headers["Content-Length"] == "\(bodyBytes.count)")
    }

    @Test func stubTransportEnforcesMaxBytesBeforeReturningBody() throws {
        let body = Data(repeating: 0xab, count: 32)
        let transport = StubSessionBlobHTTPTransport(
            canned: SessionBlobHTTPResponse(statusCode: 200, headers: [:], body: body)
        )
        let url = URL(string: "https://example.test/large.bin")!
        let address = SessionBlobResolvedAddress(sockaddrData: Data(), hostLiteral: "127.0.0.1")
        #expect(throws: SessionPersistenceError.self) {
            _ = try transport.get(url: url, vettedAddress: address, maxBytes: 16, isHTTPS: true)
        }
        #expect(transport.lastMaxBytes == 16)
    }
}
