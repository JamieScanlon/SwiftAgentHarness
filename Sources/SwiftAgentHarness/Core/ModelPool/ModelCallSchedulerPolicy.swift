import Foundation

public struct ModelCallSchedulerPolicy: Sendable, Equatable {
    public enum FairnessPolicy: Sendable, Equatable {
        case fifo
        case roundRobinByConversation
    }

    public enum BucketScope: Sendable, Equatable {
        case global
        case perCredential
        case perOwner
    }

    public var maxConcurrentPerOwner: Int?

    public var maxConcurrentPerModel: Int?
    public var maxConcurrentPerCredential: Int?
    public var perModelCaps: [UUID: Int]
    public var perCredentialCaps: [String: Int]
    public var requestBucketPerMinute: Int?
    public var tokenBucketPerMinute: Int?
    public var bucketScope: BucketScope
    public var bucketRefillGranularitySeconds: TimeInterval
    public var fairness: FairnessPolicy

    public init(
        maxConcurrentPerModel: Int? = nil,
        maxConcurrentPerCredential: Int? = nil,
        maxConcurrentPerOwner: Int? = nil,
        perModelCaps: [UUID: Int] = [:],
        perCredentialCaps: [String: Int] = [:],
        requestBucketPerMinute: Int? = nil,
        tokenBucketPerMinute: Int? = nil,
        bucketScope: BucketScope = .perCredential,
        bucketRefillGranularitySeconds: TimeInterval = 0.25,
        fairness: FairnessPolicy = .fifo
    ) {
        self.maxConcurrentPerModel = maxConcurrentPerModel.map { max(1, $0) }
        self.maxConcurrentPerCredential = maxConcurrentPerCredential.map { max(1, $0) }
        self.maxConcurrentPerOwner = maxConcurrentPerOwner.map { max(1, $0) }
        self.perModelCaps = perModelCaps.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = max(1, entry.value)
        }
        self.perCredentialCaps = perCredentialCaps.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = max(1, entry.value)
        }
        self.requestBucketPerMinute = requestBucketPerMinute.map { max(1, $0) }
        self.tokenBucketPerMinute = tokenBucketPerMinute.map { max(1, $0) }
        self.bucketScope = bucketScope
        self.bucketRefillGranularitySeconds = max(0.05, bucketRefillGranularitySeconds)
        self.fairness = fairness
    }

    public func applyingStrictTenancyDefaults(maxConcurrent: Int) -> ModelCallSchedulerPolicy {
        var resolved = self
        if resolved.maxConcurrentPerOwner == nil {
            resolved.maxConcurrentPerOwner = max(1, maxConcurrent / 2)
        }
        return resolved
    }
}
