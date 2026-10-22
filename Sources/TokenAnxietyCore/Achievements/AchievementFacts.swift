import Foundation

/// Everything the achievements are judged on, worked out from the usage history,
/// the quota watcher and the app's own counters.
public struct AchievementFacts: Sendable, Equatable {
    // Volume
    public var totalTokens = 0.0
    public var familyTokens: [String: Double] = [:]
    public var outputTokens = 0.0
    public var cacheReadTokens = 0.0
    public var cacheWriteTokens = 0.0
    // Habits
    public var activeDays = 0.0
    public var longestStreak = 0.0
    public var activeWeeks = 0.0
    public var longestOutputHours = 0.0
    public var owlNights = 0.0
    public var earlyDays = 0.0
    public var fullWeekends = 0.0
    public var grassDays = 0.0
    // Variety
    public var models = 0.0
    public var threeFamilyDays = 0.0
    public var bilingualDays = 0.0
    public var effortLevels = 0.0
    public var mostSubagents = 0.0
    public var mostProjectsInDay = 0.0
    public var mostBranchesInWeek = 0.0
    public var webSearches = 0.0
    public var maxEffortRequests = 0.0
    // Feats
    public var bestHourTokens = 0.0
    public var marathons = 0.0
    public var peakContext = 0.0
    public var cacheDays = 0.0
    // Money (API prices)
    public var totalCost = 0.0
    public var bestWeekCost = 0.0
    public var bestSessionCost = 0.0
    /// The best calendar month's cost over the plan's price, for the best service.
    public var planMultiple = 0.0
    // Secrets
    public var fridayEvenings = 0.0
    public var newYearHours = 0.0
    public var haikuDays = 0.0
    public var comebacks = 0.0
    // Watched, not read from logs
    public var quota = QuotaCounters()
    public var app = AppCounters()

    public init() {}

    /// Monthly prices of the plans the services report, in dollars.
    public static func planPrice(provider: ProviderID, plan: String?) -> Double? {
        guard let plan = plan?.lowercased() else { return nil }
        switch provider {
        case .claude:
            if plan.contains("20x") { return 200 }
            if plan.contains("5x") || plan.contains("max") { return 100 }
            if plan.contains("pro") { return 20 }
        case .codex:
            if plan.contains("pro") && !plan.contains("lite") { return 200 }
            if plan.contains("plus") { return 20 }
        default:
            break
        }
        return nil
    }

