import Foundation

/// Per-call routing record emitted by every Pool call (spec: `RouteReceipt`).
public struct RouteReceipt: Sendable, Equatable {
    public struct Resolved: Sendable, Equatable {
        public var modelID: String
        public var versionServed: String?
        public var bindingID: String
        public var surface: ContractSurface

        public init(modelID: String, versionServed: String?, bindingID: String, surface: ContractSurface) {
            self.modelID = modelID
            self.versionServed = versionServed
            self.bindingID = bindingID
            self.surface = surface
        }
    }

    public struct AliasResolution: Sendable, Equatable {
        public var alias: String
        public var to: String

        public init(alias: String, to: String) {
            self.alias = alias
            self.to = to
        }
    }

    public struct Tier: Sendable, Equatable {
        public var requested: String?
        public var effective: String?

        public init(requested: String? = nil, effective: String? = nil) {
            self.requested = requested
            self.effective = effective
        }
    }

    public struct RankedOut: Sendable, Equatable {
        public var modelID: String
        public var reason: String

        public init(modelID: String, reason: String) {
            self.modelID = modelID
            self.reason = reason
        }
    }

    public struct Cascade: Sendable, Equatable {
        public var escalated: Bool
        public var reason: String?
        /// Stage-1 answerer when the call escalated. Both stages are billed; latencies add.
        public var firstStage: Resolved?

        public init(escalated: Bool, reason: String? = nil, firstStage: Resolved? = nil) {
            self.escalated = escalated
            self.reason = reason
            self.firstStage = firstStage
        }
    }

    public struct Fallback: Sendable, Equatable {
        public var from: String
        public var reason: ProviderFailoverClassification

        public init(from: String, reason: ProviderFailoverClassification) {
            self.from = from
            self.reason = reason
        }
    }

    /// The decision, its version, and the band it fell in, so an approval can always be explained.
    public struct Decision: Sendable, Equatable {
        public var question: String
        public var verdict: DecisionVerdict
        public var reason: DecisionEvaluation.Reason
        public var modelVersion: String?
        public var value: Double?

        public init(evaluation: DecisionEvaluation, question: String) {
            self.question = question
            self.verdict = evaluation.verdict
            self.reason = evaluation.reason
            self.modelVersion = evaluation.modelVersion
            self.value = evaluation.value
        }
    }

    public var callID: UUID
    /// Owning conversation and run, when the call was made inside one; receipts publish on that conversation's topic.
    public var conversationID: UUID?
    public var runID: UUID?
    public var role: ModelRole?
    public var contract: ModelContract
    /// Role, query hash, or id as asked.
    public var requested: String
    /// `nil` when no candidate answered (the receipt of a failed call).
    public var resolved: Resolved?
    public var aliasResolved: AliasResolution?
    public var tier: Tier
    /// Top few, for "why not X".
    public var rankedOut: [RankedOut]
    public var cascade: Cascade?
    public var fallback: [Fallback]
    /// Rung actually delivered.
    public var guarantee: OutputGuarantee?
    /// `nil` when unknown. Unknown is never zero.
    public var costUSD: Double?
    public var latencyMs: Double
    public var requestIDs: [String]
    public var cacheHit: Bool
    public var decision: Decision?
    public var errorClassification: ProviderFailoverClassification?

    public init(
        callID: UUID = UUID(),
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        role: ModelRole?,
        contract: ModelContract,
        requested: String,
        resolved: Resolved? = nil,
        aliasResolved: AliasResolution? = nil,
        tier: Tier = Tier(),
        rankedOut: [RankedOut] = [],
        cascade: Cascade? = nil,
        fallback: [Fallback] = [],
        guarantee: OutputGuarantee? = nil,
        costUSD: Double? = nil,
        latencyMs: Double = 0,
        requestIDs: [String] = [],
        cacheHit: Bool = false,
        decision: Decision? = nil,
        errorClassification: ProviderFailoverClassification? = nil
    ) {
        self.callID = callID
        self.conversationID = conversationID
        self.runID = runID
        self.role = role
        self.contract = contract
        self.requested = requested
        self.resolved = resolved
        self.aliasResolved = aliasResolved
        self.tier = tier
        self.rankedOut = rankedOut
        self.cascade = cascade
        self.fallback = fallback
        self.guarantee = guarantee
        self.costUSD = costUSD
        self.latencyMs = latencyMs
        self.requestIDs = requestIDs
        self.cacheHit = cacheHit
        self.decision = decision
        self.errorClassification = errorClassification
    }
}

/// Destination for route receipts (observability export, surfaces rendering "answered by X").
public protocol RouteReceiptRecording: Sendable {
    func record(_ receipt: RouteReceipt) async
}

public struct NoOpRouteReceiptRecorder: RouteReceiptRecording {
    public init() {}
    public func record(_ receipt: RouteReceipt) async {}
}

/// Bounded in-memory receipt log.
public actor InMemoryRouteReceiptRecorder: RouteReceiptRecording {
    public private(set) var receipts: [RouteReceipt] = []
    private let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    public func record(_ receipt: RouteReceipt) async {
        receipts.append(receipt)
        if receipts.count > capacity {
            receipts.removeFirst(receipts.count - capacity)
        }
    }
}
