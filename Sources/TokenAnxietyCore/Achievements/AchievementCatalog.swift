import Foundation

public enum AchievementCategory: String, CaseIterable, Identifiable, Sendable {
    case volume, habits, variety, feats, money, quota, secret, app

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .volume: String(localized: "Volume")
        case .habits: String(localized: "Habits")
        case .variety: String(localized: "Variety")
        case .feats: String(localized: "Feats")
        case .money: String(localized: "Money (at API prices)")
        case .quota: String(localized: "Living with limits")
        case .secret: String(localized: "Secrets")
        case .app: String(localized: "Token Anxiety")
        }
    }
}

/// How a goal is written: "1B tokens", "30 days", "$100", "×5".
public enum AchievementUnit: Sendable {
    case tokens, count, days, hours, money, multiple

    public func format(_ value: Double) -> String {
        switch self {
        case .tokens: Fmt.tokens(value)
        case .count, .days, .hours: Int(value.rounded(.down)).formatted(.number.locale(Fmt.locale))
        case .money: Fmt.money(value)
        case .multiple: "×" + value.formatted(.number.precision(.fractionLength(0...1)).locale(Fmt.locale))
        }
    }
}

public struct Achievement: Identifiable, Sendable {
    public let id: String
    public let category: AchievementCategory
    public let symbol: String
    /// One goal per tier, rising: bronze, silver, gold, platinum, legendary.
    public let tiers: [Double]
    public let unit: AchievementUnit
    public let secret: Bool
    let metric: @Sendable (AchievementFacts) -> Double

    public func value(_ facts: AchievementFacts) -> Double { metric(facts) }

    /// Tiers reached with this value.
    public func tier(for value: Double) -> Int { tiers.filter { value >= $0 }.count }

    public var isTiered: Bool { tiers.count > 1 }
}

public enum Tier {
    public static func name(_ tier: Int) -> String {
        switch tier {
        case 1: String(localized: "Bronze")
        case 2: String(localized: "Silver")
        case 3: String(localized: "Gold")
        case 4: String(localized: "Platinum")
        default: String(localized: "Legendary")
        }
    }
}

public enum AchievementCatalog {
    private static func make(_ id: String, _ category: AchievementCategory, _ symbol: String, _ tiers: [Double],
                             _ unit: AchievementUnit = .count, secret: Bool = false,
                             _ metric: @escaping @Sendable (AchievementFacts) -> Double) -> Achievement {
        Achievement(id: id, category: category, symbol: symbol, tiers: tiers, unit: unit, secret: secret, metric: metric)
    }

