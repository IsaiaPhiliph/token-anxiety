import Foundation

/// Formatting for everything the app shows, in the app's language (English, or
/// Spanish when the Mac prefers it) with the Mac's region.
public enum Fmt {
    /// The language macOS picked among the app's localizations, with the user's region.
    public static let locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: "\(language)_\(region)")
    }()

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = .current
        return calendar
    }

    /// "34%" in English, "34 %" in Spanish.
    public static func percent(_ value: Double) -> String {
        (value.rounded() / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "34%", for the menu bar where every point of width counts.
    public static func compactPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "2 h 14 min", "3 days", "45 min", "less than 1 min".
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days >= 2 {
            let rounded = hours >= 12 ? days + 1 : days
            return String(localized: "\(rounded) days")
        }
        if days == 1 { return hours > 0 ? String(localized: "1 day and \(hours) h") : String(localized: "1 day") }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return "\(minutes) min" }
        return String(localized: "less than 1 min")
    }

    /// "3:30 PM", "15:30".
    public static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar))
    }

    /// "Thursday"
    public static func weekday(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.wide))
    }

    /// "November 10", "10 de noviembre".
    public static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter.string(from: date)
    }

    /// "today at 3:30 PM", "tomorrow at 9:00 AM", "on Thursday at 9:00 AM", "on November 10".
    public static func moment(_ date: Date, now: Date = Date()) -> String {
        let calendar = calendar
        let time = time(date)
        // Spanish says "a la 1:00" but "a las 2:00".
        let one = calendar.component(.hour, from: date) == 1
        if calendar.isDate(date, inSameDayAs: now) {
            return one ? String(localized: "today at \(time) (one o'clock)") : String(localized: "today at \(time)")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return one ? String(localized: "tomorrow at \(time) (one o'clock)") : String(localized: "tomorrow at \(time)")
        }
        if date.timeIntervalSince(now) < 6 * 86_400, date > now {
            let weekday = weekday(date)
            return one ? String(localized: "on \(weekday) at \(time) (one o'clock)") : String(localized: "on \(weekday) at \(time)")
        }
        return String(localized: "on \(day(date))")
    }

    /// "Resets in 2 h 14 min (3:30 PM)" / "Resets on Thursday at 9:00 AM".
    public static func resetLine(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return String(localized: "Resetting now") }
        if remaining < 12 * 3600 { return String(localized: "Resets in \(duration(remaining)) (\(time(date)))") }
        return String(localized: "Resets \(moment(date, now: now))")
    }

    /// "just now", "3 min ago", "2 h ago", "3 days ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return String(localized: "just now") }
        if seconds < 3600 { return String(localized: "\(max(1, Int((seconds / 60).rounded()))) min ago") }
        if seconds < 86_400 { return String(localized: "\(Int(seconds / 3600)) h ago") }
        let days = Int(seconds / 86_400)
        return days == 1 ? String(localized: "1 day ago") : String(localized: "\(days) days ago")
    }

    /// "12.4M", "850K", "3.1B" in English; "12,4 M", "850 mil", "3,1 mil M" in Spanish
    /// (macOS's own compact style writes "3056,8 M" there). Separators follow the region.
    public static func tokens(_ value: Double) -> String {
        tokens(value, locale: locale)
    }

    static func tokens(_ value: Double, locale: Locale) -> String {
        let spanish = locale.language.languageCode?.identifier == "es"
        let magnitude = abs(value)
        let (scaled, suffix): (Double, String) = switch magnitude {
        case 1e9...: (value / 1e9, spanish ? "\u{00A0}mil\u{00A0}M" : "B")
        case 1e6...: (value / 1e6, spanish ? "\u{00A0}M" : "M")
        case 1e3...: (value / 1e3, spanish ? "\u{00A0}mil" : "K")
        default: (value, "")
        }
        // One decimal while it says something: 12.4M, but 125M.
        let digits = suffix.isEmpty || abs(scaled) >= 100 ? 0 : 1
        return scaled.formatted(.number.precision(.fractionLength(0...digits)).grouping(.automatic).locale(locale)) + suffix
    }

    /// "$12.40", "12,40 US$".
    public static func money(_ amount: Double, currency: String = "USD") -> String {
        amount.formatted(.currency(code: currency).locale(locale))
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
