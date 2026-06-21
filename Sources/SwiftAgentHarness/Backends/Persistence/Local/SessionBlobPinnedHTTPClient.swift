//
//  Pinned HTTP GET: connect to a pre-vetted IP while TLS SNI/cert validation use the original hostname.
//

import Foundation
import NIO
import NIOHTTP1
import NIOSSL

struct SessionBlobHTTPResponse: Sendable, Equatable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
}

protocol SessionBlobPinnedHTTPTransport: Sendable {
    func get(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse

    func post(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        body: Data,
        headers: [String: String],
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse
}

enum SessionBlobNIORuntime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var group: MultiThreadedEventLoopGroup?

    static var eventLoopGroup: MultiThreadedEventLoopGroup {
        lock.lock()
        defer { lock.unlock() }
        if let group { return group }
        let created = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        group = created
        return created
    }
}

struct SessionBlobNIOHTTPTransport: SessionBlobPinnedHTTPTransport {
    func get(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        try request(
            url: url,
            vettedAddress: vettedAddress,
            method: .GET,
            body: nil,
            headers: [:],
            maxBytes: maxBytes,
            isHTTPS: isHTTPS
        )
    }

    func post(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        body: Data,
        headers: [String: String],
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        try request(
            url: url,
            vettedAddress: vettedAddress,
            method: .POST,
            body: body,
            headers: headers,
            maxBytes: maxBytes,
            isHTTPS: isHTTPS
        )
    }

    private func request(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        method: HTTPMethod,
        body: Data?,
        headers: [String: String],
        maxBytes: Int,
        isHTTPS: Bool
    ) throws -> SessionBlobHTTPResponse {
        let group = SessionBlobNIORuntime.eventLoopGroup
        return try group.next().flatSubmit {
            SessionBlobPinnedHTTPChannelClient.request(
                url: url,
                vettedAddress: vettedAddress,
                method: method,
                body: body,
                headers: headers,
                maxBytes: maxBytes,
                isHTTPS: isHTTPS,
                on: group.next()
            )
        }.wait()
    }
}

private enum SessionBlobPinnedHTTPChannelClient {
    static func request(
        url: URL,
        vettedAddress: SessionBlobResolvedAddress,
        method: HTTPMethod,
        body: Data?,
        headers: [String: String],
        maxBytes: Int,
        isHTTPS: Bool,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<SessionBlobHTTPResponse> {
        let socketAddress: SocketAddress
        do {
            socketAddress = try SessionBlobSocketAddressConversion.makeSocketAddress(from: vettedAddress.sockaddrData)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        guard let host = url.host, !host.isEmpty else {
            return eventLoop.makeFailedFuture(
                SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url host missing")
            )
        }
        let requestPath = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")

        let group = SessionBlobNIORuntime.eventLoopGroup
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .connectTimeout(.seconds(30))

        let sslContext: NIOSSLContext?
        if isHTTPS {
            do {
                sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        } else {
            sslContext = nil
        }

        let responsePromise = eventLoop.makePromise(of: SessionBlobHTTPResponse.self)

        return bootstrap.channelInitializer { channel in
            let handler = SessionBlobHTTPResponseHandler(maxBytes: maxBytes, promise: responsePromise)
            do {
                if let sslContext {
                    let tls = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    try channel.pipeline.syncOperations.addHandler(tls)
                }
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                try channel.pipeline.syncOperations.addHandler(handler)
                return channel.eventLoop.makeSucceededFuture(())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
        .connect(to: socketAddress)
        .flatMap { channel in
            var httpHeaders = HTTPHeaders()
            httpHeaders.add(name: "Host", value: host)
            httpHeaders.add(name: "Connection", value: "close")
            httpHeaders.add(name: "Accept", value: "*/*")
            for (name, value) in headers {
                httpHeaders.add(name: name, value: value)
            }
            let head = HTTPRequestHead(version: .http1_1, method: method, uri: requestPath, headers: httpHeaders)
            channel.write(HTTPClientRequestPart.head(head), promise: nil)
            if let body, !body.isEmpty {
                var buffer = channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            }
            return channel.writeAndFlush(HTTPClientRequestPart.end(nil)).flatMap {
                responsePromise.futureResult
            }
        }
    }
}

// NIO invokes handlers only on their bound event loop; cross-thread Sendable is satisfied by loop confinement.
private final class SessionBlobHTTPResponseHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    let maxBytes: Int
    let responsePromise: EventLoopPromise<SessionBlobHTTPResponse>
    private var statusCode: Int?
    private var headers: [String: String] = [:]
    private var body = Data()
    private var bodyBytes = 0
    private var completed = false

    init(maxBytes: Int, promise: EventLoopPromise<SessionBlobHTTPResponse>) {
        self.maxBytes = maxBytes
        self.responsePromise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            statusCode = Int(head.status.code)
            headers = Dictionary(uniqueKeysWithValues: head.headers.map { ($0.name.lowercased(), $0.value) })
        case .body(var buffer):
            let chunkSize = buffer.readableBytes
            guard chunkSize > 0 else { return }
            if bodyBytes + chunkSize > maxBytes {
                failTooLarge(context: context, size: bodyBytes + chunkSize)
                return
            }
            guard let chunk = buffer.readBytes(length: chunkSize) else { return }
            body.append(contentsOf: chunk)
            bodyBytes += chunkSize
        case .end:
            guard let statusCode else {
                fail(context: context, reason: "blob url fetch failed")
                return
            }
            completed = true
            responsePromise.succeed(
                SessionBlobHTTPResponse(statusCode: statusCode, headers: headers, body: body)
            )
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        fail(context: context, reason: "blob url fetch incomplete")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed {
            responsePromise.fail(error)
            completed = true
        }
        context.close(promise: nil)
    }

    private func fail(context: ChannelHandlerContext, reason: String) {
        if !completed {
            responsePromise.fail(SessionPersistenceError.transcriptPayloadInvalid(reason: reason))
            completed = true
        }
        context.close(promise: nil)
    }

    private func failTooLarge(context: ChannelHandlerContext, size: Int) {
        if !completed {
            responsePromise.fail(SessionPersistenceError.blobTooLarge(size: size, maxBytes: maxBytes))
            completed = true
        }
        context.close(promise: nil)
    }
}

enum SessionBlobSocketAddressConversion {
    static func makeSocketAddress(from data: Data) throws -> SocketAddress {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url address invalid")
            }
            switch Int32(base.pointee.sa_family) {
            case AF_INET:
                guard data.count >= MemoryLayout<sockaddr_in>.size else {
                    throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url address invalid")
                }
                let sin = raw.bindMemory(to: sockaddr_in.self).first!
                var addr = sin.sin_addr
                let port = Int(UInt16(bigEndian: sin.sin_port))
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url address invalid")
                }
                return try SocketAddress(ipAddress: String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self), port: port)
            case AF_INET6:
                guard data.count >= MemoryLayout<sockaddr_in6>.size else {
                    throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url address invalid")
                }
                let sin6 = raw.bindMemory(to: sockaddr_in6.self).first!
                var addr = sin6.sin6_addr
                let port = Int(UInt16(bigEndian: sin6.sin6_port))
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                    throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url address invalid")
                }
                return try SocketAddress(ipAddress: String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self), port: port)
            default:
                throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url address invalid")
            }
        }
    }
}
