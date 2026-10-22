import SwiftUI
import TokenAnxietyCore

enum StatsSection: String, CaseIterable, Identifiable {
    case overview, days, hours, projects, models, sessions, content, achievements, advice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .days: String(localized: "Days")
        case .hours: String(localized: "Hours")
        case .projects: String(localized: "Projects")
        case .models: String(localized: "Models")
        case .sessions: String(localized: "Sessions")
        case .content: String(localized: "Content")
        case .achievements: String(localized: "Achievements")
        case .advice: String(localized: "Advice")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .days: "chart.bar.xaxis"
        case .hours: "clock"
        case .projects: "folder"
        case .models: "cpu"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .content: "text.page"
        case .achievements: "trophy"
        case .advice: "lightbulb"
        }
    }
}

@MainActor @Observable
final class StatsNavigation {
    var section: StatsSection = .overview
    var sharing = false
}

enum StatsMetric: String, CaseIterable, Identifiable {
    case tokens, cost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: String(localized: "Tokens")
        case .cost: String(localized: "≈ API $")
        }
    }
}

enum ServiceFilter: String, CaseIterable, Identifiable {
    case all, claude, codex

    var id: String { rawValue }
    var provider: ProviderID? { ProviderID(rawValue: rawValue) }

    var title: String {
        switch self {
        case .all: String(localized: "Both")
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

extension StatsPeriod {
    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .week: String(localized: "7 days")
        case .month: String(localized: "30 days")
        case .quarter: String(localized: "90 days")
        case .all: String(localized: "All")
        }
    }
}

/// What every section shows: one ledger, one period, one service, one metric.
struct StatsScope {
    let ledger: UsageLedger
    let period: StatsPeriod
    let interval: DateInterval
    let previous: DateInterval?
    let provider: ProviderID?
    let metric: StatsMetric
    let calendar: Calendar
    let now: Date

    init(ledger: UsageLedger, period: StatsPeriod, provider: ProviderID?, metric: StatsMetric, now: Date) {
        self.ledger = ledger
        self.period = period
        self.provider = provider
        self.metric = metric
        self.now = now
        calendar = Fmt.calendar
        interval = period.interval(now: now, calendar: calendar, firstDate: ledger.firstDate)
        previous = period.previous(now: now, calendar: calendar)
    }

    var totals: UsageTotals { ledger.totals(in: interval, provider: provider) }

    func value(_ totals: UsageTotals) -> Double {
        metric == .tokens ? Double(totals.counts.total) : totals.cost
    }

    func format(_ value: Double) -> String {
        metric == .tokens ? Fmt.tokens(value) : Fmt.money(value)
    }

    /// The metric's name for chart axes.
    var valueLabel: String { metric == .tokens ? String(localized: "Tokens") : String(localized: "≈ API $") }
}

struct StatsView: View {
    let store: UsageStore
    let usage: UsageLedgerStore
    @Bindable var navigation: StatsNavigation

    @AppStorage("stats.period") private var period: StatsPeriod = .week
    @AppStorage("stats.service") private var service: ServiceFilter = .all
    @AppStorage("stats.metric") private var metric: StatsMetric = .tokens

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.section }, set: { if let value = $0 { navigation.section = value } })) {
                ForEach(StatsSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(section == .achievements ? store.achievements.book.unseen.count : 0)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let scope = StatsScope(ledger: usage.ledger, period: period, provider: service.provider,
                                       metric: metric, now: context.date)
                detail(scope)
            }
            .navigationSubtitle(navigation.section.title)
            .toolbar {
                ToolbarItem {
                    Picker("Period", selection: $period) {
                        ForEach(StatsPeriod.allCases) { period in Text(period.title).tag(period) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    Picker("Service", selection: $service) {
                        ForEach(ServiceFilter.allCases) { service in Text(service.title).tag(service) }
                    }
                    .pickerStyle(.segmented)
                    .help("Service")
                }
                ToolbarItem {
                    Button("Share card", systemImage: "square.and.arrow.up") { navigation.sharing = true }
                        .help("Make a share card")
                }
                ToolbarItem {
                    Toggle(isOn: Binding(get: { metric == .cost }, set: { metric = $0 ? .cost : .tokens })) {
                        Label("Show API cost", systemImage: "dollarsign")
                    }
                    .toggleStyle(.button)
                    .help("Show the estimated API cost instead of tokens")
                }
            }
        }
        .environment(\.locale, Fmt.locale)
        .frame(minWidth: 860, minHeight: 560)
        .sheet(isPresented: $navigation.sharing) {
            ShareSheet(store: store) { navigation.sharing = false }
        }
    }

    @ViewBuilder
    private func detail(_ scope: StatsScope) -> some View {
        VStack(spacing: 0) {
            if let progress = usage.progress {
                ReadingBanner(progress: progress)
            }
            if navigation.section == .achievements {
                scrolling { AchievementsSection(store: store.achievements) }
            } else if navigation.section == .advice {
                scrolling { AdviceSection(store: store) }
            } else if scope.ledger.isEmpty {
                ContentUnavailableView {
                    Label(usage.lastUpdate == nil ? String(localized: "Reading your history…") : String(localized: "No local usage yet"),
                          systemImage: "chart.bar.xaxis")
                } description: {
                    Text("The statistics come from Claude Code's and Codex's own logs on this Mac. Use either and come back.")
                }
            } else {
                switch navigation.section {
                case .overview: scrolling { OverviewSection(scope: scope, store: store) }
                case .days: scrolling { DaysSection(scope: scope) }
                case .hours: scrolling { HoursSection(scope: scope) }
                case .projects: ProjectsSection(scope: scope)
                case .models: scrolling { ModelsSection(scope: scope) }
                case .sessions: SessionsSection(scope: scope)
                case .content: scrolling { ContentSection(scope: scope, measuring: store.settings.measureContent) }
                case .achievements, .advice: EmptyView()
                }
            }
        }
    }

    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .padding(24)
                .frame(maxWidth: 1100, alignment: .topLeading)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Shown during a long read of the logs (the first launch).
private struct ReadingBanner: View {
    let progress: LedgerIndexer.Progress

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: progress.fraction)
                .frame(width: 160)
            Text("Reading your history: \(Fmt.percent(progress.fraction * 100))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
