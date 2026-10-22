import Charts
import SwiftUI
import TokenAnxietyCore

/// When the tokens go: by hour of the day, and by weekday and hour.
struct HoursSection: View {
    let scope: StatsScope

    @State private var selectedHour: Int?

    var body: some View {
        let hours = scope.ledger.byHourOfDay(in: scope.interval, provider: scope.provider, calendar: scope.calendar)
        let values = (0..<24).map { (hour: $0, value: hours[$0].map(scope.value) ?? 0) }
        let total = values.reduce(0) { $0 + $1.value }
        VStack(alignment: .leading, spacing: 18) {
            StatsCard(title: String(localized: "By hour of the day"), subtitle: scope.valueLabel) {
                hourChart(values, total: total)
            }
            StatsCard(title: String(localized: "By weekday and hour"),
                      subtitle: String(localized: "Darker, more. Times are this Mac's.")) {
                weekGrid
            }
            if total > 0 { habits(values, total: total) }
        }
    }

    private struct HourBar: Identifiable {
        var hour: Int
        var value: Double
        var id: Int { hour }
        var start: Double { Double(hour) + 0.1 }
        var end: Double { Double(hour) + 0.9 }
        var base: Double { 0 }
    }

    private var selection: Binding<Double?> {
        Binding(get: { selectedHour.map { Double($0) + 0.5 } },
                set: { selectedHour = $0.map { min(23, max(0, Int($0))) } })
    }

    private func hourChart(_ values: [(hour: Int, value: Double)], total: Double) -> some View {
        let bars = values.map { HourBar(hour: $0.hour, value: $0.value) }
        return Chart {
            ForEach(bars) { bar in
                barMark(bar)
            }
            if let selectedHour, total > 0 {
                RuleMark(x: .value("Hour", Double(selectedHour) + 0.5))
                    .foregroundStyle(Color.primary.opacity(0.12))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        hourTooltip(selectedHour, value: bars[selectedHour].value, total: total)
                    }
            }
        }
        .chartXScale(domain: 0.0...24.0)
        .chartXAxis {
            AxisMarks(values: [0.0, 3, 6, 9, 12, 15, 18, 21]) { value in
                AxisValueLabel { Text(hourLabel(Int(value.as(Double.self) ?? 0))) }
            }
        }
        .chartXSelection(value: selection)
        .statsValueAxis(scope)
        .frame(height: 220)
    }

    private func barMark(_ bar: HourBar) -> some ChartContent {
        let start: PlottableValue<Double> = .value("Hour", bar.start)
        let end: PlottableValue<Double> = .value("Hour", bar.end)
        let bottom: PlottableValue<Double> = .value("Value", bar.base)
        let top: PlottableValue<Double> = .value("Value", bar.value)
        let opacity: Double = bar.hour == selectedHour ? 1 : 0.65
        return RectangleMark(xStart: start, xEnd: end, yStart: bottom, yEnd: top)
            .foregroundStyle(Color.accentColor.opacity(opacity))
    }

    private func hourTooltip(_ hour: Int, value: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hourLabel(hour)).font(.caption.weight(.semibold))
            Text(scope.format(value)).font(.caption.monospacedDigit())
            Text("\(Fmt.percent(value / total * 100)) of the period")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background).shadow(radius: 3))
    }

    private var weekGrid: some View {
        let grid = scope.ledger.byWeekdayAndHour(in: scope.interval, provider: scope.provider, calendar: scope.calendar)
        let symbols = scope.calendar.weekdaySymbols
        // Weekdays in the order of this calendar's week (Monday first in Spain).
        let weekdays = (0..<7).map { (scope.calendar.firstWeekday - 1 + $0) % 7 + 1 }
        let rows = weekdays.map { weekday in
            MatrixHeatmap.Row(label: symbols[weekday - 1].capitalized(with: Fmt.locale),
                              values: (0..<24).map { grid[WeekHour(weekday: weekday, hour: $0)].map(scope.value) ?? 0 })
        }
        let labels = Dictionary(uniqueKeysWithValues: stride(from: 0, to: 24, by: 3).map { ($0, hourLabel($0)) })
        return MatrixHeatmap(rows: rows, columnLabels: labels, tooltip: { row, hour in
            "\(rows[row].label), \(hourLabel(hour)): \(scope.format(rows[row].values[hour]))"
        }, cellHeight: 22, labelWidth: 90)
    }

    /// A few plain-language facts about when you work.
    private func habits(_ values: [(hour: Int, value: Double)], total: Double) -> some View {
        let busiest = values.max { $0.value < $1.value }?.hour ?? 0
        let night = values.filter { $0.hour >= 22 || $0.hour < 6 }.reduce(0) { $0 + $1.value } / total
        let morning = values.filter { (6..<12).contains($0.hour) }.reduce(0) { $0 + $1.value } / total
        let grid = scope.ledger.byWeekdayAndHour(in: scope.interval, provider: scope.provider, calendar: scope.calendar)
        let weekend = grid.filter { $0.key.weekday == 1 || $0.key.weekday == 7 }.values.reduce(0) { $0 + scope.value($1) } / total
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatTile(title: String(localized: "Busiest hour"), value: hourLabel(busiest), symbol: "flame")
            StatTile(title: String(localized: "Mornings"), value: Fmt.percent(morning * 100), symbol: "sunrise", footnote: "6–12 h")
            StatTile(title: String(localized: "Nights"), value: Fmt.percent(night * 100), symbol: "moon.stars", footnote: "22–6 h")
            StatTile(title: String(localized: "Weekends"), value: Fmt.percent(weekend * 100), symbol: "beach.umbrella")
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = scope.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: scope.now) ?? scope.now
        return Fmt.time(date)
    }
}
