import SwiftUI
import TokenAnxietyCore

/// Statistics › Advice: prepare the request, read it, send it, rate the tips.
struct AdviceSection: View {
    let store: UsageStore

    @AppStorage("advice.includeProjects") private var includeProjects = false

    var body: some View {
        let advice = store.advice
        VStack(alignment: .leading, spacing: 18) {
            StatsCard(title: String(localized: "AI advice"),
                      subtitle: String(localized: "Claude reads your last 30 days, in numbers only, and suggests how to make your limits last.")) {
                Text("What goes: totals, models, effort, hours of the day, content sizes and session lengths. Never your prompts, files, paths or accounts. It is sent to Anthropic with your own API key, only when you press Send, and billed to your account (a few cents).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Include project names", isOn: $includeProjects)
                HStack(spacing: 12) {
                    Button("Prepare the request", systemImage: "doc.text.magnifyingglass") { prepare() }
                    if !advice.hasKey {
                        Label("Add your API key in Settings › Statistics", systemImage: "key")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let preview = advice.preview {
                StatsCard(title: String(localized: "The exact request"),
                          subtitle: String(localized: "POST \(advice.endpointDescription) · \(Advice.model) · your key goes in the x-api-key header")) {
                    ScrollView {
                        Text(String(decoding: preview, as: UTF8.self))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 260)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    HStack(spacing: 10) {
                        Button("Send", systemImage: "paperplane") { Task { await advice.send() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!advice.hasKey || advice.state == .sending)
                        Button("Discard") { advice.discardPreview() }
                            .disabled(advice.state == .sending)
                        if advice.state == .sending {
                            ProgressView().controlSize(.small)
                            Text("Claude is reading your numbers…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if case .failed(let message) = advice.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !advice.tips.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Tips").font(.title3.weight(.semibold))
                        if let date = advice.tipsDate {
                            Text(Fmt.moment(date)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(advice.tips) { tip in
                        TipCard(tip: tip) { helpful in
                            if advice.rate(tip, helpful: helpful) { store.achievements.adviceRated() }
                        }
                    }
                }
            }
        }
    }

    private func prepare() {
        var plans: [ProviderID: String] = [:]
        var weekly: [ProviderID: Double] = [:]
        for id in [ProviderID.claude, .codex] {
            guard let snapshot = store.entries[id]?.snapshot else { continue }
            if let plan = snapshot.plan { plans[id] = plan }
            if let week = snapshot.secondary, week.kind == .weekly { weekly[id] = week.usedPercent }
        }
        store.advice.prepare(ledger: store.usage.ledger, includeProjects: includeProjects, plans: plans, weeklyUsed: weekly)
    }
}

private struct TipCard: View {
    let tip: Advice.Tip
    let rate: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.max")
                .font(.title3)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text(tip.title).font(.headline)
                Text(tip.evidence).font(.callout).foregroundStyle(.secondary)
                Label(tip.action, systemImage: "arrow.right.circle")
                    .font(.callout)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button { rate(true) } label: {
                    Image(systemName: tip.helpful == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .help("Useful")
                Button { rate(false) } label: {
                    Image(systemName: tip.helpful == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .help("Not useful")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}
