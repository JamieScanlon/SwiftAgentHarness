//
//  Delivers OAuth callback (code/state/error) from the HTTP route to the waiting
//  SwiftAgentKit manual OAuth flow so it can exchange the code for a token.
//

import Foundation
import Logging
import SwiftAgentKit

/// Delivers the OAuth redirect result from our HTTP callback route to whoever is
/// waiting (e.g. MCPOAuthHandler's manual flow). Use one instance per server lifecycle;
/// set it on APILayer and pass `receiver` when creating an OAuth handler that supports
/// a custom `OAuthCallbackReceiver` (see SwiftAgentKit).
/// Use of @unchecked Sendable is valid here
public final class OAuthCallbackDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OAuthCallbackServer.CallbackResult, Error>?
    private var waitGeneration: UInt64 = 0
    private let logger: Logger

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "OAuthCallbackDelivery")
    }

    /// Call this from the HTTP route when the browser hits /oauth/callback?code=... (or error).
    public func deliver(result: OAuthCallbackServer.CallbackResult) {
        lock.lock()
        let cont = continuation
        continuation = nil
        if cont != nil {
            waitGeneration &+= 1
        }
        lock.unlock()
        if let cont = cont {
            cont.resume(returning: result)
            logger.debug(
                "Delivered OAuth callback result to waiting flow (success: \(result.isSuccess), hadCode: \(result.authorizationCode != nil))"
            )
        } else {
            logger.debug("OAuth callback received but no flow is waiting (ignored)")
        }
    }

    /// Returns an `OAuthCallbackReceiver` that suspends in `waitForCallback` until
    /// `deliver(result:)` is called (e.g. from our Vapor route). Use this when creating
    /// an OAuth handler so the manual flow uses our server instead of starting its own.
    public var receiver: any OAuthCallbackReceiver {
        VaporOAuthCallbackReceiver(delivery: self)
    }
}

/// Receiver that waits on `OAuthCallbackDelivery` instead of starting a separate HTTP server.
private final class VaporOAuthCallbackReceiver: OAuthCallbackReceiver {
    private let delivery: OAuthCallbackDelivery

    init(delivery: OAuthCallbackDelivery) {
        self.delivery = delivery
    }

    func waitForCallback(timeout: TimeInterval) async throws -> OAuthCallbackServer.CallbackResult {
        try await withCheckedThrowingContinuation { continuation in
            delivery.storeContinuation(continuation, timeout: timeout)
        }
    }
}

// MARK: - Internal continuation handling

extension OAuthCallbackDelivery {
    fileprivate func storeContinuation(_ cont: CheckedContinuation<OAuthCallbackServer.CallbackResult, Error>, timeout: TimeInterval) {
        lock.lock()
        if continuation == nil {
            waitGeneration &+= 1
            let generation = waitGeneration
            continuation = cont
            lock.unlock()
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                resumeWithTimeoutIfNeeded(generation: generation)
            }
        } else {
            lock.unlock()
            cont.resume(throwing: OAuthError.networkError("OAuth callback already in progress"))
        }
    }

    fileprivate func resumeWithTimeoutIfNeeded(generation: UInt64) {
        lock.lock()
        guard generation == waitGeneration, let cont = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        waitGeneration &+= 1
        lock.unlock()
        cont.resume(throwing: OAuthError.networkError("OAuth callback timeout"))
    }
}