    public static func compute(ledger: UsageLedger, plans: [ProviderID: String] = [:], quota: QuotaCounters = .init(),
                               app: AppCounters = .init(), now: Date = Date(), calendar: Calendar = .current) -> AchievementFacts {
        var facts = AchievementFacts()
        facts.quota = quota
        facts.app = app

        struct Day {
            var tokens = 0
            var requests = 0
            var counts = TokenCounts()
            var providers = Set<ProviderID>()
            var families = Set<String>()
            var haikuOnly = true
            var projects = Set<String>()
        }
        var days: [Date: Day] = [:]
        var hours: [Int: Int] = [:]
        var outputHours = Set<Int>()
        var models = Set<String>()
        var efforts = Set<String>()
        var owl: [Date: Int] = [:]
        var early = Set<Date>()
        var friday: [Date: Int] = [:]
        var weeks: [Date: Double] = [:]
        var months: [ProviderID: [Date: Double]] = [:]

        for (key, counts) in ledger.buckets {
            let date = key.date
            let day = calendar.startOfDay(for: date)
            let hour = calendar.component(.hour, from: date)
            var totals = UsageTotals()
            totals.add(counts, model: key.model, tier: key.tier)
            let family = ModelNames.family(key.model)

            facts.totalTokens += Double(counts.total)
            if let family { facts.familyTokens[family, default: 0] += Double(counts.total) }
            facts.outputTokens += Double(counts.output)
            facts.cacheReadTokens += Double(counts.cacheRead)
            facts.cacheWriteTokens += Double(counts.cacheWrite)
            facts.webSearches += Double(counts.webSearches)
            facts.totalCost += totals.cost
            if key.effort == "max" { facts.maxEffortRequests += Double(counts.requests) }
            if !key.effort.isEmpty { efforts.insert(key.effort) }
            if key.model != "unknown" { models.insert(Pricing.canonical(key.model)) }

            var entry = days[day] ?? Day()
            entry.tokens += counts.total
            entry.requests += counts.requests
            entry.counts += counts
            if counts.requests > 0 {
                entry.providers.insert(key.provider)
                if key.provider == .claude, let family { entry.families.insert(family) }
                if family != "Haiku" { entry.haikuOnly = false }
                if key.project != ProjectNames.unknown { entry.projects.insert(key.project) }
            }
            days[day] = entry

            hours[key.hour, default: 0] += counts.total
            if counts.output > 0 { outputHours.insert(key.hour) }
            if (2..<5).contains(hour) { owl[day, default: 0] += counts.requests }
            if (5..<7).contains(hour), counts.requests > 0 { early.insert(day) }
            if calendar.component(.weekday, from: date) == 6, hour >= 18 { friday[day, default: 0] += counts.total }
            if calendar.component(.month, from: date) == 1, calendar.component(.day, from: date) == 1, hour == 0,
               counts.requests > 0 {
                facts.newYearHours += 1
            }
            if let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start { weeks[week, default: 0] += totals.cost }
            if let month = calendar.dateInterval(of: .month, for: date)?.start {
                months[key.provider, default: [:]][month, default: 0] += totals.cost
            }
        }

        // Days
        let active = days.filter { $0.value.requests > 0 }
        facts.activeDays = Double(active.count)
        facts.longestStreak = Double(ledger.streaks(now: now, calendar: calendar).longest)
        var weekDays: [Date: Int] = [:]
        for day in active.keys {
            if let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start { weekDays[week, default: 0] += 1 }
        }
        facts.activeWeeks = Double(weekDays.values.filter { $0 >= 3 }.count)
        facts.owlNights = Double(owl.values.filter { $0 >= 20 }.count)
        facts.earlyDays = Double(early.count)
        facts.threeFamilyDays = Double(active.values.filter { $0.families.count >= 3 }.count)
        facts.bilingualDays = Double(active.values.filter { $0.providers.contains(.claude) && $0.providers.contains(.codex) }.count)
        facts.mostProjectsInDay = Double(active.values.map(\.projects.count).max() ?? 0)
        facts.cacheDays = Double(active.values.filter { $0.tokens >= 10_000_000 && ($0.counts.cacheHitRate ?? 0) >= 0.95 }.count)
        facts.haikuDays = Double(active.values.filter { $0.haikuOnly && $0.requests >= 20 }.count)
        facts.fridayEvenings = Double(friday.values.filter { $0 >= 5_000_000 }.count)
        for (day, entry) in active where calendar.component(.weekday, from: day) == 7 && entry.tokens >= 1_000_000 {
            if let sunday = calendar.date(byAdding: .day, value: 1, to: day), (days[sunday]?.tokens ?? 0) >= 1_000_000 {
                facts.fullWeekends += 1
            }
        }

        // Runs and gaps between active days
        let sorted = active.keys.sorted()
        let today = calendar.startOfDay(for: now)
        var run = 0
        for (index, day) in sorted.enumerated() {
            if index > 0, calendar.date(byAdding: .day, value: 1, to: sorted[index - 1]) == day {
                run += 1
            } else {
                run = 1
            }
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let rested = next < today && !active.keys.contains(next)
            if run >= 14 && rested { facts.grassDays += 1 }
            if index > 0, let gap = calendar.dateComponents([.day], from: sorted[index - 1], to: day).day, gap > 30 {
                facts.comebacks += 1
            }
        }

        // Hours
        facts.bestHourTokens = Double(hours.values.max() ?? 0)
        var longest = 0
        var current = 0
        var previous: Int?
        for hour in outputHours.sorted() {
            current = previous.map { $0 + 1 == hour } == true ? current + 1 : 1
            longest = max(longest, current)
            previous = hour
        }
        facts.longestOutputHours = Double(longest)

        // Sessions
        var branchWeeks: [Date: Set<String>] = [:]
        for session in ledger.sessions.values {
            let totals = session.totals
            facts.mostSubagents = max(facts.mostSubagents, Double(session.agents.count))
            facts.peakContext = max(facts.peakContext, Double(session.peakContext))
            facts.bestSessionCost = max(facts.bestSessionCost, totals.cost)
            let requests = totals.counts.requests
            if requests >= 1000 || (session.duration >= 8 * 3600 && requests >= 300) { facts.marathons += 1 }
            if let week = calendar.dateInterval(of: .weekOfYear, for: session.start)?.start {
                branchWeeks[week, default: []].formUnion(session.branches.keys)
            }
        }
        facts.mostBranchesInWeek = Double(branchWeeks.values.map(\.count).max() ?? 0)

        facts.models = Double(models.count)
        facts.effortLevels = Double(efforts.count)
        facts.bestWeekCost = weeks.values.max() ?? 0
        for (provider, byMonth) in months {
            guard let price = planPrice(provider: provider, plan: plans[provider]) else { continue }
            facts.planMultiple = max(facts.planMultiple, (byMonth.values.max() ?? 0) / price)
        }
        return facts
    }
}

/// Counted by the app as it runs: things the logs do not say.
public struct AppCounters: Codable, Sendable, Equatable {
    public var panelOpensDay: String = ""
    public var panelOpensToday = 0
    public var mostPanelOpens = 0
    public var settingsChanged: Set<String> = []
    public var shareExports = 0
    public var adviceRatings = 0

    public init() {}

    public mutating func panelOpened(now: Date = Date(), calendar: Calendar = .current) {
        let day = QuotaWatcher.dayKey(now, calendar: calendar)
        if day != panelOpensDay {
            panelOpensDay = day
            panelOpensToday = 0
        }
        panelOpensToday += 1
        mostPanelOpens = max(mostPanelOpens, panelOpensToday)
    }
}
