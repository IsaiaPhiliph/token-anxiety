import Foundation
import Testing
@testable import TokenAnxietyCore

@Suite struct StatsQueryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    private func day(_ text: String) -> Date { LogLines.date(text)! }

    private func ledger(_ times: [String], model: String = "claude-opus-5-5") -> UsageLedger {
        var ledger = UsageLedger()
        for (index, time) in times.enumerated() {
            ledger.add(UsageEvent(provider: .claude, date: day(time), session: "s\(index % 2)", project: "p\(index % 3)",
                                  model: model, counts: TokenCounts(input: 10, output: 100, cacheWrite5m: 1000,
                                                                     cacheRead: 10_000, requests: 1)))
        }
        return ledger
    }

    @Test func periodsEndNowAndCompareWithTheSameStretchBefore() {
        let now = day("2026-10-22T16:30:00.000Z") // 18:30 in Madrid
        let week = StatsPeriod.week.interval(now: now, calendar: calendar, firstDate: nil)
        #expect(week.start == day("2026-10-15T22:00:00.000Z")) // Oct 16, 00:00 local
        #expect(week.end == now)
        let today = StatsPeriod.today.previous(now: now, calendar: calendar)
        #expect(today?.start == day("2026-10-20T22:00:00.000Z"))
        #expect(today?.duration == StatsPeriod.today.interval(now: now, calendar: calendar, firstDate: nil).duration)
        #expect(StatsPeriod.all.interval(now: now, calendar: calendar, firstDate: day("2026-05-01T10:00:00.000Z")).start
                == day("2026-04-30T22:00:00.000Z"))
    }

    @Test func kindsAddUpToTheTotal() throws {
        let ledger = ledger(["2026-10-20T10:00:00.000Z", "2026-10-21T10:00:00.000Z"])
        let kinds = ledger.byKind()
        let total = ledger.totals()
        #expect(kinds.values.reduce(0) { $0 + $1.counts.total } == total.counts.total)
        #expect(abs(kinds.values.reduce(0) { $0 + $1.cost } - total.cost) < 1e-12)
        #expect(kinds[.cacheRead]?.counts.total == 20_000)
    }

    @Test func countsStreaks() {
        let ledger = ledger(["2026-10-10T10:00:00.000Z", "2026-10-11T10:00:00.000Z", "2026-10-12T10:00:00.000Z",
                             "2026-10-20T10:00:00.000Z", "2026-10-21T10:00:00.000Z"])
        // Today (the 22nd) has nothing yet: the run up to yesterday still counts.
        let streaks = ledger.streaks(now: day("2026-10-22T09:00:00.000Z"), calendar: calendar)
        #expect(streaks.current == 2)
        #expect(streaks.longest == 3)
        #expect(ledger.streaks(now: day("2026-10-24T09:00:00.000Z"), calendar: calendar).current == 0)
    }

    @Test func groupsByLocalHourAndWeekday() {
        let ledger = ledger(["2026-10-19T22:30:00.000Z", "2026-10-20T08:15:00.000Z"]) // Tue 00:30, Tue 10:15
        let hours = ledger.byHourOfDay(calendar: calendar)
        #expect(Set(hours.keys) == [0, 10])
        let grid = ledger.byWeekdayAndHour(calendar: calendar)
        #expect(grid[WeekHour(weekday: 3, hour: 0)]?.counts.requests == 1)
    }

    @Test func weighsTheWeek() throws {
        let now = day("2026-10-22T12:00:00.000Z")
        let ledger = ledger(["2026-10-01T10:00:00.000Z", "2026-10-20T10:00:00.000Z", "2026-10-21T10:00:00.000Z"])
        let window = UsageWindow(id: "seven_day", label: "Week", kind: .weekly, usedPercent: 50,
                                 resetsAt: day("2026-10-25T10:00:00.000Z"), duration: 7 * 86_400)
        let worth = try #require(WeekWorth.estimate(window: window, ledger: ledger, provider: .claude, now: now))
        let spent = ledger.totals(in: DateInterval(start: day("2026-10-18T10:00:00.000Z"), end: now)).cost
        #expect(abs(worth.spent - spent) < 1e-12)
        #expect(abs(worth.full - spent * 2) < 1e-12)
        // A window the history does not cover says nothing.
        #expect(WeekWorth.estimate(window: window, ledger: self.ledger(["2026-10-21T10:00:00.000Z"]),
                                   provider: .claude, now: now) == nil)
    }

    @Test func demoLedgerHasSomethingToShow() {
        let ledger = Demo.ledger(now: day("2026-10-22T12:00:00.000Z"), calendar: calendar)
        #expect(ledger.totals(provider: .claude).counts.requests > 1_000)
        #expect(ledger.totals(provider: .codex).counts.requests > 100)
        #expect(ledger.sessions.values.contains { !$0.agents.isEmpty })
        #expect(ledger == Demo.ledger(now: day("2026-10-22T12:00:00.000Z"), calendar: calendar))
    }
}
