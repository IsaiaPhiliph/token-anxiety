import Foundation

public struct HistorySample: Codable, Sendable, Hashable {
    public var date: Date
    /// The menu bar's two figures at that moment (five hours, week).
    public var primary: Double?
    public var secondary: Double?

    public init(date: Date, primary: Double?, secondary: Double?) {
        self.date = date
        self.primary = primary
        self.secondary = secondary
    }
}

/// Usage over time, kept on this Mac only, for the panel's seven-day chart.
public struct HistoryLog: Codable, Sendable, Equatable {
    /// Keyed by `ProviderID.rawValue`.
    public private(set) var samples: [String: [HistorySample]] = [:]

    public static let retention: TimeInterval = 30 * 86_400
    /// Unchanged figures are written at most this often.
    public static let spacing: TimeInterval = 10 * 60

    public init() {}

    /// Adds the snapshot's figures; returns whether anything was written.
    @discardableResult
    public mutating func record(_ snapshot: ProviderSnapshot) -> Bool {
        let sample = HistorySample(date: snapshot.fetchedAt,
                                   primary: snapshot.primary?.usedPercent,
                                   secondary: snapshot.secondary?.usedPercent)
        guard sample.primary != nil || sample.secondary != nil else { return false }
        var list = samples[snapshot.provider.rawValue] ?? []
        if let last = list.last {
            guard sample.date > last.date else { return false }
            let moved = Self.differs(last.primary, sample.primary) || Self.differs(last.secondary, sample.secondary)
            if !moved && sample.date.timeIntervalSince(last.date) < Self.spacing { return false }
        }
        list.append(sample)
        let cutoff = snapshot.fetchedAt.addingTimeInterval(-Self.retention)
        list.removeAll { $0.date < cutoff }
        samples[snapshot.provider.rawValue] = list
        return true
    }

    public func samples(for provider: ProviderID, since start: Date) -> [HistorySample] {
        (samples[provider.rawValue] ?? []).filter { $0.date >= start }
    }

    public mutating func removeAll() {
        samples = [:]
    }

    private static func differs(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): false
        case let (a?, b?): abs(a - b) >= 1
        default: true
        }
    }
}

/// Decides which notifications a new snapshot deserves: each threshold once per
/// window cycle, "used up" at 100 %, and "your quota is back" when a window that
/// was nearly spent renews.
public struct AlertTracker: Codable, Sendable, Equatable {
    struct Record: Codable, Sendable, Equatable {
        var resetsAt: Date?
        var highest: Int
        var updated: Date
    }

    private var records: [String: Record] = [:]

    public init() {}

    public struct Event: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case threshold(Int)
            case exhausted
            case renewed
        }

        public var provider: ProviderID
        public var window: UsageWindow
        public var kind: Kind
        public var title: String
        public var body: String

        public init(provider: ProviderID, window: UsageWindow, kind: Kind, title: String, body: String) {
            self.provider = provider
            self.window = window
            self.kind = kind
            self.title = title
            self.body = body
        }
    }

    public mutating func events(for snapshot: ProviderSnapshot, thresholds: [Int], notifyRenewals: Bool,
                                now: Date = Date()) -> [Event] {
        var events: [Event] = []
        let levels = Array(Set(thresholds.filter { $0 > 0 && $0 < 100 } + [100])).sorted()

        for window in snapshot.windows where [.session, .weekly, .monthly].contains(window.kind) {
            let key = "\(snapshot.provider.rawValue).\(window.id)"
            var record = records[key]

            if let previous = record, previous.highest > 0 {
                let resetMoved: Bool = {
                    guard let before = previous.resetsAt, let after = window.resetsAt else { return false }
                    return abs(after.timeIntervalSince(before)) > 3600
                }()
                if resetMoved || window.usedPercent + 25 < Double(previous.highest) {
                    if notifyRenewals, previous.highest >= 95 {
                        events.append(Self.event(.renewed, snapshot.provider, window, now: now))
                    }
                    record = nil
                }
            }

            let reached = levels.last { Double($0) <= window.usedPercent } ?? 0
            if reached > (record?.highest ?? 0) {
                events.append(Self.event(reached >= 100 ? .exhausted : .threshold(reached), snapshot.provider, window, now: now))
            }
            records[key] = Record(resetsAt: window.resetsAt ?? record?.resetsAt,
                                  highest: max(record?.highest ?? 0, reached), updated: now)
        }

        let cutoff = now.addingTimeInterval(-40 * 86_400)
        records = records.filter { $0.value.updated > cutoff }
        return events
    }

    private static func event(_ kind: Event.Kind, _ provider: ProviderID, _ window: UsageWindow, now: Date) -> Event {
        // Whole sentences per window kind: articles and word order differ between languages.
        let name = provider.displayName
        let label = window.label
        let back = window.resetsAt.map { Fmt.moment($0, now: now) }
        switch kind {
        case .threshold(let level):
            let title = switch window.kind {
            case .session: String(localized: "\(name): \(level)% of the 5-hour session")
            case .weekly: String(localized: "\(name): \(level)% of the week")
            case .monthly: String(localized: "\(name): \(level)% of the month")
            default: String(localized: "\(name): \(level)% of \(label)")
            }
            let quip = level >= 90 ? String(localized: "Ration your tokens.") : String(localized: "The anxiety begins.")
            let when = back.map { " " + String(localized: "Resets \($0).") } ?? ""
            return Event(provider: provider, window: window, kind: kind, title: title, body: quip + when)
        case .exhausted:
            let title = switch window.kind {
            case .session: String(localized: "\(name): you've used up the 5-hour session")
            case .weekly: String(localized: "\(name): you've used up the week")
            case .monthly: String(localized: "\(name): you've used up the month")
            default: String(localized: "\(name): you've used up \(label)")
            }
            return Event(provider: provider, window: window, kind: kind, title: title,
                         body: back.map { String(localized: "Go touch grass: it's back \($0).") }
                             ?? String(localized: "Go touch grass for a while."))
        case .renewed:
            let body = switch window.kind {
            case .session: String(localized: "The 5-hour session has reset. Take a deep breath and burn some tokens.")
            case .weekly: String(localized: "The week has reset. Take a deep breath and burn some tokens.")
            case .monthly: String(localized: "The month has reset. Take a deep breath and burn some tokens.")
            default: String(localized: "\(label) has reset. Take a deep breath and burn some tokens.")
            }
            return Event(provider: provider, window: window, kind: kind,
                         title: String(localized: "\(name): your quota is back"), body: body)
        }
    }
}
