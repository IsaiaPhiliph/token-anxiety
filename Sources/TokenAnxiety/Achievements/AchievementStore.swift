import Foundation
import Observation
import TokenAnxietyCore

/// The achievements for the app: judges them whenever the history or a quota changes,
/// keeps the book on disk and announces new ones.
@MainActor @Observable
final class AchievementStore {
    private(set) var book = AchievementBook()
    private(set) var facts = AchievementFacts()

    var hasUnseen: Bool { !book.unseen.isEmpty }

    @ObservationIgnored private let demo: Bool
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let settings: AppSettings
    /// Nothing is judged before the history has been read once: the first judgement
    /// is the one announced as a summary.
    @ObservationIgnored private var ledger: UsageLedger?
    @ObservationIgnored private var plans: [ProviderID: String] = [:]

    init(demo: Bool, notifier: Notifier, settings: AppSettings) {
        self.demo = demo
        self.notifier = notifier
        self.settings = settings
        if !demo { load() }
    }

    /// After each read of the logs.
    func ledgerUpdated(_ ledger: UsageLedger) {
        self.ledger = ledger
        evaluate()
    }

    /// After each snapshot, for the achievements about the limits.
    func observe(_ snapshot: ProviderSnapshot) {
        if let plan = snapshot.plan { plans[snapshot.provider] = plan }
        let ledger = self.ledger
        book.watcher.observe(snapshot, inMenuBar: settings.showsInMenuBar(snapshot.provider), calendar: Fmt.calendar) { interval in
            guard let ledger else { return 0 }
            return ledger.daily(in: interval, calendar: Fmt.calendar).values.filter { $0.counts.requests > 0 }.count
        }
        evaluate()
    }

    func panelOpened() {
        book.app.panelOpened(calendar: Fmt.calendar)
        evaluate()
    }

    func settingChanged(_ key: String) {
        guard !book.app.settingsChanged.contains(key) else { return }
        book.app.settingsChanged.insert(key)
        evaluate()
    }

    func shareExported() {
        book.app.shareExports += 1
        evaluate()
    }

    func adviceRated() {
        book.app.adviceRatings += 1
        evaluate()
    }

    func markSeen() {
        guard hasUnseen else { return }
        book.markSeen()
        save()
    }

    private func evaluate() {
        guard let ledger else { return }
        facts = AchievementFacts.compute(ledger: ledger, plans: plans, quota: demo ? Self.demoQuota : book.watcher.counters,
                                         app: book.app, calendar: Fmt.calendar)
        let (unlocks, first) = book.evaluate(facts)
        save()
        guard !unlocks.isEmpty, !demo, settings.notificationsEnabled else { return }
        announce(unlocks, summary: first || unlocks.count > 3)
    }

    private func announce(_ unlocks: [AchievementBook.Unlock], summary: Bool) {
        if summary {
            notifier.post(title: String(localized: "You've unlocked \(unlocks.count) achievements"),
                          body: String(localized: "See them in Statistics › Achievements."), thread: "achievements")
            return
        }
        for unlock in unlocks {
            guard let achievement = AchievementCatalog.achievement(unlock.id) else { continue }
            let name = achievement.isTiered ? "\(achievement.title) · \(Tier.name(unlock.tier))" : achievement.title
            notifier.post(title: String(localized: "Achievement unlocked: \(name)"),
                          body: achievement.detail(goal: achievement.tiers[unlock.tier - 1]), thread: "achievements")
        }
    }

    /// For `--demo`: a few months of watching the limits.
    private static var demoQuota: QuotaCounters {
        var counters = QuotaCounters()
        counters.limitHits = 4
        counters.savedByTheBell = 2
        counters.onTheEdge = 1
        counters.crumblessWeeks = 1
        counters.answers = 1
        return counters
    }

    // MARK: Saving

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenAnxiety/achievements.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url),
              let saved = try? JSONDecoder().decode(AchievementBook.self, from: data) else { return }
        book = saved
    }

    private func save() {
        guard !demo, let data = try? JSONEncoder().encode(book) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
