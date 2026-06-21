import Foundation
import NIO
import NIOHTTP1
@testable import SwiftAgentHarness
import Testing

private func sockaddrIPv4(_ literal: String, port: UInt16) -> SessionBlobResolvedAddress {
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    _ = literal.withCString { inet_pton(AF_INET, $0, &sin.sin_addr) }
    let data = withUnsafeBytes(of: &sin) { Data($0) }
    return SessionBlobResolvedAddress(sockaddrData: data, hostLiteral: literal)
}

private final class BinaryBodyHTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let body: [UInt8]
    private let bodyChunkSize: Int
    private var responded = false

    init(body: [UInt8], bodyChunkSize: Int) {
        self.body = body
        self.bodyChunkSize = max(1, bodyChunkSize)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data), !responded else { return }
        responded = true
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(body.count)")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var offset = 0
        while offset < body.count {
            let end = min(offset + bodyChunkSize, body.count)
            var buffer = context.channel.allocator.buffer(capacity: end - offset)
            buffer.writeBytes(body[offset ..< end])
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            offset = end
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private enum LocalBinaryHTTPServer {
    static func start(body: [UInt8], bodyChunkSize: Int) throws -> (port: Int, shutdown: () -> Void) {
        let group = SessionBlobNIORuntime.eventLoopGroup
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(BinaryBodyHTTPServerHandler(body: body, bodyChunkSize: bodyChunkSize))
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        guard let port = channel.localAddress?.port else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "test server bind failed")
        }
        return (port, { _ = channel.close() })
    }
}

@Suite("Session blob pinned HTTP client")
struct SessionBlobPinnedHTTPClientTests {
    @Test func fetchesBinaryBodyWithContentLength() throws {
        let bodyBytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0x00]
        let (port, shutdown) = try LocalBinaryHTTPServer.start(body: bodyBytes, bodyChunkSize: 3)
        defer { shutdown() }

        let transport = SessionBlobNIOHTTPTransport()
        let url = URL(string: "http://127.0.0.1/blob.bin")!
        let response = try transport.get(
            url: url,
            vettedAddress: sockaddrIPv4("127.0.0.1", port: UInt16(port)),
            maxBytes: 64,
            isHTTPS: false
        )
        #expect(response.statusCode == 200)
        #expect(Array(response.body) == bodyBytes)
    }

    @Test func rejectsBodyExceedingMaxBytesMidStream() throws {
        let bodyBytes = Array(repeating: UInt8(0xab), count: 32)
        let (port, shutdown) = try LocalBinaryHTTPServer.start(body: bodyBytes, bodyChunkSize: 8)
        defer { shutdown() }

        let transport = SessionBlobNIOHTTPTransport()
        let url = URL(string: "http://127.0.0.1/large.bin")!
        #expect(throws: SessionPersistenceError.self) {
            _ = try transport.get(
                url: url,
                vettedAddress: sockaddrIPv4("127.0.0.1", port: UInt16(port)),
                maxBytes: 16,
                isHTTPS: false
            )
        }
    }
}