    public static let all: [Achievement] = [
        // Volume
        make("token-club", .volume, "sum", [1e8, 1e9, 1e10, 1e11, 1e12], .tokens) { $0.totalTokens },
        make("opus-deep-dive", .volume, "water.waves", [1e8, 1e9, 1e10], .tokens) { $0.familyTokens["Opus"] ?? 0 },
        make("sonnet-mainstay", .volume, "music.note", [1e8, 1e9, 1e10], .tokens) { $0.familyTokens["Sonnet"] ?? 0 },
        make("haiku-workhorse", .volume, "leaf", [1e7, 1e8, 1e9], .tokens) { $0.familyTokens["Haiku"] ?? 0 },
        make("fable-teller", .volume, "book.closed", [5e7, 5e8, 5e9], .tokens) { $0.familyTokens["Fable"] ?? 0 },
        make("codex-regular", .volume, "chevron.left.forwardslash.chevron.right", [1e7, 1e8, 1e9], .tokens) { $0.familyTokens["GPT"] ?? 0 },
        make("wordsmith", .volume, "text.cursor", [2e6, 2e7, 2e8], .tokens) { $0.outputTokens },
        make("cache-reader", .volume, "memorychip", [1e8, 1e9, 1e10], .tokens) { $0.cacheReadTokens },
        make("cache-builder", .volume, "square.stack.3d.up", [1e7, 1e8, 1e9], .tokens) { $0.cacheWriteTokens },
        // Habits
        make("regular", .habits, "calendar", [30, 100, 365], .days) { $0.activeDays },
        make("on-a-streak", .habits, "flame", [7, 14, 30, 100], .days) { $0.longestStreak },
        make("week-after-week", .habits, "calendar.badge.checkmark", [4, 12, 52]) { $0.activeWeeks },
        make("no-sleep", .habits, "hourglass", [12, 24, 48], .hours) { $0.longestOutputHours },
        make("night-owl", .habits, "moon.stars", [1]) { $0.owlNights },
        make("early-bird", .habits, "sunrise", [5], .days) { $0.earlyDays },
        make("weekend-warrior", .habits, "figure.run", [1]) { $0.fullWeekends },
        make("touch-grass", .habits, "leaf.arrow.triangle.circlepath", [1]) { $0.grassDays },
        // Variety
        make("model-rainbow", .variety, "rainbow", [2, 5, 10]) { $0.models },
        make("family-reunion", .variety, "person.3", [1]) { $0.threeFamilyDays },
        make("bilingual", .variety, "character.bubble", [1, 7, 30], .days) { $0.bilingualDays },
        make("four-fronts", .variety, "square.grid.2x2", [1]) { Double($0.quota.fourFrontDays) },
        make("effort-explorer", .variety, "dial.medium", [3, 5]) { $0.effortLevels },
        make("hive-mind", .variety, "ant", [5, 10, 20]) { $0.mostSubagents },
        make("juggler", .variety, "circle.grid.cross", [3, 5, 8]) { $0.mostProjectsInDay },
        make("branch-hopper", .variety, "arrow.triangle.branch", [5, 10, 20]) { $0.mostBranchesInWeek },
        make("web-surfer", .variety, "globe", [10, 100, 1000]) { $0.webSearches },
        make("full-throttle", .variety, "gauge.with.dots.needle.100percent", [100, 1000, 10000]) { $0.maxEffortRequests },
        // Feats
        make("speedrun", .feats, "bolt", [1e7, 5e7, 2e8], .tokens) { $0.bestHourTokens },
        make("marathon", .feats, "figure.walk.motion", [1, 10]) { $0.marathons },
        make("big-brain", .feats, "brain", [2e5, 5e5, 9e5], .tokens) { $0.peakContext },
        make("cache-me", .feats, "bolt.horizontal.circle", [1, 10], .days) { $0.cacheDays },
        // Money
        make("big-spender", .money, "dollarsign.circle", [100, 1000, 10_000, 100_000], .money) { $0.totalCost },
        make("pricey-week", .money, "calendar.badge.clock", [100, 500, 2500, 10_000, 25_000], .money) { $0.bestWeekCost },
        make("pricey-chat", .money, "bubble.left.and.text.bubble.right", [10, 100, 1000], .money) { $0.bestSessionCost },
        make("plan-pays", .money, "arrow.up.right.circle", [1, 5, 10], .multiple) { $0.planMultiple },
        // Living with limits
        make("hit-the-wall", .quota, "exclamationmark.octagon", [1, 10, 50]) { Double($0.quota.limitHits) },
        make("saved-by-the-bell", .quota, "bell", [1, 10]) { Double($0.quota.savedByTheBell) },
        make("on-the-edge", .quota, "figure.climbing", [1, 10]) { Double($0.quota.onTheEdge) },
        make("not-a-crumb", .quota, "fork.knife", [1, 5]) { Double($0.quota.crumblessWeeks) },
        make("zen-mode", .quota, "figure.mind.and.body", [1, 5]) { Double($0.quota.zenWeeks) },
        make("at-the-door", .quota, "door.left.hand.open", [1, 10]) { Double($0.quota.quickStarts) },
        make("token-anxiety", .quota, "heart.text.square", [30, 100]) { Double($0.app.mostPanelOpens) },
        // Secrets
        make("the-answer", .secret, "42.circle", [1], secret: true) { Double($0.quota.answers) },
        make("friday-deploy", .secret, "shippingbox", [1], secret: true) { $0.fridayEvenings },
        make("happy-new-token", .secret, "sparkles", [1], secret: true) { $0.newYearHours },
        make("poet", .secret, "text.quote", [1], secret: true) { $0.haikuDays },
        make("welcome-back", .secret, "hand.wave", [1], secret: true) { $0.comebacks },
        // The app
        make("tinkerer", .app, "slider.horizontal.3", [3, 6]) { Double($0.app.settingsChanged.count) },
        make("show-off", .app, "square.and.arrow.up", [1]) { Double($0.app.shareExports) },
        make("good-advice", .app, "lightbulb", [1]) { Double($0.app.adviceRatings) },
    ]

