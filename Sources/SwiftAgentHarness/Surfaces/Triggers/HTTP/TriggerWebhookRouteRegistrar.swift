import Foundation
import Logging
import Vapor

struct TriggerWebhookRouteRegistrar: Sendable {
    let routeStore: WebhookRouteStore
    let adapter: WebhookIngressAdapter
    let logger: Logger

    private static let defaultMaxBodyBytes = 1_048_576

    func register(on app: Application) {
        app.get("webhook", "health") { _ async -> Response in
            let body = #"{"status":"ok","platform":"webhook"}"#
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(string: body))
        }

        app.post("webhook", ":name") { [routeStore, adapter, logger] req async throws -> Response in
            let name = req.parameters.get("name") ?? ""
            let maxBytes = (try? routeStore.route(named: name))?.maxBodyBytes ?? Self.defaultMaxBodyBytes
            let body: Data
            do {
                let buffer = try await req.body.collect(max: maxBytes).get()
                if var buf = buffer {
                    body = Data(buffer: buf.readSlice(length: buf.readableBytes) ?? buf)
                } else {
                    body = Data()
                }
            } catch {
                return Response(status: .payloadTooLarge)
            }
            var headers: [String: String] = [:]
            for (key, value) in req.headers {
                headers[key] = value
            }
            let deliveryID = headers["X-GitHub-Delivery"]
                ?? headers["x-github-delivery"]
                ?? headers["X-Request-ID"]
                ?? headers["x-request-id"]
            let ingress = WebhookIngressRequest(
                routeName: name,
                body: body,
                headers: headers,
                deliveryID: deliveryID
            )
            do {
                let result = try await adapter.ingest(ingress)
                var status: HTTPStatus = .ok
                if result.deliverOnlyOutcome != nil, result.deliverOnlyOutcome != .success {
                    status = .badGateway
                }
                var payload: [String: String] = [
                    "status": result.decision.rawValue,
                    "sessionID": result.sessionID?.uuidString ?? "",
                ]
                if let outcome = result.deliverOnlyOutcome {
                    switch outcome {
                    case .success:
                        payload["delivery"] = "success"
                    case .deliveryFailed(let reason):
                        payload["delivery"] = "failed"
                        payload["deliveryReason"] = reason
                    case .targetMissing:
                        payload["delivery"] = "target-missing"
                    }
                }
                let data = try JSONSerialization.data(withJSONObject: payload)
                var responseHeaders = HTTPHeaders()
                responseHeaders.contentType = .json
                return Response(status: status, headers: responseHeaders, body: .init(data: data))
            } catch WebhookValidationFailure.bodyTooLarge {
                return Response(status: .payloadTooLarge)
            } catch WebhookValidationFailure.routeNotFound {
                return Response(status: .notFound)
            } catch WebhookValidationFailure.invalidSignature, WebhookValidationFailure.routeDisabled {
                return Response(status: .unauthorized)
            } catch WebhookValidationFailure.deliverOnlyInvalidTarget {
                return Response(status: .badRequest)
            } catch WebhookValidationFailure.duplicate {
                var responseHeaders = HTTPHeaders()
                responseHeaders.contentType = .json
                return Response(status: .ok, headers: responseHeaders, body: .init(string: #"{"status":"duplicate"}"#))
            } catch WebhookValidationFailure.rateLimited {
                return Response(status: .tooManyRequests)
            } catch {
                logger.warning("webhook_ingest_failed route=\(name) error=\(String(describing: error))")
                return Response(status: .badRequest)
            }
        }
    }
}
