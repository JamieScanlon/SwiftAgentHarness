//
//  Tests for OAuth callback delivery and GET /oauth/callback route.
//

import Foundation
import Logging
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

// MARK: - OAuthCallbackServer.CallbackResult (contract)

@Suite("OAuth CallbackResult contract")
struct OAuthCallbackResultTests {

    @Test("Success result: code and state set, no error → isSuccess true")
    func callbackResultSuccess() {
        let result = OAuthCallbackServer.CallbackResult(
            authorizationCode: "auth_code_123",
            state: "state_xyz",
            error: nil,
            errorDescription: nil
        )
        #expect(result.isSuccess == true)
        #expect(result.authorizationCode == "auth_code_123")
        #expect(result.state == "state_xyz")
        #expect(result.error == nil)
    }

    @Test("Error result: error set → isSuccess false")
    func callbackResultError() {
        let result = OAuthCallbackServer.CallbackResult(
            authorizationCode: nil,
            state: "state_xyz",
            error: "access_denied",
            errorDescription: "User denied access"
        )
        #expect(result.isSuccess == false)
        #expect(result.authorizationCode == nil)
        #expect(result.error == "access_denied")
        #expect(result.errorDescription == "User denied access")
    }

    @Test("No code, no error → isSuccess false")
    func callbackResultNoCode() {
        let result = OAuthCallbackServer.CallbackResult(
            authorizationCode: nil,
            state: nil,
            error: nil,
            errorDescription: nil
        )
        #expect(result.isSuccess == false)
    }
}

// MARK: - OAuthCallbackDelivery

@Suite("OAuthCallbackDelivery")
struct OAuthCallbackDeliveryTests {

    @Test("Deliver success result to waiting receiver")
    func deliverSuccessToWaiter() async throws {
        let delivery = OAuthCallbackDelivery()
        let resultToDeliver = OAuthCallbackServer.CallbackResult(
            authorizationCode: "code_abc",
            state: "state_123",
            error: nil,
            errorDescription: nil
        )
        async let received: OAuthCallbackServer.CallbackResult = {
            try await delivery.receiver.waitForCallback(timeout: 2.0)
        }()
        try await Task.sleep(for: .milliseconds(50))
        delivery.deliver(result: resultToDeliver)
        let receivedResult = try await received
        #expect(receivedResult.isSuccess == true)
        #expect(receivedResult.authorizationCode == "code_abc")
        #expect(receivedResult.state == "state_123")
    }

    @Test("Deliver error result to waiting receiver")
    func deliverErrorToWaiter() async throws {
        let delivery = OAuthCallbackDelivery()
        let resultToDeliver = OAuthCallbackServer.CallbackResult(
            authorizationCode: nil,
            state: nil,
            error: "access_denied",
            errorDescription: "User denied"
        )
        async let received: OAuthCallbackServer.CallbackResult = {
            try await delivery.receiver.waitForCallback(timeout: 2.0)
        }()
        try await Task.sleep(for: .milliseconds(50))
        delivery.deliver(result: resultToDeliver)
        let receivedResult = try await received
        #expect(receivedResult.isSuccess == false)
        #expect(receivedResult.error == "access_denied")
        #expect(receivedResult.errorDescription == "User denied")
    }

    @Test("Deliver when no waiter does not crash")
    func deliverWithNoWaiter() {
        let delivery = OAuthCallbackDelivery()
        let result = OAuthCallbackServer.CallbackResult(
            authorizationCode: "code",
            state: "state",
            error: nil,
            errorDescription: nil
        )
        delivery.deliver(result: result)
        // No crash; deliver is no-op when no one is waiting
    }

    @Test("Second concurrent waiter throws already in progress")
    func secondWaiterGetsError() async throws {
        let delivery = OAuthCallbackDelivery()
        let firstWaiter = Task {
            try await delivery.receiver.waitForCallback(timeout: 2.0)
        }
        try await Task.sleep(for: .milliseconds(50))
        let secondWaiter = Task {
            try await delivery.receiver.waitForCallback(timeout: 0.3)
        }
        try await Task.sleep(for: .milliseconds(20))
        delivery.deliver(result: OAuthCallbackServer.CallbackResult(
            authorizationCode: "c",
            state: "s",
            error: nil,
            errorDescription: nil
        ))
        let firstResult = try await firstWaiter.value
        #expect(firstResult.isSuccess == true)
        do {
            _ = try await secondWaiter.value
            #expect(Bool(false), "Second waiter should have thrown")
        } catch {
            #expect(String(describing: error).contains("already in progress") || String(describing: error).contains("OAuth"))
        }
    }
}

// MARK: - OAuth callback route (GET /oauth/callback)

@Suite("OAuth callback route")
struct OAuthCallbackRouteTests {

    @Test("GET /oauth/callback with code and state returns 200 and success HTML")
    func oauthCallbackSuccess() async throws {
        let delivery = OAuthCallbackDelivery()
        let logger = Logger(label: "test.oauth")
        try await withApp { app in
            APILayer.registerOAuthCallbackRoute(on: app, delivery: delivery, logger: logger)
            try await app.testing().test(.GET, "/oauth/callback?code=abc123&state=xyz") { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Authentication successful"))
                #expect(res.body.string.contains("Harness"))
            }
        }
    }

    @Test("GET /oauth/callback with error returns 200 and error HTML")
    func oauthCallbackError() async throws {
        let delivery = OAuthCallbackDelivery()
        let logger = Logger(label: "test.oauth")
        try await withApp { app in
            APILayer.registerOAuthCallbackRoute(on: app, delivery: delivery, logger: logger)
            try await app.testing().test(.GET, "/oauth/callback?error=access_denied&error_description=User%20denied") { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Authentication failed"))
                #expect(res.body.string.contains("access_denied") || res.body.string.contains("User denied"))
            }
        }
    }

    @Test("GET /oauth/callback delivers result to waiting receiver")
    func oauthCallbackDeliversToWaiter() async throws {
        let delivery = OAuthCallbackDelivery()
        let logger = Logger(label: "test.oauth")
        var receivedResult: OAuthCallbackServer.CallbackResult?
        try await withApp { app in
            APILayer.registerOAuthCallbackRoute(on: app, delivery: delivery, logger: logger)
            let waiter = Task {
                try await delivery.receiver.waitForCallback(timeout: 3.0)
            }
            try await Task.sleep(for: .milliseconds(50))
            try await app.testing().test(.GET, "/oauth/callback?code=exchanged&state=st") { res in
                #expect(res.status == .ok)
            }
            receivedResult = try await waiter.value
        }
        #expect(receivedResult != nil)
        #expect(receivedResult?.isSuccess == true)
        #expect(receivedResult?.authorizationCode == "exchanged")
        #expect(receivedResult?.state == "st")
    }

    @Test("GET /oauth/callback response has HTML content type")
    func oauthCallbackContentType() async throws {
        let delivery = OAuthCallbackDelivery()
        let logger = Logger(label: "test.oauth")
        try await withApp { app in
            APILayer.registerOAuthCallbackRoute(on: app, delivery: delivery, logger: logger)
            try await app.testing().test(.GET, "/oauth/callback?code=x&state=y") { res in
                #expect(res.status == .ok)
                let contentType = res.headers["Content-Type"].first ?? ""
                #expect(contentType.contains("text/html"))
            }
        }
    }
}
