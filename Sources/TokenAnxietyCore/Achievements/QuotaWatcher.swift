import Foundation

/// Tallies of quota moments, for the achievements that are about the limits themselves.
public struct QuotaCounters: Codable, Sendable, Equatable {
    /// Windows that reached 100 %.
    public var limitHits = 0
    /// Five-hour windows that reset while at 95 % or more.
    public var savedByTheBell = 0
    /// Five-hour windows that ended between 95 % and 100 % without reaching it.
    public var onTheEdge = 0
    /// Weeks that ended at 90 % or more without ever reaching 100 %.
    public var crumblessWeeks = 0
    /// Weeks under 50 % with five active days or more.
    public var zenWeeks = 0
    /// A new five-hour window used within minutes of the old one ending.
    public var quickStarts = 0
    /// The menu bar showing exactly 42 %.
    public var answers = 0
    /// Days on which all four services' quotas moved.
    public var fourFrontDays = 0

    public init() {}
}

/// Follows each service's five-hour and weekly windows through their cycles and counts
/// the moments above. Fed with every snapshot the app receives.
public struct QuotaWatcher: Codable, Sendable, Equatable {
    struct Cycle: Codable, Sendable, Equatable {
        var resetsAt: Date?
        var duration: TimeInterval?
        var since: Date
        var last: Double
        var peak: Double
        var hitLimit: Bool
    }

    public private(set) var counters = QuotaCounters()
    private var cycles: [String: Cycle] = [:]
    private var day = ""
    private var movedToday: Set<String> = []
    private var countedToday = false

    public init() {}

    /// - Parameters:
    ///   - inMenuBar: whether the service's figures are in the menu bar (for 42 %).
    ///   - activeDays: how many days had usage in an interval, from the local history.
    public mutating func observe(_ snapshot: ProviderSnapshot, inMenuBar: Bool, now: Date = Date(),
                                 calendar: Calendar = .current, activeDays: (DateInterval) -> Int = { _ in 0 }) {
        let today = Self.dayKey(now, calendar: calendar)
        if today != day {
            day = today
            movedToday = []
            countedToday = false
        }
        for window in snapshot.windows where window.kind == .session || window.kind == .weekly {
            let key = "\(snapshot.provider.rawValue).\(window.id)"
            let used = window.usedPercent
            if var cycle = cycles[key] {
                let moved = { () -> Bool in
                    guard let before = cycle.resetsAt, let after = window.resetsAt else { return false }
                    return after.timeIntervalSince(before) > 600
                }()
                if moved || used + 25 < cycle.last {
                    close(cycle, kind: window.kind, activeDays: activeDays)
                    // The new window was used within minutes of the old one ending.
                    if window.kind == .session, used > 0, let end = cycle.resetsAt,
                       now >= end, now.timeIntervalSince(end) < 5 * 60 {
                        counters.quickStarts += 1
                    }
                    cycle = Cycle(resetsAt: window.resetsAt, duration: window.duration, since: now, last: used, peak: used,
                                  hitLimit: false)
                } else if used > cycle.last {
                    movedToday.insert(snapshot.provider.rawValue)
                }
                if used >= 100 && !cycle.hitLimit {
                    cycle.hitLimit = true
                    counters.limitHits += 1
                }
                cycle.last = used
                cycle.peak = max(cycle.peak, used)
                cycle.resetsAt = window.resetsAt ?? cycle.resetsAt
                cycles[key] = cycle
            } else {
                cycles[key] = Cycle(resetsAt: window.resetsAt, duration: window.duration, since: now, last: used,
                                    peak: used, hitLimit: used >= 100)
                if used >= 100 { counters.limitHits += 1 }
            }
        }
        if inMenuBar, [snapshot.primary, snapshot.secondary].contains(where: { $0.map { Int($0.usedPercent.rounded()) == 42 } == true }) {
            counters.answers += 1
        }
        if movedToday.count >= ProviderID.allCases.count && !countedToday {
            countedToday = true
            counters.fourFrontDays += 1
        }
    }

    private mutating func close(_ cycle: Cycle, kind: WindowKind, activeDays: (DateInterval) -> Int) {
        switch kind {
        case .session:
            if cycle.last >= 95 { counters.savedByTheBell += 1 }
            if cycle.peak >= 95, !cycle.hitLimit { counters.onTheEdge += 1 }
        case .weekly:
            // Only a week watched from (nearly) its start says how it went.
            guard let end = cycle.resetsAt, let duration = cycle.duration,
                  cycle.since <= end.addingTimeInterval(-duration + 86_400) else { return }
            if cycle.peak >= 90, !cycle.hitLimit { counters.crumblessWeeks += 1 }
            if cycle.peak < 50, activeDays(DateInterval(start: end.addingTimeInterval(-duration), end: end)) >= 5 {
                counters.zenWeeks += 1
            }
        default:
            break
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
