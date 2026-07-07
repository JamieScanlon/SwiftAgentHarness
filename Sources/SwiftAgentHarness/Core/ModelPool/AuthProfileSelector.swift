import Foundation

/// Pure credential selection for intra-model auth-profile rotation.
public enum AuthProfileSelector {
    public struct SelectionInput: Sendable {
        public var pool: [AuthProfile]
        public var cooldownStates: [String: AuthProfileCooldownState]
        public var strategy: AuthProfileRotationStrategy
        public var now: Date
        public var excludeIDs: Set<String>
        public var roundRobinCursor: Int
        public var usageCounts: [String: Int]

        public init(
            pool: [AuthProfile],
            cooldownStates: [String: AuthProfileCooldownState] = [:],
            strategy: AuthProfileRotationStrategy = .fillFirst,
            now: Date = Date(),
            excludeIDs: Set<String> = [],
            roundRobinCursor: Int = 0,
            usageCounts: [String: Int] = [:]
        ) {
            self.pool = pool
            self.cooldownStates = cooldownStates
            self.strategy = strategy
            self.now = now
            self.excludeIDs = excludeIDs
            self.roundRobinCursor = roundRobinCursor
            self.usageCounts = usageCounts
        }
    }

    public struct SelectionResult: Sendable, Equatable {
        public var credential: AuthProfile
        public var nextRoundRobinCursor: Int

        public init(credential: AuthProfile, nextRoundRobinCursor: Int) {
            self.credential = credential
            self.nextRoundRobinCursor = nextRoundRobinCursor
        }
    }

    public static func selectNext(_ input: SelectionInput) -> SelectionResult? {
        let available = input.pool.filter { profile in
            !input.excludeIDs.contains(profile.id)
                && (input.cooldownStates[profile.id]?.isAvailable(at: input.now)
                    ?? AuthProfileCooldownState().isAvailable(at: input.now))
        }
        guard !available.isEmpty else { return nil }

        switch input.strategy {
        case .fillFirst:
            guard let first = available.first else { return nil }
            return SelectionResult(credential: first, nextRoundRobinCursor: input.roundRobinCursor)

        case .roundRobin:
            guard !available.isEmpty else { return nil }
            let start = input.roundRobinCursor % available.count
            for offset in 0..<available.count {
                let index = (start + offset) % available.count
                let selected = available[index]
                return SelectionResult(
                    credential: selected,
                    nextRoundRobinCursor: (index + 1) % available.count
                )
            }
            return nil

        case .random:
            guard let selected = available.randomElement() else { return nil }
            return SelectionResult(credential: selected, nextRoundRobinCursor: input.roundRobinCursor)

        case .leastUsed:
            let selected = available.min { lhs, rhs in
                let lhsCount = input.usageCounts[lhs.id, default: 0]
                let rhsCount = input.usageCounts[rhs.id, default: 0]
                if lhsCount != rhsCount { return lhsCount < rhsCount }
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.id < rhs.id
            }
            guard let selected else { return nil }
            return SelectionResult(credential: selected, nextRoundRobinCursor: input.roundRobinCursor)
        }
    }
}
