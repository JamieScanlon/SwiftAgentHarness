import Foundation
import NIOCore
import Vapor

/// Dispatches HTTP requests through a Vapor application's route pipeline without a listen socket.
enum EmbeddedHarnessInProcessHTTP {
    static func perform(
        app: Application,
        method: HTTPMethod,
        path: String,
        headers: HTTPHeaders,
        body: ByteBuffer
    ) async throws -> EmbeddedLoopbackHTTPResponse {
        try await app.asyncBoot()

        var requestHeaders = headers
        requestHeaders.replaceOrAdd(
            name: .contentLength,
            value: body.readableBytes.description
        )

        let eventLoop = app.eventLoopGroup.next()
        let request = Request(
            application: app,
            method: method,
            url: URI(path: path),
            headers: requestHeaders,
            collectedBody: body.readableBytes == 0 ? nil : body,
            remoteAddress: nil,
            logger: app.logger,
            on: eventLoop
        )

        let response = try await app.responder.respond(to: request).get()
        let responseBody = try await response.body.collect(on: eventLoop).get()
            ?? ByteBufferAllocator().buffer(capacity: 0)

        return EmbeddedLoopbackHTTPResponse(
            status: response.status,
            headers: response.headers,
            body: responseBody
        )
    }
}
