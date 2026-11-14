import Foundation

/// The host's budget settings for computer-use sessions. The model never sets these: the parent sizes the work in
/// steps, and time and cost limits belong to the host.
public struct ComputerUseBudgetPolicy: Sendable, Codable, Hashable {
    /// The first allotment when the task names none.
    public var defaultSteps: Int
    /// The most steps a session can reach, extensions included.
    public var ceilingSteps: Int
    /// The fraction of the first allotment each extension adds.
    public var extensionShare: Double
    /// Consecutive steps without progress before the session ends.
    public var noProgressSteps: Int
    /// The wall-clock ceiling for one session.
    public var maxDuration: Duration
    /// Never extended automatically.
    public var maxUSD: Double?

    public init(
        defaultSteps: Int = 40,
        ceilingSteps: Int? = nil,
        extensionShare: Double = 0.5,
        noProgressSteps: Int = 8,
        maxDuration: Duration = .seconds(30 * 60),
        maxUSD: Double? = nil
    ) {
        self.defaultSteps = max(1, defaultSteps)
        self.ceilingSteps = max(self.defaultSteps, ceilingSteps ?? 3 * self.defaultSteps)
        self.extensionShare = extensionShare > 0 ? min(1, extensionShare) : 0.5
        self.noProgressSteps = max(1, noProgressSteps)
        self.maxDuration = maxDuration
        self.maxUSD = maxUSD
    }

    /// Combines this policy with a task's request. `maxUSD` may only tighten the host's cap.
    public func resolve(steps: Int?, deadline: Date?, maxUSD: Double? = nil) -> ComputerUseBudgets {
        ComputerUseBudgets(
            steps: min(steps ?? defaultSteps, ceilingSteps),
            ceilingSteps: ceilingSteps,
            extensionShare: extensionShare,
            noProgressSteps: noProgressSteps,
            maxDuration: maxDuration,
            deadline: deadline,
            maxUSD: [self.maxUSD, maxUSD].compactMap { $0 }.min()
        )
    }
}

/// The budgets a lease carries: the host's policy combined with the task's request.
public struct ComputerUseBudgets: Sendable, Codable, Hashable {
    /// The current step allotment. A step is one action delivered to the driver.
    public var steps: Int
    public var ceilingSteps: Int
    public var extensionShare: Double
    public var noProgressSteps: Int
    /// The wall-clock ceiling, measured from when the lease is issued.
    public var maxDuration: Duration
    /// A cutoff the user stated. Never moved.
    public var deadline: Date?
    /// The absolute expiry of an unattended session's grants, measured from when the lease is issued. Never moved.
    public var grantExpiry: Duration?
    public var maxUSD: Double?

    public init(
        steps: Int,
        ceilingSteps: Int? = nil,
        extensionShare: Double = 0.5,
        noProgressSteps: Int = 8,
        maxDuration: Duration,
        deadline: Date? = nil,
        grantExpiry: Duration? = nil,
        maxUSD: Double? = nil
    ) {
        self.steps = max(1, steps)
        self.ceilingSteps = max(self.steps, ceilingSteps ?? self.steps)
        self.extensionShare = extensionShare
        self.noProgressSteps = max(1, noProgressSteps)
        self.maxDuration = maxDuration
        self.deadline = deadline
        self.grantExpiry = grantExpiry
        self.maxUSD = maxUSD
    }

    /// The earliest of the time ceiling, the deadline, and the unattended grant expiry.
    public func endsAt(start: Date) -> Date {
        [
            start.addingTimeInterval(maxDuration.timeInterval),
            deadline,
            grantExpiry.map { start.addingTimeInterval($0.timeInterval) },
        ].compactMap { $0 }.min() ?? start
    }
}
