import SwiftUI
import TokenAnxietyCore

/// The panel under the menu bar item.
struct PanelView: View {
    let store: UsageStore
    let settings: AppSettings
    let actions: PanelActions

    var body: some View {
        ScrollView(.vertical) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actions.resize($0) }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: PanelController.width)
        .environment(\.locale, Fmt.locale)
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)
            let providers = store.visibleProviders
            if providers.isEmpty {
                emptyState
            } else {
                ForEach(Array(providers.enumerated()), id: \.element) { index, id in
                    if index > 0 {
                        Divider().opacity(0.6).padding(.vertical, 14)
                    }
                    ProviderSection(id: id, entry: store.entries[id] ?? .init(), settings: settings,
                                    history: store.history, now: now, retry: actions.refresh,
                                    stale: store.isStale(id, now: now), today: today(id, now: now))
                }
            }
            footer(now: now)
                .padding(.top, 16)
        }
        .padding(16)
    }

    private func today(_ id: ProviderID, now: Date) -> UsageTotals? {
        guard id == .claude || id == .codex else { return nil }
        let start = Fmt.calendar.startOfDay(for: now)
        return store.usage.ledger.totals(in: DateInterval(start: start, end: max(now, start)), provider: id)
    }

    private var header: some View {
        let mood = Mood(worst: store.worstPercent, settings: settings)
        return HStack(spacing: 10) {
            Image(nsImage: ProviderGlyph.image(nil, size: 17, color: .white))
                .frame(width: 32, height: 32)
                .background(Circle().fill(mood.color.gradient))
                .shadow(color: mood.color.opacity(0.35), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Token Anxiety")
                    .font(.system(size: 14, weight: .semibold))
                Text(mood.phrase)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: actions.openStats) {
                        Image(systemName: "chart.bar.xaxis")
                            .frame(width: 18, height: 18)
                            .overlay(alignment: .topTrailing) {
                                // New achievements waiting.
                                if store.achievements.hasUnseen {
                                    Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 4, y: -3)
                                }
                            }
                    }
                    .help("Statistics")
                    Button(action: actions.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: store.isRefreshing)
                            .frame(width: 18, height: 18)
                    }
                    .help("Refresh now")
                    Button(action: actions.openSettings) {
                        Image(systemName: "gearshape")
                            .frame(width: 18, height: 18)
                    }
                    .help("Settings")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No plans found")
                .font(.headline)
            Text("Sign in to Claude Code, Codex or Cursor, or open Antigravity, and they will show up here on their own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func footer(now: Date) -> some View {
        HStack {
            if store.demo {
                Label("Sample data", systemImage: "theatermasks")
            } else if let last = store.lastRefresh {
                Text("Updated \(Fmt.ago(last, now: now))")
            } else {
                Text("Updating…")
            }
            Spacer()
            Button("Quit", systemImage: "power", action: actions.quit)
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
