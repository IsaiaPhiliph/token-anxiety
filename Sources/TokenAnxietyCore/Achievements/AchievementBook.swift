import Foundation

/// The achievements earned so far (they are never taken back, even when the logs that
/// earned them are gone), the ones not seen yet, and the counters behind the rest.
public struct AchievementBook: Codable, Sendable, Equatable {
    public struct Earned: Codable, Sendable, Equatable {
        /// When each tier was reached, in order.
        public var dates: [Date]
        public var tier: Int { dates.count }
    }

    /// A tier just reached.
    public struct Unlock: Sendable, Equatable {
        public var id: String
        public var tier: Int
    }

    public private(set) var earned: [String: Earned] = [:]
    public private(set) var unseen: Set<String> = []
    /// Set by the first evaluation: what the history earned before is announced together.
    public private(set) var started: Date?
    public var watcher = QuotaWatcher()
    public var app = AppCounters()

    public init() {}

    public func tier(_ id: String) -> Int { earned[id]?.tier ?? 0 }

    public var earnedTiers: Int { earned.values.reduce(0) { $0 + $1.tier } }

    /// Records the tiers `facts` reach; returns the new ones and whether this was the
    /// first evaluation (the history's achievements, to announce as one).
    public mutating func evaluate(_ facts: AchievementFacts, now: Date = Date()) -> (unlocks: [Unlock], first: Bool) {
        let first = started == nil
        if first { started = now }
        var unlocks: [Unlock] = []
        for achievement in AchievementCatalog.all {
            let reached = achievement.tier(for: achievement.value(facts))
            let current = tier(achievement.id)
            guard reached > current else { continue }
            var entry = earned[achievement.id] ?? Earned(dates: [])
            for tier in (current + 1)...reached {
                entry.dates.append(now)
                unlocks.append(Unlock(id: achievement.id, tier: tier))
            }
            earned[achievement.id] = entry
            unseen.insert(achievement.id)
        }
        return (unlocks, first)
    }

    public mutating func markSeen() {
        unseen = []
    }
}
