import Charts
import SwiftUI
import TokenAnxietyCore

/// What fills Claude Code's context: your prompts, tool results by tool, Claude's replies.
struct ContentSection: View {
    let scope: StatsScope
    let measuring: Bool

    private struct Part: Identifiable {
        var name: String
        var tokens: Double
        var color: Color
        var id: String { name }
    }

    var body: some View {
        let content = scope.ledger.content(in: scope.interval)
        let parts = [
            Part(name: String(localized: "Your prompts"), tokens: ContentCounts.tokens(content.prompts), color: .blue),
            Part(name: String(localized: "Subagent instructions"), tokens: ContentCounts.tokens(content.agentPrompts), color: .indigo),
            Part(name: String(localized: "Tool results"),
                 tokens: ContentCounts.tokens(content.toolResultCharacters) + Double(content.images) * ContentCounts.tokensPerImage,
                 color: .teal),
            Part(name: String(localized: "Claude's replies"), tokens: ContentCounts.tokens(content.replies), color: .orange),
            Part(name: String(localized: "Tool calls"), tokens: ContentCounts.tokens(content.toolCalls), color: .pink),
        ].filter { $0.tokens > 0 }
        let sum = parts.reduce(0) { $0 + $1.tokens }
        VStack(alignment: .leading, spacing: 18) {
            if scope.provider == .codex {
                note(String(localized: "Only Claude Code's conversations are measured."))
            } else if sum == 0 {
                note(measuring ? String(localized: "Nothing measured in this period yet.")
                               : String(localized: "Content analysis is off. Turn it on in Settings › Statistics."))
            } else {
                StatsCard(title: String(localized: "What goes into the context"),
                          subtitle: String(localized: "Estimated tokens of each kind of content")) {
                    Chart(parts) { part in
                        BarMark(x: .value("Tokens", part.tokens), y: .value("Content", ""))
                            .foregroundStyle(part.color)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(spacing: 6) {
                        ForEach(parts) { part in
                            HStack {
                                Circle().fill(part.color).frame(width: 8, height: 8)
                                Text(part.name)
                                Spacer()
                                Text("≈ \(Fmt.tokens(part.tokens))").monospacedDigit()
                                Text(Fmt.percent(part.tokens / sum * 100))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    StatsCard(title: String(localized: "Tool results by tool"),
                              subtitle: String(localized: "What each tool sent back into the context")) {
                        tools(content)
                    }
                    StatsCard(title: String(localized: "What Claude wrote"),
                              subtitle: String(localized: "Output tokens: visible text and calls, the rest thinking")) {
                        output(content)
                    }
                }
                note(String(localized: "Estimated from sizes, at about four characters a token. Only sizes are measured, on this Mac; no text is kept. System prompts, tool definitions and attachments are not counted."))
            }
        }
    }

    private func tools(_ content: ContentCounts) -> some View {
        let rows = content.toolResults.sorted { $0.value > $1.value }.prefix(10)
        let top = Double(rows.first?.value ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows), id: \.key) { tool, characters in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(tool).lineLimit(1)
                        Spacer()
                        Text("≈ \(Fmt.tokens(ContentCounts.tokens(characters)))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    UsageBar(value: Double(characters) / top * 100, tint: .teal, height: 5)
                }
            }
        }
    }

    private func output(_ content: ContentCounts) -> some View {
        let output = Double(scope.ledger.totals(in: scope.interval, provider: .claude).counts.output)
        let visible = min(output, ContentCounts.tokens(content.replies + content.toolCalls))
        let thinking = max(0, output - visible)
        return VStack(alignment: .leading, spacing: 10) {
            Text(Fmt.tokens(output))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            ForEach([(String(localized: "Visible"), visible, Color.orange), (String(localized: "Thinking"), thinking, Color.purple)],
                    id: \.0) { name, value, color in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(name)
                        Spacer()
                        Text(output > 0 ? Fmt.percent(value / output * 100) : "–").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    UsageBar(value: output > 0 ? value / output * 100 : 0, tint: color, height: 5)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
