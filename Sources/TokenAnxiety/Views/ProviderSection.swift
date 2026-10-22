import SwiftUI
import TokenAnxietyCore

/// One service in the panel: its two headline windows as tiles, the pace, the
/// other windows, a few facts and the seven-day chart.
struct ProviderSection: View {
    let id: ProviderID
    let entry: UsageStore.Entry
    let settings: AppSettings
    let history: HistoryLog
    let now: Date
    let retry: () -> Void
    let stale: Bool
    /// Today's tokens from the local logs (Claude Code, Codex).
    let today: UsageTotals?
    /// Live Claude Code sessions and how full their context is.
    let contexts: [ContextGauge]

    @AppStorage private var showsHistory: Bool

    init(id: ProviderID, entry: UsageStore.Entry, settings: AppSettings, history: HistoryLog, now: Date,
         retry: @escaping () -> Void, stale: Bool = false, today: UsageTotals? = nil, contexts: [ContextGauge] = []) {
        self.id = id
        self.stale = stale
        self.today = today
        self.contexts = contexts
        self.entry = entry
        self.settings = settings
        self.history = history
        self.now = now
        self.retry = retry
        _showsHistory = AppStorage(wrappedValue: false, "showsHistory.\(id.rawValue)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snapshot = entry.snapshot {
                tiles(snapshot)
                if settings.showPace, let weekly = snapshot.secondary ?? snapshot.primary,
                   weekly.kind == .weekly || weekly.kind == .monthly, let pace = Pace.evaluate(weekly, now: now) {
                    paceLine(pace)
                }
                let others = snapshot.otherWindows
                if !others.isEmpty {
                    VStack(spacing: 7) {
                        ForEach(others) { window in compactRow(window) }
                    }
                    .padding(.top, 2)
                }
                let facts = snapshot.facts + todayFact
                if !facts.isEmpty { self.facts(facts) }
                if !contexts.isEmpty { contextRows }
                if settings.historyEnabled { historyBlock(snapshot) }
            }
            if let error = entry.error { errorLine(error) }
        }
        .opacity(entry.error != nil && entry.snapshot != nil ? 0.92 : 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ProviderIcon(id: id, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(id.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let plan = entry.snapshot?.plan { PlanBadge(text: plan) }
                }
                if settings.showAccounts, let account = entry.snapshot?.account {
                    Text(account)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if entry.loading {
                ProgressView().controlSize(.small)
            } else if let snapshot = entry.snapshot {
                Text(Fmt.ago(snapshot.fetchedAt, now: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Tiles

    @ViewBuilder
    private func tiles(_ snapshot: ProviderSnapshot) -> some View {
        let headline = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        if !headline.isEmpty {
            HStack(spacing: 8) {
                ForEach(headline) { window in
                    tile(window, pace: settings.showPace && window.kind == .weekly ? Pace.evaluate(window, now: now) : nil,
                         dimmed: stale)
                }
            }
        } else if entry.error == nil {
            Text("No limits to show right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ window: UsageWindow, pace: Pace?, dimmed: Bool) -> some View {
        let level = settings.level(window.usedPercent)
        return VStack(alignment: .leading, spacing: 5) {
            Text(window.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Fmt.percent(window.usedPercent))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: window.usedPercent))
                .foregroundStyle(level >= .warning ? AnyShapeStyle(level.color) : AnyShapeStyle(.primary))
            UsageBar(value: window.usedPercent, marker: pace?.expectedPercent, tint: level.color)
                .padding(.vertical, 2)
            if let reset = shortReset(window.resetsAt) {
                Label(reset, systemImage: "arrow.counterclockwise")
                    .labelStyle(TightLabel())
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let detail = window.detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.primary.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .opacity(dimmed ? 0.55 : 1)
        .help(Fmt.resetLine(window.resetsAt, now: now) ?? window.label)
    }

    /// "in 2 h 14 min" up to half a day, then "Saturday 10:00 AM".
    private func shortReset(_ date: Date?) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return String(localized: "resetting") }
        if remaining < 12 * 3600 { return String(localized: "in \(Fmt.duration(remaining))") }
        let calendar = Fmt.calendar
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "tomorrow \(Fmt.time(date))")
        }
        if remaining < 6 * 86_400 { return "\(Fmt.weekday(date)) \(Fmt.time(date))" }
        return Fmt.day(date)
    }

    // MARK: Pace

    private func paceLine(_ pace: Pace) -> some View {
        let tint: Color = pace.isWorrying ? .orange : (pace.delta > 5 ? .yellow : .green)
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: pace.isWorrying ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.50percent")
                .foregroundStyle(tint)
            Text(pace.summary(now: now))
                .foregroundStyle(pace.isWorrying ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(pace.deltaText)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.18)))
                .foregroundStyle(tint)
                .help("Points above (+) or below (−) an even spend over the week")
        }
        .font(.system(size: 11.5))
    }

    // MARK: Other windows

    private func compactRow(_ window: UsageWindow) -> some View {
        let level = settings.level(window.usedPercent)
        return HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .frame(width: 138, alignment: .leading)
            UsageBar(value: window.usedPercent, tint: level.color, height: 4)
            Text(Fmt.percent(window.usedPercent))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(level >= .warning ? AnyShapeStyle(level.color) : AnyShapeStyle(.secondary))
                .frame(width: 40, alignment: .trailing)
        }
        .help([window.detail, Fmt.resetLine(window.resetsAt, now: now)].compactMap { $0 }.joined(separator: " · "))
    }

