import Foundation
import Testing
@testable import TokenAnxietyCore

private var madrid: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
    calendar.firstWeekday = 2
    return calendar
}

private func at(_ text: String) -> Date { LogLines.date(text)! }

private func snapshot(_ provider: ProviderID = .claude, session: Double, sessionReset: String,
                      week: Double = 10, weekReset: String = "2026-10-25T10:00:00.000Z", at time: String) -> (ProviderSnapshot, Date) {
    let now = at(time)
    return (ProviderSnapshot(provider: provider, windows: [
        UsageWindow(id: "five_hour", label: "", kind: .session, usedPercent: session, resetsAt: at(sessionReset), duration: 5 * 3600),
        UsageWindow(id: "seven_day", label: "", kind: .weekly, usedPercent: week, resetsAt: at(weekReset), duration: 7 * 86_400),
    ], fetchedAt: now), now)
}

@Suite struct QuotaWatcherTests {
    private func feed(_ watcher: inout QuotaWatcher, _ items: [(ProviderSnapshot, Date)], inMenuBar: Bool = true,
                      activeDays: Int = 0) {
        for (snapshot, now) in items {
            watcher.observe(snapshot, inMenuBar: inMenuBar, now: now, calendar: madrid) { _ in activeDays }
        }
    }

    @Test func countsTheMomentsOfAFiveHourWindow() {
        var watcher = QuotaWatcher()
        feed(&watcher, [
            snapshot(session: 60, sessionReset: "2026-10-20T15:00:00.000Z", at: "2026-10-20T12:00:00.000Z"),
            snapshot(session: 100, sessionReset: "2026-10-20T15:00:00.000Z", at: "2026-10-20T13:00:00.000Z"),
            snapshot(session: 100, sessionReset: "2026-10-20T15:00:00.000Z", at: "2026-10-20T14:00:00.000Z"), // same wall
            // Reset while at 100: saved by the bell, and a new window used two minutes later.
            snapshot(session: 3, sessionReset: "2026-10-20T20:00:00.000Z", at: "2026-10-20T15:02:00.000Z"),
            snapshot(session: 97, sessionReset: "2026-10-20T20:00:00.000Z", at: "2026-10-20T19:00:00.000Z"),
            // Ended at 97 % without reaching 100: on the edge, and saved again; used much later.
            snapshot(session: 1, sessionReset: "2026-10-21T02:00:00.000Z", at: "2026-10-20T21:00:00.000Z"),
        ])
        #expect(watcher.counters.limitHits == 1)
        #expect(watcher.counters.savedByTheBell == 2)
        #expect(watcher.counters.onTheEdge == 1)
        #expect(watcher.counters.quickStarts == 1)
    }

    @Test func judgesOnlyWeeksItWatchedWhole() {
        var watcher = QuotaWatcher()
        feed(&watcher, [
            snapshot(session: 0, sessionReset: "2026-10-18T15:00:00.000Z", week: 5, weekReset: "2026-10-25T10:00:00.000Z",
                     at: "2026-10-18T11:00:00.000Z"),
            snapshot(session: 0, sessionReset: "2026-10-18T15:00:00.000Z", week: 93, weekReset: "2026-10-25T10:00:00.000Z",
                     at: "2026-10-25T09:00:00.000Z"),
            snapshot(session: 0, sessionReset: "2026-10-25T15:00:00.000Z", week: 2, weekReset: "2026-11-01T10:00:00.000Z",
                     at: "2026-10-25T11:00:00.000Z"),
            // A calm, busy week…
            snapshot(session: 0, sessionReset: "2026-10-25T15:00:00.000Z", week: 40, weekReset: "2026-11-01T10:00:00.000Z",
                     at: "2026-10-31T11:00:00.000Z"),
            snapshot(session: 0, sessionReset: "2026-11-01T15:00:00.000Z", week: 1, weekReset: "2026-11-08T10:00:00.000Z",
                     at: "2026-11-01T11:00:00.000Z"),
        ], activeDays: 6)
        #expect(watcher.counters.crumblessWeeks == 1)
        #expect(watcher.counters.zenWeeks == 1)

        // A week first seen halfway through says nothing.
        var late = QuotaWatcher()
        feed(&late, [
            snapshot(session: 0, sessionReset: "2026-10-22T15:00:00.000Z", week: 95, at: "2026-10-22T11:00:00.000Z"),
            snapshot(session: 0, sessionReset: "2026-10-25T15:00:00.000Z", week: 1, weekReset: "2026-11-01T10:00:00.000Z",
                     at: "2026-10-25T11:00:00.000Z"),
        ], activeDays: 6)
        #expect(late.counters.crumblessWeeks == 0)
    }

