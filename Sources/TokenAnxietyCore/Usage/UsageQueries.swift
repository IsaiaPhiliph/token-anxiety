import Foundation

/// The periods the statistics window offers.
public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, quarter, all

    public var id: String { rawValue }

    public var days: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }

    /// From the start of the first day to now; `all` starts with the ledger.
    public func interval(now: Date, calendar: Calendar, firstDate: Date?) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        guard let days else {
            let start = min(firstDate.map { calendar.startOfDay(for: $0) } ?? today, today)
            return DateInterval(start: start, end: max(now, start))
        }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return DateInterval(start: start, end: max(now, start))
    }

    /// The same stretch just before, to compare with; nil for `all`.
    public func previous(now: Date, calendar: Calendar) -> DateInterval? {
        guard let days else { return nil }
        let current = interval(now: now, calendar: calendar, firstDate: nil)
        let start = calendar.date(byAdding: .day, value: -days, to: current.start) ?? current.start
        // The same elapsed time: today until this hour is compared with yesterday until this hour.
        return DateInterval(start: start, end: start.addingTimeInterval(current.duration))
    }
}

/// The four kinds of token, which cost differently.
public enum TokenKind: String, CaseIterable, Identifiable, Sendable {
    case input, output, cacheWrite, cacheRead

    public var id: String { rawValue }
}

public extension TokenCounts {
    func tokens(_ kind: TokenKind) -> Int {
        switch kind {
        case .input: input
        case .output: output
        case .cacheWrite: cacheWrite
        case .cacheRead: cacheRead
        }
    }

    /// Only one kind (web searches go with the output, the turn that made them).
    func only(_ kind: TokenKind) -> TokenCounts {
        switch kind {
        case .input: TokenCounts(input: input)
        case .output: TokenCounts(output: output, reasoning: reasoning, requests: requests, webSearches: webSearches)
        case .cacheWrite: TokenCounts(cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h)
        case .cacheRead: TokenCounts(cacheRead: cacheRead)
        }
    }
}

public extension UsageLedger {
    /// Tokens and cost by kind of token.
    func byKind(in interval: DateInterval? = nil, provider: ProviderID? = nil) -> [TokenKind: UsageTotals] {
        var result: [TokenKind: UsageTotals] = [:]
        for (key, counts) in entries(in: interval, provider: provider) {
            for kind in TokenKind.allCases {
                result[kind, default: UsageTotals()].add(counts.only(kind), model: key.model, tier: key.tier)
            }
        }
        return result
    }

    /// Per local day and kind of token, for stacked charts.
    func dailyByKind(in interval: DateInterval, provider: ProviderID? = nil,
                     calendar: Calendar) -> [Date: [TokenKind: UsageTotals]] {
        var result: [Date: [TokenKind: UsageTotals]] = [:]
        for (key, counts) in entries(in: interval, provider: provider) {
            let day = calendar.startOfDay(for: key.date)
            for kind in TokenKind.allCases where counts.tokens(kind) > 0 || (kind == .output && counts.webSearches > 0) {
                result[day, default: [:]][kind, default: UsageTotals()].add(counts.only(kind), model: key.model, tier: key.tier)
            }
        }
        return result
    }

    /// Totals by hour of the day (0–23, local).
    func byHourOfDay(in interval: DateInterval? = nil, provider: ProviderID? = nil,
                     calendar: Calendar) -> [Int: UsageTotals] {
        grouped(in: interval, provider: provider) { calendar.component(.hour, from: $0.date) }
    }

    /// Totals by weekday (1 = Sunday … 7, as `Calendar` counts) and hour.
    func byWeekdayAndHour(in interval: DateInterval? = nil, provider: ProviderID? = nil,
                          calendar: Calendar) -> [WeekHour: UsageTotals] {
        grouped(in: interval, provider: provider) {
            let parts = calendar.dateComponents([.weekday, .hour], from: $0.date)
            return WeekHour(weekday: parts.weekday ?? 1, hour: parts.hour ?? 0)
        }
    }

    /// Consecutive active days: the run that reaches today (or yesterday, while today
    /// still has time) and the longest ever.
    func streaks(now: Date, provider: ProviderID? = nil, calendar: Calendar) -> (current: Int, longest: Int) {
        let days = activeDays(provider: provider, calendar: calendar)
        guard !days.isEmpty else { return (0, 0) }
        var longest = 0
        var run = 0
        var previous: Date?
        for day in days.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        var current = 0
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        while days.contains(day) {
            current += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return (current, longest)
    }

    /// The `limit` projects with the most tokens in the period; the rest go together as nil.
    func topProjects(in interval: DateInterval?, provider: ProviderID? = nil, limit: Int) -> [String] {
        grouped(in: interval, provider: provider, by: \.project)
            .sorted { $0.value.counts.total > $1.value.counts.total }
            .prefix(limit).map(\.key)
    }

    /// When each project was last used, and in how many sessions.
    func projectActivity(in interval: DateInterval?, provider: ProviderID? = nil) -> [String: (sessions: Int, last: Date)] {
        var result: [String: (sessions: Int, last: Date)] = [:]
        for session in sessions(in: interval, provider: provider) {
            let current = result[session.project]
            result[session.project] = ((current?.sessions ?? 0) + 1, max(current?.last ?? .distantPast, session.end))
        }
        return result
    }
}

public struct WeekHour: Hashable, Sendable {
    public var weekday: Int
    public var hour: Int

    public init(weekday: Int, hour: Int) {
        self.weekday = weekday
        self.hour = hour
    }
}

/// What a plan's weekly window is worth at API prices: the cost of the tokens used since
/// the window began, scaled to 100 %. Only meaningful once a fair share of it is used.
public struct WeekWorth: Sendable, Equatable {
    public var usedPercent: Double
    public var spent: Double
    public var full: Double

    public static func estimate(window: UsageWindow, ledger: UsageLedger, provider: ProviderID,
                                now: Date) -> WeekWorth? {
        guard window.kind == .weekly, window.usedPercent >= 5, let resetsAt = window.resetsAt,
              let duration = window.duration, resetsAt > now else { return nil }
        let start = resetsAt.addingTimeInterval(-duration)
        guard let first = ledger.firstDate, first <= start else { return nil }
        let spent = ledger.totals(in: DateInterval(start: start, end: now), provider: provider).cost
        guard spent > 0 else { return nil }
        return WeekWorth(usedPercent: window.usedPercent, spent: spent, full: spent / (window.usedPercent / 100))
    }
}