    public static func achievement(_ id: String) -> Achievement? { all.first { $0.id == id } }
}

// MARK: Texts

public extension Achievement {
    var title: String {
        switch id {
        case "token-club": String(localized: "Token club")
        case "opus-deep-dive": String(localized: "Opus deep dive")
        case "sonnet-mainstay": String(localized: "Sonnet mainstay")
        case "haiku-workhorse": String(localized: "Haiku workhorse")
        case "fable-teller": String(localized: "Fable teller")
        case "codex-regular": String(localized: "Codex regular")
        case "wordsmith": String(localized: "Wordsmith")
        case "cache-reader": String(localized: "Cache reader")
        case "cache-builder": String(localized: "Cache builder")
        case "regular": String(localized: "Regular")
        case "on-a-streak": String(localized: "On a streak")
        case "week-after-week": String(localized: "Week after week")
        case "no-sleep": String(localized: "Who needs sleep")
        case "night-owl": String(localized: "Night owl")
        case "early-bird": String(localized: "Early bird")
        case "weekend-warrior": String(localized: "Weekend warrior")
        case "touch-grass": String(localized: "Touch grass")
        case "model-rainbow": String(localized: "Model rainbow")
        case "family-reunion": String(localized: "Family reunion")
        case "bilingual": String(localized: "Bilingual")
        case "four-fronts": String(localized: "Four fronts")
        case "effort-explorer": String(localized: "Effort explorer")
        case "hive-mind": String(localized: "Hive mind")
        case "juggler": String(localized: "Juggler")
        case "branch-hopper": String(localized: "Branch hopper")
        case "web-surfer": String(localized: "Web surfer")
        case "full-throttle": String(localized: "Full throttle")
        case "speedrun": String(localized: "Speedrun")
        case "marathon": String(localized: "Marathon")
        case "big-brain": String(localized: "Big brain")
        case "cache-me": String(localized: "Cache me if you can")
        case "big-spender": String(localized: "Big spender (on paper)")
        case "pricey-week": String(localized: "Pricey week")
        case "pricey-chat": String(localized: "Pricey chat")
        case "plan-pays": String(localized: "The plan pays for itself")
        case "hit-the-wall": String(localized: "Hit the wall")
        case "saved-by-the-bell": String(localized: "Saved by the bell")
        case "on-the-edge": String(localized: "Living on the edge")
        case "not-a-crumb": String(localized: "Not a crumb left")
        case "zen-mode": String(localized: "Zen mode")
        case "at-the-door": String(localized: "Waiting at the door")
        case "token-anxiety": String(localized: "Token anxiety")
        case "the-answer": String(localized: "The answer")
        case "friday-deploy": String(localized: "Friday deploy")
        case "happy-new-token": String(localized: "Happy new token")
        case "poet": String(localized: "Poet")
        case "welcome-back": String(localized: "Welcome back")
        case "tinkerer": String(localized: "Tinkerer")
        case "show-off": String(localized: "Show-off")
        case "good-advice": String(localized: "Good advice")
        default: id
        }
    }

