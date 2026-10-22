import Foundation

/// Made-up but plausible figures for `--demo`, screenshots and previews.
public struct DemoProvider: UsageProvider {
    public let id: ProviderID

    public init(_ id: ProviderID) { self.id = id }

    public func isInstalled() async -> Bool { true }

    public func fetch() async throws -> ProviderSnapshot {
        try await Task.sleep(for: .milliseconds(300))
        return Demo.snapshot(for: id)
    }
}

public enum Demo {
    public static func snapshot(for id: ProviderID, now: Date = Date()) -> ProviderSnapshot {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        switch id {
        case .claude:
            return ProviderSnapshot(provider: .claude, plan: "Max 20x", account: "tete@ejemplo.com", windows: [
                UsageWindow(id: "five_hour", label: "Sesión · 5 h", kind: .session, usedPercent: 34,
                            resetsAt: now.addingTimeInterval(2 * hour + 14 * 60), duration: 5 * hour),
                UsageWindow(id: "seven_day", label: "Semana", kind: .weekly, usedPercent: 66,
                            resetsAt: now.addingTimeInterval(2 * day + 20 * hour), duration: 7 * day),
                UsageWindow(id: "seven_day_opus", label: "Semana · Opus", kind: .weeklyModel, usedPercent: 12,
                            resetsAt: now.addingTimeInterval(2 * day + 20 * hour), duration: 7 * day),
                UsageWindow(id: "seven_day_sonnet", label: "Semana · Sonnet", kind: .weeklyModel, usedPercent: 3,
                            resetsAt: now.addingTimeInterval(2 * day + 20 * hour), duration: 7 * day),
            ], facts: [Fact("Uso extra", "8\(Fmt.thinSpace)% del límite mensual", symbol: "creditcard")], fetchedAt: now)
        case .codex:
            let days = (0..<7).map { offset in
                DayValue(day: Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(6 - offset) * day)),
                         value: [1.2, 0.4, 2.8, 3.1, 0.0, 1.9, 0.7][offset] * 1_000_000)
            }
            return ProviderSnapshot(provider: .codex, plan: "Plus", account: "tete@ejemplo.com", windows: [
                UsageWindow(id: "primary", label: "Sesión · 5 h", kind: .session, usedPercent: 8,
                            resetsAt: now.addingTimeInterval(3 * hour + 50 * 60), duration: 5 * hour),
                UsageWindow(id: "secondary", label: "Semana", kind: .weekly, usedPercent: 22,
                            resetsAt: now.addingTimeInterval(5 * day), duration: 7 * day),
            ], facts: [
                Fact("Racha", "4 días seguidos", symbol: "flame"),
                Fact("Tokens desde siempre", "12,4\(Fmt.thinSpace)M", symbol: "sum"),
            ], dailyTokens: days, fetchedAt: now)
        case .antigravity:
            return ProviderSnapshot(provider: .antigravity, plan: "Google AI Pro", account: "tete@ejemplo.com", windows: [
                UsageWindow(id: "gemini-pro", label: "Gemini 3 Pro (High)", kind: .model, usedPercent: 45,
                            resetsAt: now.addingTimeInterval(2 * hour), duration: 5 * hour),
                UsageWindow(id: "claude-sonnet", label: "Claude Sonnet 4.5", kind: .model, usedPercent: 80,
                            resetsAt: now.addingTimeInterval(1 * hour + 5 * 60), duration: 5 * hour),
                UsageWindow(id: "gemini-flash", label: "Gemini 3 Flash", kind: .model, usedPercent: 10,
                            resetsAt: now.addingTimeInterval(4 * hour), duration: 5 * hour),
            ], fetchedAt: now)
        case .cursor:
            return ProviderSnapshot(provider: .cursor, plan: "Pro", account: "tete@ejemplo.com", windows: [
                UsageWindow(id: "plan", label: "Este mes", kind: .monthly, usedPercent: 41,
                            resetsAt: now.addingTimeInterval(12 * day), duration: 30 * day,
                            detail: "8,20\(Fmt.thinSpace)US$ de 20,00\(Fmt.thinSpace)US$"),
                UsageWindow(id: "auto", label: "Auto y Composer", kind: .other, usedPercent: 30,
                            resetsAt: now.addingTimeInterval(12 * day), duration: 30 * day),
                UsageWindow(id: "api", label: "Modelos elegidos", kind: .other, usedPercent: 52,
                            resetsAt: now.addingTimeInterval(12 * day), duration: 30 * day),
            ], fetchedAt: now)
        }
    }

    /// A week of samples: the weekly figure climbing, sessions coming and going.
    public static func history(now: Date = Date()) -> HistoryLog {
        var log = HistoryLog()
        let start = now.addingTimeInterval(-7 * 86_400)
        var weekly: [ProviderID: Double] = [.claude: 18, .codex: 2]
        var date = start
        var step = 0
        while date < now {
            let hourOfDay = Calendar.current.component(.hour, from: date)
            let working = (9...13).contains(hourOfDay) || (16...23).contains(hourOfDay)
            for provider in [ProviderID.claude, .codex] {
                let speed = provider == .claude ? 0.7 : 0.12
                if working { weekly[provider, default: 0] += speed * Double.random(in: 0.3...1.4) }
                if provider == .claude, step == 136 { weekly[provider] = 2 } // the weekly reset, 4 d 4 h ago
                let phase = Double(hourOfDay % 5) / 5
                let session = working ? min(100, phase * (provider == .claude ? 95 : 30) + Double.random(in: 0...6)) : 0
                var windows = [
                    UsageWindow(id: "s", label: "", kind: .session, usedPercent: session),
                    UsageWindow(id: "w", label: "", kind: .weekly, usedPercent: min(100, weekly[provider] ?? 0)),
                ]
                if date.addingTimeInterval(1800) >= now { windows = Demo.snapshot(for: provider, now: now).windows }
                log.record(ProviderSnapshot(provider: provider, windows: windows, fetchedAt: date))
            }
            date = date.addingTimeInterval(1800)
            step += 1
        }
        return log
    }
}
