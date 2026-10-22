import AppKit
import Observation
import TokenAnxietyCore

/// Asks every service for its usage on a timer and keeps the latest answers,
/// the history and the alert state, saved between launches.
@MainActor @Observable
final class UsageStore {
    struct Entry: Equatable {
        var installed = false
        var snapshot: ProviderSnapshot?
        var error: ProviderError?
        var loading = false
        var lastAttempt: Date?
    }

    private(set) var entries: [ProviderID: Entry] = [:]
    private(set) var history = HistoryLog()
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    let settings: AppSettings
    let demo: Bool
    /// Tokens, projects and sessions from the local logs, beside the quotas.
    let usage: UsageLedgerStore
    @ObservationIgnored private let providers: [ProviderID: any UsageProvider]
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private var alerts = AlertTracker()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pausedUntil: [ProviderID: Date] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(settings: AppSettings, notifier: Notifier, demo: Bool) {
        self.settings = settings
        self.notifier = notifier
        self.demo = demo
        usage = UsageLedgerStore(demo: demo)
        if demo {
            providers = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, DemoProvider($0) as any UsageProvider) })
            history = Demo.history()
        } else {
            providers = [
                .claude: ClaudeProvider(),
                .codex: CodexProvider(),
                .antigravity: AntigravityProvider(),
                .cursor: CursorProvider(),
            ]
            load()
        }
    }

    // MARK: What to show

    /// Enabled services that are on this Mac (or that answered before).
    var visibleProviders: [ProviderID] {
        ProviderID.allCases.filter { id in
            guard settings.isEnabled(id), let entry = entries[id] else { return false }
            return entry.installed || entry.snapshot != nil
        }
    }

    var menuBarProviders: [ProviderID] {
        visibleProviders.filter { settings.showsInMenuBar($0) }
    }

    /// The highest figure in the menu bar, which sets the panel's mood.
    var worstPercent: Double? {
        menuBarProviders.compactMap { id -> Double? in
            guard let snapshot = entries[id]?.snapshot else { return nil }
            return [snapshot.primary?.usedPercent, snapshot.secondary?.usedPercent].compactMap { $0 }.max()
        }.max()
    }

    /// Dimmed when the figures need the user (expired session…) or are old. A passing
    /// hiccup (429, network) keeps recent figures bright: they are still right.
    func isStale(_ id: ProviderID, now: Date = Date()) -> Bool {
        guard let entry = entries[id], let snapshot = entry.snapshot else { return true }
        if entry.error?.needsUser == true { return true }
        let tolerance = max(Double(settings.refreshMinutes) * 60 * 3, 15 * 60)
        return now.timeIntervalSince(snapshot.fetchedAt) > tolerance
    }

    // MARK: Refreshing

    func start() {
        Task { await refresh(manual: false) }
        reschedule()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    try? await Task.sleep(for: .seconds(4)) // let the network come back
                    await self.refresh(manual: false)
                }
            }
        })
    }

    func reschedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(settings.refreshMinutes) * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh(manual: false) }
            }
        }
        timer?.tolerance = 10
    }

    /// For the panel: refresh when it opens if the figures are more than a minute old.
    func refreshIfStale() {
        guard !isRefreshing else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        Task { await refresh(manual: false) }
    }

    /// How long to leave a service alone after a 429 that does not say.
    nonisolated static let rateLimitPause: TimeInterval = 5 * 60

    /// Longer than any provider's own timeouts (a Keychain prompt waits 60 s).
    nonisolated static let fetchDeadline: Double = 90

    func refresh(manual: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let now = Date()
        var jobs: [(ProviderID, any UsageProvider)] = []
        for id in ProviderID.allCases where settings.isEnabled(id) {
            guard let provider = providers[id] else { continue }
            if !manual {
                if let until = pausedUntil[id], until > now { continue }
                // Do not pop a Keychain prompt every two minutes after the user said no.
                if case .accessDenied = entries[id]?.error { continue }
            }
            entries[id, default: Entry()].loading = true
            jobs.append((id, provider))
        }

        await withTaskGroup(of: (ProviderID, Bool, Result<ProviderSnapshot, ProviderError>?).self) { group in
            for (id, provider) in jobs {
                group.addTask {
                    // One stuck service (Antigravity while it quits…) must not hold up the others'
                    // next refresh: each gets a deadline and the round ends on time.
                    await withDeadline(Self.fetchDeadline, onTimeout: {
                        (id, true, .failure(.network(String(localized: "\(id.displayName) took too long to answer."))))
                    }) {
                        guard await provider.isInstalled() else { return (id, false, nil) }
                        do {
                            return (id, true, .success(try await provider.fetch()))
                        } catch let error as ProviderError {
                            return (id, true, .failure(error))
                        } catch {
                            return (id, true, .failure(.badResponse(error.localizedDescription)))
                        }
                    }
                }
            }
            for await (id, installed, result) in group {
                apply(id, installed: installed, result: result)
            }
        }

        lastRefresh = Date()
        isRefreshing = false
        save()
        // On its own queue: the logs never hold up the quotas.
        usage.update()
    }

    private func apply(_ id: ProviderID, installed: Bool, result: Result<ProviderSnapshot, ProviderError>?) {
        var entry = entries[id] ?? Entry()
        entry.installed = installed
        entry.loading = false
        entry.lastAttempt = Date()
        switch result {
        case .success(let snapshot):
            entry.snapshot = snapshot
            entry.error = nil
            pausedUntil[id] = nil
            if settings.historyEnabled { history.record(snapshot) }
            let events = alerts.events(for: snapshot, thresholds: settings.thresholds,
                                       notifyRenewals: settings.notifyRenewals)
            if settings.notificationsEnabled, !demo { notifier.post(events) }
        case .failure(let error):
            entry.error = error
            if case .rateLimited(let retryAfter) = error {
                // The service's own Retry-After, kept between half a minute and an hour.
                pausedUntil[id] = Date().addingTimeInterval(min(max(retryAfter ?? Self.rateLimitPause, 30), 3600))
            }
        case nil:
            entry.error = nil
        }
        entries[id] = entry
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    // MARK: Saving

    private struct SavedState: Codable {
        var snapshots: [ProviderSnapshot]
        var history: HistoryLog
        var alerts: AlertTracker
    }

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TokenAnxiety", isDirectory: true).appendingPathComponent("state.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(SavedState.self, from: data) else { return }
        for snapshot in state.snapshots {
            entries[snapshot.provider] = Entry(installed: true, snapshot: snapshot)
        }
        history = state.history
        alerts = state.alerts
    }

    private func save() {
        guard !demo else { return }
        let state = SavedState(snapshots: entries.values.compactMap(\.snapshot), history: history, alerts: alerts)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(state) else { return }
        let url = Self.stateURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
