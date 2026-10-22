import Foundation

/// Made-up but plausible figures for `--demo`, screenshots and previews.
public struct DemoProvider: UsageProvider {
    public let id: ProviderID

    public init(_ id: ProviderID) { self.id = id }

    public func isInstalled() async -> Bool { true }

    public func fetch() async throws -> ProviderSnapshot {
        try await Task.sleep(for: .milliseconds(300))
        return Demo.snapshot(for: id)
    }
}

public enum Demo {
    public static func snapshot(for id: ProviderID, now: Date = Date()) -> ProviderSnapshot {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        switch id {
        case .claude:
            return ProviderSnapshot(provider: .claude, plan: "Max 20x", account: "you@example.com", windows: [
                UsageWindow(id: "five_hour", label: String(localized: "Session · 5 h"), kind: .session, usedPercent: 34,
                            resetsAt: now.addingTimeInterval(2 * hour + 14 * 60), duration: 5 * hour),
                UsageWindow(id: "seven_day", label: String(localized: "Week"), kind: .weekly, usedPercent: 66,
                            resetsAt: now.addingTimeInterval(2 * day + 20 * hour), duration: 7 * day),
                UsageWindow(id: "seven_day_opus", label: String(localized: "Week · \("Opus")"), kind: .weeklyModel, usedPercent: 12,
                            resetsAt: now.addingTimeInterval(2 * day + 20 * hour), duration: 7 * day),
                UsageWindow(id: "seven_day_sonnet", label: String(localized: "Week · \("Sonnet")"), kind: .weeklyModel, usedPercent: 3,
                            resetsAt: now.addingTimeInterval(2 * day + 20 * hour), duration: 7 * day),
            ], facts: [Fact(String(localized: "Extra usage"), String(localized: "\(Fmt.percent(8)) of the monthly limit"), symbol: "creditcard")], fetchedAt: now)
        case .codex:
            let days = (0..<7).map { offset in
                DayValue(day: Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(6 - offset) * day)),
                         value: [1.2, 0.4, 2.8, 3.1, 0.0, 1.9, 0.7][offset] * 1_000_000)
            }
            return ProviderSnapshot(provider: .codex, plan: "Plus", account: "you@example.com", windows: [
                UsageWindow(id: "primary", label: String(localized: "Session · 5 h"), kind: .session, usedPercent: 8,
                            resetsAt: now.addingTimeInterval(3 * hour + 50 * 60), duration: 5 * hour),
                UsageWindow(id: "secondary", label: String(localized: "Week"), kind: .weekly, usedPercent: 22,
                            resetsAt: now.addingTimeInterval(5 * day), duration: 7 * day),
            ], facts: [
                Fact(String(localized: "Streak"), String(localized: "\(4) days in a row"), symbol: "flame"),
                Fact(String(localized: "Lifetime tokens"), Fmt.tokens(12_400_000), symbol: "sum"),
            ], dailyTokens: days, fetchedAt: now)
        case .antigravity:
            return ProviderSnapshot(provider: .antigravity, plan: "Google AI Pro", account: "you@example.com", windows: [
                UsageWindow(id: "gemini-pro", label: "Gemini 3 Pro (High)", kind: .model, usedPercent: 45,
                            resetsAt: now.addingTimeInterval(2 * hour), duration: 5 * hour),
                UsageWindow(id: "claude-sonnet", label: "Claude Sonnet 4.5", kind: .model, usedPercent: 80,
                            resetsAt: now.addingTimeInterval(1 * hour + 5 * 60), duration: 5 * hour),
                UsageWindow(id: "gemini-flash", label: "Gemini 3 Flash", kind: .model, usedPercent: 10,
                            resetsAt: now.addingTimeInterval(4 * hour), duration: 5 * hour),
            ], fetchedAt: now)
        case .cursor:
            return ProviderSnapshot(provider: .cursor, plan: "Pro", account: "you@example.com", windows: [
                UsageWindow(id: "plan", label: String(localized: "This month"), kind: .monthly, usedPercent: 41,
                            resetsAt: now.addingTimeInterval(12 * day), duration: 30 * day,
                            detail: String(localized: "\(Fmt.money(8.2)) of \(Fmt.money(20))")),
                UsageWindow(id: "auto", label: String(localized: "Auto and Composer"), kind: .other, usedPercent: 30,
                            resetsAt: now.addingTimeInterval(12 * day), duration: 30 * day),
                UsageWindow(id: "api", label: String(localized: "Selected models"), kind: .other, usedPercent: 52,
                            resetsAt: now.addingTimeInterval(12 * day), duration: 30 * day),
            ], fetchedAt: now)
        }
    }

    /// A week of samples: the weekly figure climbing, sessions coming and going.
    public static func history(now: Date = Date()) -> HistoryLog {
        var log = HistoryLog()
        let start = now.addingTimeInterval(-7 * 86_400)
        var weekly: [ProviderID: Double] = [.claude: 18, .codex: 2]
        var date = start
        var step = 0
        while date < now {
            let hourOfDay = Calendar.current.component(.hour, from: date)
            let working = (9...13).contains(hourOfDay) || (16...23).contains(hourOfDay)
            for provider in [ProviderID.claude, .codex] {
                let speed = provider == .claude ? 0.7 : 0.12
                if working { weekly[provider, default: 0] += speed * Double.random(in: 0.3...1.4) }
                if provider == .claude, step == 136 { weekly[provider] = 2 } // the weekly reset, 4 d 4 h ago
                let phase = Double(hourOfDay % 5) / 5
                let session = working ? min(100, phase * (provider == .claude ? 95 : 30) + Double.random(in: 0...6)) : 0
                var windows = [
                    UsageWindow(id: "s", label: "", kind: .session, usedPercent: session),
                    UsageWindow(id: "w", label: "", kind: .weekly, usedPercent: min(100, weekly[provider] ?? 0)),
                ]
                if date.addingTimeInterval(1800) >= now { windows = Demo.snapshot(for: provider, now: now).windows }
                log.record(ProviderSnapshot(provider: provider, windows: windows, fetchedAt: date))
            }
            date = date.addingTimeInterval(1800)
            step += 1
        }
        return log
    }

    /// Four months of local usage: weekday work with evening spikes, a few projects
    /// and sessions, Claude most days and Codex now and then. The same every time.
    public static func ledger(now: Date = Date(), calendar: Calendar = .current) -> UsageLedger {
        var ledger = UsageLedger()
        var random = SeededRandom(seed: 42)
        let projects = ["token-anxiety", "web-shop", "ml-notebooks", "api-gateway", "dotfiles", "portfolio"]
        let weights = [0.34, 0.24, 0.16, 0.13, 0.05, 0.08]
        let titles = ["Fix the login redirect", "Charts for the stats window", "Refactor the cart", "Write the README",
                      "Speed up the importer", "Flaky test hunt", "Dark mode polish", "Add the webhooks",
                      "Migrate to Swift 6", "Profile the build", "Clean up the CSS", "Rate limit the API"]
        let branches = ["main", "feature/stats", "fix/login", "refactor/cart", "chore/deps"]
        let today = calendar.startOfDay(for: now)
        var sessionNumber = 0
        for offset in stride(from: 119, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            // A few days off, more of them at weekends.
            if random.next() < (weekend ? 0.45 : 0.08) { continue }
            let sessions = weekend ? 1 + Int(random.next() * 2) : 2 + Int(random.next() * 4)
            for _ in 0..<sessions {
                sessionNumber += 1
                let codex = random.next() < 0.18
                let project = pick(projects, weights, random.next())
                let startHour = [9, 10, 11, 12, 15, 16, 17, 18, 21, 22, 23][Int(random.next() * 11)]
                var date = day.addingTimeInterval(Double(startHour) * 3600 + random.next() * 3000)
                guard date < now else { continue }
                let session = "demo-\(sessionNumber)"
                let branch = branches[Int(random.next() * Double(branches.count))]
                let effort = ["medium", "high", "xhigh", "max"][Int(random.next() * 4)]
                let model = codex ? "gpt-5.5" : pick(["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
                                                     [0.72, 0.2, 0.08], random.next())
                let requests = 15 + Int(random.next() * 160)
                var context = 30_000 + random.next() * 40_000
                for request in 0..<requests where date < now {
                    let grow = 2_000 + random.next() * 6_000
                    context = context > 600_000 ? 40_000 : context + grow
                    let counts = codex
                        ? TokenCounts(input: Int(grow), output: 300 + Int(random.next() * 1_500), cacheRead: Int(context),
                                      reasoning: Int(random.next() * 400), requests: 1)
                        : TokenCounts(input: 6, output: 200 + Int(random.next() * 2_400), cacheWrite5m: Int(grow),
                                      cacheRead: Int(context), requests: 1, webSearches: random.next() < 0.02 ? 1 : 0)
                    let agent = !codex && request > 10 && random.next() < 0.12 ? "agent-\(request % 3)" : nil
                    ledger.add(UsageEvent(provider: codex ? .codex : .claude, date: date, session: session, project: project,
                                          branch: codex ? nil : branch, model: model, effort: effort, agent: agent,
                                          entrypoint: codex ? nil : ["claude-desktop", "claude-vscode", "cli"][sessionNumber % 3],
                                          counts: counts))
                    date = date.addingTimeInterval(20 + random.next() * 70)
                }
                ledger.setTitle(titles[sessionNumber % titles.count], provider: codex ? .codex : .claude,
                                session: session, custom: true)
            }
        }
        return ledger
    }

    private static func pick<T>(_ items: [T], _ weights: [Double], _ roll: Double) -> T {
        var total = 0.0
        for (item, weight) in zip(items, weights) {
            total += weight
            if roll < total { return item }
        }
        return items[items.count - 1]
    }
}

/// A small deterministic generator, so the demo looks the same on every launch.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// 0 ..< 1
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