    /// What it takes, with the goal of a tier written in.
    func detail(goal: Double) -> String {
        let g = unit.format(goal)
        return switch id {
        case "token-club": String(localized: "Process \(g) tokens in all.")
        case "opus-deep-dive": String(localized: "\(g) tokens with Opus.")
        case "sonnet-mainstay": String(localized: "\(g) tokens with Sonnet.")
        case "haiku-workhorse": String(localized: "\(g) tokens with Haiku.")
        case "fable-teller": String(localized: "\(g) tokens with Fable.")
        case "codex-regular": String(localized: "\(g) tokens with Codex's GPT models.")
        case "wordsmith": String(localized: "\(g) tokens written by the models.")
        case "cache-reader": String(localized: "\(g) tokens read from the cache.")
        case "cache-builder": String(localized: "\(g) tokens written to the cache.")
        case "regular": String(localized: "Use AI on \(g) different days.")
        case "on-a-streak": String(localized: "\(g) days in a row with usage.")
        case "week-after-week": String(localized: "\(g) weeks with three active days or more.")
        case "no-sleep": String(localized: "Output in \(g) hours in a row.")
        case "night-owl": String(localized: "20 requests between 2:00 and 5:00 in one night.")
        case "early-bird": String(localized: "Work between 5:00 and 7:00 on \(g) days.")
        case "weekend-warrior": String(localized: "A million tokens on both Saturday and Sunday of one weekend.")
        case "touch-grass": String(localized: "A whole day off after a streak of 14 days.")
        case "model-rainbow": String(localized: "Use \(g) different models.")
        case "family-reunion": String(localized: "Opus, Sonnet and Haiku (or Fable) on the same day.")
        case "bilingual": String(localized: "Claude and Codex on the same day, \(g) times.")
        case "four-fronts": String(localized: "Claude, Codex, Antigravity and Cursor all move on the same day.")
        case "effort-explorer": String(localized: "Work at \(g) different effort levels.")
        case "hive-mind": String(localized: "\(g) subagents in one session.")
        case "juggler": String(localized: "\(g) projects in one day.")
        case "branch-hopper": String(localized: "\(g) git branches in one week.")
        case "web-surfer": String(localized: "\(g) web searches by Claude.")
        case "full-throttle": String(localized: "\(g) requests at maximum effort.")
        case "speedrun": String(localized: "\(g) tokens in a single hour.")
        case "marathon": String(localized: "Sessions of 8 hours or 1,000 requests: \(g).")
        case "big-brain": String(localized: "A request with \(g) tokens of context.")
        case "cache-me": String(localized: "Days with 10M tokens and 95% from the cache: \(g).")
        case "big-spender": String(localized: "\(g) of usage at API prices.")
        case "pricey-week": String(localized: "\(g) at API prices in one week.")
        case "pricey-chat": String(localized: "\(g) at API prices in one session.")
        case "plan-pays": String(localized: "A month worth \(g) your plan's price at API prices.")
        case "hit-the-wall": String(localized: "Reach 100% of a limit, \(g) times.")
        case "saved-by-the-bell": String(localized: "The 5-hour session resets while you're at 95% or more, \(g) times.")
        case "on-the-edge": String(localized: "End a 5-hour session between 95% and 100% without reaching it, \(g) times.")
        case "not-a-crumb": String(localized: "End a week at 90% or more without ever reaching 100%, \(g) times.")
        case "zen-mode": String(localized: "A whole week under 50% with five active days, \(g) times.")
        case "at-the-door": String(localized: "Start a new 5-hour session within minutes of the reset, \(g) times.")
        case "token-anxiety": String(localized: "Open the panel \(g) times in one day.")
        case "the-answer": String(localized: "The menu bar shows exactly 42%.")
        case "friday-deploy": String(localized: "5M tokens on a Friday after 18:00.")
        case "happy-new-token": String(localized: "Use AI in the first hour of the year.")
        case "poet": String(localized: "A whole day with nothing but Haiku.")
        case "welcome-back": String(localized: "Come back after a month without AI.")
        case "tinkerer": String(localized: "Change \(g) different settings.")
        case "show-off": String(localized: "Export a share card.")
        case "good-advice": String(localized: "Rate a piece of AI advice.")
        default: g
        }
    }
}
