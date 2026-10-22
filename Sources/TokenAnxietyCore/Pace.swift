import Foundation

/// How fast a window is being spent compared with an even pace: at the 40 %
/// mark of a week, an even pace has used 40 % of the allowance.
public struct Pace: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// Already at 100 %.
        case exhausted
        /// At the current average rate, 100 % arrives before the reset.
        case runsOut(Date)
        /// Above the even pace, but still under 100 % at the reset.
        case ahead
        case onTrack
        /// Well below the even pace.
        case relaxed
    }

    /// Where an even pace would be now, 0…100.
    public let expectedPercent: Double
    /// Points above (+) or below (−) the even pace.
    public let delta: Double
    /// Where the window ends at the current average rate.
    public let projectedPercent: Double
    public let resetsAt: Date
    public let verdict: Verdict

    /// Nothing is judged during the first 3 % of a window (five hours of a week):
    /// one early session would otherwise read as a disaster.
    public static let warmUp = 0.03

    public static func evaluate(_ window: UsageWindow, now: Date = Date()) -> Pace? {
        guard let resetsAt = window.resetsAt, let duration = window.duration, duration > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let elapsed = min(duration, max(0, duration - remaining))
        let expected = elapsed / duration * 100
        let used = window.usedPercent

        if used >= 100 {
            return Pace(expectedPercent: expected, delta: used - expected, projectedPercent: used,
                        resetsAt: resetsAt, verdict: .exhausted)
        }
        guard elapsed >= duration * warmUp else { return nil }

        let rate = used / elapsed
        let projected = used + rate * remaining
        let delta = used - expected
        let verdict: Verdict
        if rate > 0, projected >= 100 {
            verdict = .runsOut(now.addingTimeInterval((100 - used) / rate))
        } else if delta > 5 {
            verdict = .ahead
        } else if delta < -10 {
            verdict = .relaxed
        } else {
            verdict = .onTrack
        }
        return Pace(expectedPercent: expected, delta: delta, projectedPercent: projected,
                    resetsAt: resetsAt, verdict: verdict)
    }

    /// "+8 pts", "−12 pts", "on pace".
    public var deltaText: String {
        let points = Int(delta.rounded())
        if points == 0 { return String(localized: "on pace") }
        return points > 0 ? "+\(points) pts" : "−\(-points) pts"
    }

    public func summary(now: Date = Date()) -> String {
        let projected = Fmt.percent(min(projectedPercent, 999))
        switch verdict {
        case .exhausted: return String(localized: "Used up. Back \(Fmt.moment(resetsAt, now: now)).")
        case .runsOut(let date): return String(localized: "At this pace you'll hit 100% \(Fmt.moment(date, now: now)).")
        case .ahead: return String(localized: "Above pace, but you'll make it: you'd end at \(projected).")
        case .onTrack: return String(localized: "On pace: you'd end at \(projected).")
        case .relaxed: return String(localized: "Plenty of room: you'd end at \(projected).")
        }
    }

    public var isWorrying: Bool {
        switch verdict {
        case .exhausted, .runsOut: true
        default: false
        }
    }
}