    @Test func spotsTheAnswerAndFourFronts() {
        var watcher = QuotaWatcher()
        feed(&watcher, [snapshot(session: 41.6, sessionReset: "2026-10-20T15:00:00.000Z", at: "2026-10-20T12:00:00.000Z")],
             inMenuBar: false)
        #expect(watcher.counters.answers == 0)
        feed(&watcher, [snapshot(session: 41.6, sessionReset: "2026-10-20T15:00:00.000Z", at: "2026-10-20T12:01:00.000Z")])
        #expect(watcher.counters.answers == 1)

        for provider in ProviderID.allCases {
            feed(&watcher, [snapshot(provider, session: 10, sessionReset: "2026-10-20T15:00:00.000Z", at: "2026-10-20T12:10:00.000Z"),
                            snapshot(provider, session: 20, sessionReset: "2026-10-20T15:00:00.000Z", at: "2026-10-20T12:20:00.000Z")])
        }
        feed(&watcher, [snapshot(session: 50, sessionReset: "2026-10-20T15:00:00.000Z", at: "2026-10-20T12:30:00.000Z")])
        #expect(watcher.counters.fourFrontDays == 1)
    }
}

@Suite struct AchievementTests {
    private func ledger(_ events: [(String, String, Int)]) -> UsageLedger {
        var ledger = UsageLedger()
        for (index, (time, model, tokens)) in events.enumerated() {
            ledger.add(UsageEvent(provider: model.hasPrefix("gpt") ? .codex : .claude, date: at(time), session: "s\(index)",
                                  project: "p", model: model, counts: TokenCounts(output: tokens, requests: 1)))
        }
        return ledger
    }

    @Test func catalogIsWellFormed() {
        let ids = AchievementCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for achievement in AchievementCatalog.all {
            #expect(!achievement.tiers.isEmpty)
            #expect(achievement.tiers == achievement.tiers.sorted())
            #expect(achievement.title != achievement.id)
            #expect(achievement.detail(goal: achievement.tiers[0]) != achievement.unit.format(achievement.tiers[0]))
        }
    }

    @Test func unlocksTiersOnceAndKeepsThem() {
        var book = AchievementBook()
        var facts = AchievementFacts()
        facts.longestStreak = 15
        let first = book.evaluate(facts, now: at("2026-10-20T10:00:00.000Z"))
        #expect(first.first)
        #expect(first.unlocks.filter { $0.id == "on-a-streak" }.map(\.tier) == [1, 2])
        #expect(book.unseen.contains("on-a-streak"))

        book.markSeen()
        facts.longestStreak = 3 // the logs behind it were deleted
        let second = book.evaluate(facts)
        #expect(!second.first)
        #expect(second.unlocks.isEmpty)
        #expect(book.tier("on-a-streak") == 2)

        facts.longestStreak = 40
        #expect(book.evaluate(facts).unlocks == [AchievementBook.Unlock(id: "on-a-streak", tier: 3)])
    }

    @Test func readsHabitsFromTheHistory() {
        var events: [(String, String, Int)] = []
        // Fourteen days in a row, at 10:00 Madrid, then a day off, then back a month later.
        for day in 1...14 { events.append((String(format: "2026-09-%02dT08:00:00.000Z", day), "claude-opus-5-5", 1000)) }
        events.append(("2026-10-20T08:00:00.000Z", "claude-opus-5-5", 1000))
        // A night owl: 20 requests at 3:00 Madrid.
        for _ in 0..<20 { events.append(("2026-10-21T01:10:00.000Z", "claude-sonnet-5-5", 10)) }
        // A Friday evening deploy (Oct 23, 19:00 Madrid).
        events.append(("2026-10-23T17:00:00.000Z", "claude-opus-5-5", 5_000_000))
        // A day of nothing but Haiku.
        for _ in 0..<20 { events.append(("2026-10-24T10:00:00.000Z", "claude-haiku-5-5", 10)) }
        // Claude and Codex the same day.
        events.append(("2026-10-24T11:00:00.000Z", "gpt-5.5", 10))
        let facts = AchievementFacts.compute(ledger: ledger(events), plans: [.claude: "Max 5x"],
                                             now: at("2026-10-25T12:00:00.000Z"), calendar: madrid)
        #expect(facts.longestStreak == 14)
        #expect(facts.grassDays == 1)
        #expect(facts.comebacks == 1)
        #expect(facts.owlNights == 1)
        #expect(facts.fridayEvenings == 1)
        #expect(facts.haikuDays == 0) // the Codex request breaks the Haiku-only day
        #expect(facts.bilingualDays == 1)
        #expect(facts.models == 4)
        #expect(facts.planMultiple > 0)

        var tokyo = facts
        tokyo.familyTokens["Opus"] = 2e9
        var book = AchievementBook()
        _ = book.evaluate(tokyo)
        #expect(book.tier("opus-deep-dive") == 2)
        #expect(book.tier("friday-deploy") == 1)
    }

    @Test func knowsThePlans() {
        #expect(AchievementFacts.planPrice(provider: .claude, plan: "Max 20x") == 200)
        #expect(AchievementFacts.planPrice(provider: .claude, plan: "Max 5x") == 100)
        #expect(AchievementFacts.planPrice(provider: .claude, plan: "Pro") == 20)
        #expect(AchievementFacts.planPrice(provider: .codex, plan: "Plus") == 20)
        #expect(AchievementFacts.planPrice(provider: .codex, plan: "Free") == nil)
    }
}
