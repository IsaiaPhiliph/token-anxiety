import Foundation

/// Spanish formatting for everything the app shows.
public enum Fmt {
    public static let locale = Locale(identifier: "es_ES")
    /// Narrow no-break space, the Spanish separator between a number and "%".
    public static let thinSpace = "\u{202F}"

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = .current
        return calendar
    }

    /// "34 %"
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))\(thinSpace)%"
    }

    /// "34%", for the menu bar where every point of width counts.
    public static func compactPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "2 h 14 min", "3 días", "45 min", "menos de 1 min".
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days >= 2 { return hours >= 12 ? "\(days + 1) días" : "\(days) días" }
        if days == 1 { return hours > 0 ? "1 día y \(hours) h" : "1 día" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return "\(minutes) min" }
        return "menos de 1 min"
    }

    /// "15:30"
    public static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "H:mm"
        return formatter.string(from: date)
    }

    /// "jueves"
    public static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    /// "hoy a las 15:30", "mañana a las 9:00", "el jueves a las 9:00", "el 10 de noviembre".
    public static func moment(_ date: Date, now: Date = Date()) -> String {
        let calendar = calendar
        let at = calendar.component(.hour, from: date) == 1 ? "a la" : "a las"
        if calendar.isDate(date, inSameDayAs: now) { return "hoy \(at) \(time(date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "mañana \(at) \(time(date))"
        }
        if date.timeIntervalSince(now) < 6 * 86_400, date > now {
            return "el \(weekday(date)) \(at) \(time(date))"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "d 'de' MMMM"
        return "el \(formatter.string(from: date))"
    }

    /// "Se renueva en 2 h 14 min (15:30)" / "Se renueva el jueves a las 9:00".
    public static func resetLine(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return "Se está renovando" }
        if remaining < 12 * 3600 { return "Se renueva en \(duration(remaining)) (\(time(date)))" }
        return "Se renueva \(moment(date, now: now))"
    }

    /// "ahora", "hace 3 min", "hace 2 h", "hace 3 días".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "ahora" }
        if seconds < 3600 { return "hace \(max(1, Int((seconds / 60).rounded()))) min" }
        if seconds < 86_400 { return "hace \(Int(seconds / 3600)) h" }
        let days = Int(seconds / 86_400)
        return days == 1 ? "hace 1 día" : "hace \(days) días"
    }

    /// "12,4 M", "850 k", "312".
    public static func tokens(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        switch value {
        case 1_000_000_000...: return "\(formatter.string(from: NSNumber(value: value / 1_000_000_000)) ?? "")\(thinSpace)mil M"
        case 1_000_000...: return "\(formatter.string(from: NSNumber(value: value / 1_000_000)) ?? "")\(thinSpace)M"
        case 1000...: return "\(formatter.string(from: NSNumber(value: value / 1000)) ?? "")\(thinSpace)k"
        default: return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        }
    }

    /// "12,40 US$"
    public static func money(_ amount: Double, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
    }

    /// "Max 20x", "Pro", "Pro Lite": plan identifiers as people say them.
    public static func planName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return cleaned.split(separator: " ").map { word in
            let lower = word.lowercased()
            if lower.hasSuffix("x"), Int(lower.dropLast()) != nil { return lower }
            if ["ai", "cbp"].contains(lower) { return lower.uppercased() }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }
}
