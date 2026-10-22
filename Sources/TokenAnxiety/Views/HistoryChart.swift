import Charts
import SwiftUI
import TokenAnxietyCore

/// The last seven days: the week as a line, the five-hour sessions as an area,
/// and tokens per day when the service reports them.
struct HistoryChart: View {
    let samples: [HistorySample]
    let daily: [DayValue]
    let now: Date
    let primaryLabel: String
    let secondaryLabel: String

    private var start: Date { now.addingTimeInterval(-7 * 86_400) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if samples.count >= 2 {
                Chart {
                    ForEach(samples, id: \.date) { sample in
                        if let primary = sample.primary {
                            AreaMark(x: .value("Hora", sample.date), y: .value(primaryLabel, primary))
                                .foregroundStyle(Color.orange.opacity(0.22))
                                .interpolationMethod(.monotone)
                        }
                    }
                    ForEach(samples, id: \.date) { sample in
                        if let secondary = sample.secondary {
                            LineMark(x: .value("Hora", sample.date), y: .value(secondaryLabel, secondary))
                                .foregroundStyle(Color.accentColor)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartXScale(domain: start...now)
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel {
                            if let percent = value.as(Int.self) { Text("\(percent)%") }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                    }
                }
                .font(.system(size: 9.5))
                .frame(height: 92)

                HStack(spacing: 12) {
                    legend(color: .accentColor, text: secondaryLabel, line: true)
                    legend(color: .orange.opacity(0.5), text: primaryLabel, line: false)
                }
            }
            if daily.contains(where: { $0.value > 0 }) {
                Text("Tokens por día")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Chart(daily, id: \.day) { day in
                    BarMark(x: .value("Día", day.day, unit: .day), y: .value("Tokens", day.value))
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(3)
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                }
                .font(.system(size: 9.5))
                .frame(height: 52)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func legend(color: Color, text: String, line: Bool) -> some View {
        HStack(spacing: 5) {
            if line {
                Capsule().fill(color).frame(width: 12, height: 2.5)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            }
            Text(text)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
}
