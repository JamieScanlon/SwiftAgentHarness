import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP seam so codecs can be tested without the network.
public protocol DecisionHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` transport tuned for ~100 ms stateless reads: a dedicated session (so connections are reused across
/// calls) with a small per-host connection pool. HTTP/2 is negotiated automatically when the server offers it.
public struct URLSessionDecisionTransport: DecisionHTTPTransport {
    private let session: URLSession

    public init(maxConnectionsPerHost: Int = 8, requestTimeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldUsePipelining = false
        self.session = URLSession(configuration: configuration)
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DecisionProviderError.invalidResponse("non-HTTP response")
        }
        return (data, http)
    }
}

/// Jittered exponential backoff with a total time budget across attempts (spec: decision-models § Transport).
/// A gate stuck in retries is worse than a gate that fails conservatively.
public struct DecisionRetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var totalBudget: Duration
    public var baseDelay: Duration
    public var maxDelay: Duration

    public init(
        maxAttempts: Int = 4,
        totalBudget: Duration = .seconds(10),
        baseDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(5)
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.totalBudget = totalBudget
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = DecisionRetryPolicy()
    public static let none = DecisionRetryPolicy(maxAttempts: 1)

    /// Backoff before attempt `attempt + 1` (zero-based `attempt`), with full jitter in `[base/2, cap]`.
    func backoff(afterAttempt attempt: Int, jitter: Double) -> Duration {
        let exponent = min(attempt, 16)
        let raw = baseDelay * (1 << exponent)
        let capped = min(raw, maxDelay)
        let clampedJitter = min(max(jitter, 0), 1)
        let floor = baseDelay / 2
        let span = capped - floor
        return floor + span * clampedJitter
    }
}

/// Runs a request with retries on 408 / 429 / 529 / 5xx and transport errors, honoring `retry-after` and
/// `retry-after-ms`. Calls are stateless reads, so retrying needs no idempotency key.
public struct DecisionRetryExecutor: Sendable {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    public typealias Clock = @Sendable () -> ContinuousClock.Instant
    public typealias Jitter = @Sendable () -> Double

    public var policy: DecisionRetryPolicy
    private let sleep: Sleeper
    private let now: Clock
    private let jitter: Jitter

    public init(
        policy: DecisionRetryPolicy = .default,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        now: @escaping Clock = { ContinuousClock.now },
        jitter: @escaping Jitter = { Double.random(in: 0...1) }
    ) {
        self.policy = policy
        self.sleep = sleep
        self.now = now
        self.jitter = jitter
    }

    public func execute(
        _ request: URLRequest,
        transport: any DecisionHTTPTransport,
        budget: Duration? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let start = now()
        let totalBudget = budget.map { min($0, policy.totalBudget) } ?? policy.totalBudget
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt + 1 < policy.maxAttempts else { throw error }
                let delay = policy.backoff(afterAttempt: attempt, jitter: jitter())
                guard now() - start + delay <= totalBudget else { throw DecisionProviderError.timeBudgetExhausted }
                try await sleep(delay)
                attempt += 1
                continue
            }
            if (200..<300).contains(response.statusCode) {
                return (data, response)
            }
            let error = DecisionProviderError.http(
                status: response.statusCode,
                body: String(decoding: data.prefix(4096), as: UTF8.self),
                requestID: Self.requestID(from: response)
            )
            guard DecisionErrorClassifier.isRetryable(status: response.statusCode),
                  attempt + 1 < policy.maxAttempts
            else { throw error }
            let delay = Self.retryAfter(from: response) ?? policy.backoff(afterAttempt: attempt, jitter: jitter())
            guard now() - start + delay <= totalBudget else { throw error }
            try await sleep(delay)
            attempt += 1
        }
    }

    static func retryAfter(from response: HTTPURLResponse) -> Duration? {
        if let ms = response.value(forHTTPHeaderField: "retry-after-ms"), let value = Double(ms), value >= 0 {
            return .milliseconds(Int(value))
        }
        if let seconds = response.value(forHTTPHeaderField: "retry-after"), let value = Double(seconds), value >= 0 {
            return .milliseconds(Int(value * 1000))
        }
        return nil
    }

    public static func requestID(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "request-id")
            ?? response.value(forHTTPHeaderField: "x-request-id")
            ?? response.value(forHTTPHeaderField: "cf-ray")
    }
}

/// Single-layer gzip for request bodies above ~1 KiB when the server accepts it.
public enum DecisionBodyCompression {
    public static let threshold = 1024

    public static func gzip(_ data: Data) throws -> Data {
        // NSData's `.zlib` algorithm produces raw DEFLATE (RFC 1951); gzip adds a header and CRC/size trailer.
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        output.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}

enum DecisionEndpoint {
    /// Joins `path` onto `base`, collapsing a duplicated `v1` segment (`…/v1` + `v1/systemone`).
    static func url(base: URL, path: String) -> URL {
        var trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if base.path.hasSuffix("/v1") || base.path == "/v1", trimmedPath.hasPrefix("v1/") {
            trimmedPath = String(trimmedPath.dropFirst(3))
        }
        return base.appendingPathComponent(trimmedPath)
    }
}