    // MARK: Context

    private var contextRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(contexts) { gauge in
                HStack(spacing: 8) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 10))
                        .frame(width: 14)
                        .foregroundStyle(.secondary)
                    Text(gauge.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 124, alignment: .leading)
                    UsageBar(value: gauge.percent, tint: gauge.percent >= 80 ? .orange : .accentColor, height: 4)
                    Text(Fmt.percent(gauge.percent))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .help(String(localized: "Context: \(Fmt.tokens(Double(gauge.tokens))) of \(Fmt.tokens(Double(gauge.window))) tokens · \(ModelNames.display(gauge.model))"))
            }
        }
        .padding(.top, 2)
    }

    // MARK: Facts

    private var todayFact: [Fact] {
        guard let today, today.counts.requests > 0 else { return [] }
        let tokens = String(localized: "\(Fmt.tokens(Double(today.counts.total))) tokens")
        let value = today.cost > 0 ? "\(tokens) · ≈ \(Fmt.money(today.cost))" : tokens
        return [Fact(String(localized: "Today"), value, symbol: "chart.bar")]
    }

    private func facts(_ facts: [Fact]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(facts) { fact in
                HStack(spacing: 6) {
                    Image(systemName: fact.symbol ?? "info.circle")
                        .frame(width: 14)
                        .foregroundStyle(.secondary)
                    Text(fact.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(fact.value)
                        .fontWeight(.medium)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(.top, 2)
    }

    // MARK: History

    @ViewBuilder
    private func historyBlock(_ snapshot: ProviderSnapshot) -> some View {
        let samples = history.samples(for: id, since: now.addingTimeInterval(-7 * 86_400))
        let weekStart = Fmt.calendar.startOfDay(for: now.addingTimeInterval(-6 * 86_400))
        let daily = snapshot.dailyTokens.filter { $0.day >= weekStart }
        // Hidden until there is something to draw: two samples, or tokens this week.
        if samples.count >= 2 || daily.contains(where: { $0.value > 0 }) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.smooth(duration: 0.25)) { showsHistory.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showsHistory ? 90 : 0))
                        Text("Last 7 days")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsHistory {
                    HistoryChart(samples: samples, daily: daily, now: now,
                                 primaryLabel: snapshot.primary?.label ?? "5 h",
                                 secondaryLabel: snapshot.secondary?.label ?? String(localized: "Week"))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Errors

    private func errorLine(_ error: ProviderError) -> some View {
        let symbol: String = switch error {
        case .notRunning: "moon.zzz"
        case .sessionExpired, .notLoggedIn: "person.crop.circle.badge.exclamationmark"
        case .accessDenied: "lock"
        default: "exclamationmark.triangle"
        }
        let retryable: Bool = switch error {
        case .notRunning, .notLoggedIn: false
        default: true
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            Text(error.errorDescription ?? String(localized: "Error"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if retryable {
                Button("Retry", action: retry)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .font(.system(size: 11.5))
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}
