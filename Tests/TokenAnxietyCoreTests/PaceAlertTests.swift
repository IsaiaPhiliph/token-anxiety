import Foundation
import Testing
@testable import TokenAnxietyCore

private let day: TimeInterval = 86_400

private func weekly(_ used: Double, resetsIn remaining: TimeInterval, now: Date) -> UsageWindow {
    UsageWindow(id: "seven_day", label: "Week", kind: .weekly, usedPercent: used,
                resetsAt: now.addingTimeInterval(remaining), duration: 7 * day)
}

@Suite struct PaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func runsOutBeforeTheReset() throws {
        // Four days in, 66 % spent: 16.5 points a day, 100 % in about two days.
        let pace = try #require(Pace.evaluate(weekly(66, resetsIn: 3 * day, now: now), now: now))
        #expect(abs(pace.expectedPercent - 400.0 / 7) < 0.01)
        guard case .runsOut(let date) = pace.verdict else { Issue.record("expected runsOut"); return }
        #expect(abs(date.timeIntervalSince(now) - 34.0 / 66 * 4 * day) < 1)
        #expect(pace.deltaText == "+9 pts")
    }

    @Test func relaxedWhenWellBelow() throws {
        let pace = try #require(Pace.evaluate(weekly(20, resetsIn: 3 * day, now: now), now: now))
        #expect(pace.verdict == .relaxed)
        #expect(pace.projectedPercent < 100)
    }

    @Test func noVerdictInTheFirstHours() {
        #expect(Pace.evaluate(weekly(10, resetsIn: 7 * day - 3600, now: now), now: now) == nil)
    }

    @Test func exhaustedAtOneHundred() throws {
        let pace = try #require(Pace.evaluate(weekly(100, resetsIn: day, now: now), now: now))
        #expect(pace.verdict == .exhausted)
    }
}

@Suite struct AlertTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ used: Double, resetsIn remaining: TimeInterval) -> ProviderSnapshot {
        ProviderSnapshot(provider: .claude, windows: [weekly(used, resetsIn: remaining, now: now)], fetchedAt: now)
    }

    @Test func eachThresholdOncePerCycle() {
        var tracker = AlertTracker()
        #expect(tracker.events(for: snapshot(50, resetsIn: 3 * day), thresholds: [80, 95], notifyRenewals: true, now: now).isEmpty)
        let first = tracker.events(for: snapshot(82, resetsIn: 3 * day), thresholds: [80, 95], notifyRenewals: true, now: now)
        #expect(first.map(\.kind) == [.threshold(80)])
        #expect(tracker.events(for: snapshot(85, resetsIn: 3 * day - 60), thresholds: [80, 95], notifyRenewals: true, now: now).isEmpty)
        // Jumping past both thresholds at once only sends the higher one.
        #expect(tracker.events(for: snapshot(100, resetsIn: 3 * day - 120), thresholds: [80, 95], notifyRenewals: true, now: now)
            .map(\.kind) == [.exhausted])
    }

    @Test func renewalAfterANearlySpentWindow() {
        var tracker = AlertTracker()
        _ = tracker.events(for: snapshot(97, resetsIn: 600), thresholds: [80, 95], notifyRenewals: true, now: now)
        let events = tracker.events(for: snapshot(2, resetsIn: 7 * day), thresholds: [80, 95], notifyRenewals: true, now: now)
        #expect(events.map(\.kind) == [.renewed])
        // The new cycle starts clean: 80 % notifies again.
        #expect(tracker.events(for: snapshot(81, resetsIn: 5 * day), thresholds: [80, 95], notifyRenewals: true, now: now)
            .map(\.kind) == [.threshold(80)])
    }

    /// Tests run without the app bundle, so they see the English source texts.
    @Test func copy() throws {
        var tracker = AlertTracker()
        let event = try #require(tracker.events(for: snapshot(96, resetsIn: 3600), thresholds: [80, 95],
                                                notifyRenewals: true, now: now).first)
        #expect(event.title == "Claude: 95% of the week")
        #expect(event.body.hasPrefix("Ration your tokens."))
    }
}

@Suite struct HistoryTests {
    @Test func spacesUnchangedSamples() {
        var log = HistoryLog()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func record(_ minutes: Double, _ used: Double) -> Bool {
            log.record(ProviderSnapshot(provider: .codex, windows: [
                UsageWindow(id: "s", label: "", kind: .session, usedPercent: used),
            ], fetchedAt: start.addingTimeInterval(minutes * 60)))
        }
        #expect(record(0, 10))
        #expect(!record(2, 10)) // same figure, two minutes later
        #expect(record(4, 12)) // it moved
        #expect(record(20, 12)) // unchanged, but ten minutes passed
        #expect(log.samples(for: .codex, since: start).count == 3)
    }
}

@Suite struct FormattingTests {
    @Test func durations() {
        #expect(Fmt.duration(2 * 3600 + 14 * 60) == "2 h 14 min")
        #expect(Fmt.duration(45 * 60) == "45 min")
        #expect(Fmt.duration(20) == "less than 1 min")
        #expect(Fmt.duration(day + 3 * 3600) == "1 day and 3 h")
        #expect(Fmt.duration(3 * day) == "3 days")
    }

    @Test func plansAndTokens() {
        #expect(Fmt.planName("pro_plus") == "Pro Plus")
        #expect(Fmt.planName("max_20x") == "Max 20x")
        #expect(["12.4M", "12,4M", "12,4\u{00A0}M"].contains(Fmt.tokens(12_400_000))) // the separator follows the region
        let english = Locale(identifier: "en_US")
        let spanish = Locale(identifier: "es_ES")
        #expect(Fmt.tokens(3_056_800_000, locale: english) == "3.1B")
        #expect(Fmt.tokens(3_056_800_000, locale: spanish) == "3,1\u{00A0}mil\u{00A0}M")
        #expect(Fmt.tokens(1_000_000_000, locale: spanish) == "1\u{00A0}mil\u{00A0}M")
        #expect(Fmt.tokens(850_000, locale: english) == "850K")
        #expect(Fmt.tokens(850_000, locale: spanish) == "850\u{00A0}mil")
        #expect(Fmt.tokens(125_400_000, locale: english) == "125M")
        #expect(Fmt.tokens(312, locale: spanish) == "312")
    }
}
