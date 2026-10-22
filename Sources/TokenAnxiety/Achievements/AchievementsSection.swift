import SwiftUI
import TokenAnxietyCore

/// Medal colours: bronze, silver, gold, platinum, legendary. A one-tier achievement is gold.
enum TierStyle {
    static func colors(_ tier: Int, of tiers: Int) -> [Color] {
        let level = tiers == 1 && tier == 1 ? 3 : tier
        switch level {
        case 1: return [Color(red: 0.86, green: 0.55, blue: 0.30), Color(red: 0.62, green: 0.35, blue: 0.16)]
        case 2: return [Color(red: 0.86, green: 0.88, blue: 0.92), Color(red: 0.56, green: 0.60, blue: 0.67)]
        case 3: return [Color(red: 1.00, green: 0.84, blue: 0.30), Color(red: 0.85, green: 0.58, blue: 0.05)]
        case 4: return [Color(red: 0.70, green: 0.93, blue: 0.97), Color(red: 0.32, green: 0.62, blue: 0.80)]
        case 5...: return [Color(red: 0.98, green: 0.45, blue: 0.85), Color(red: 0.48, green: 0.25, blue: 0.95)]
        default: return [Color.primary.opacity(0.12), Color.primary.opacity(0.06)]
        }
    }
}

struct AchievementMedal: View {
    let achievement: Achievement
    let tier: Int
    var size: CGFloat = 46

    var body: some View {
        let hidden = achievement.secret && tier == 0
        ZStack {
            Circle()
                .fill(LinearGradient(colors: TierStyle.colors(tier, of: achievement.tiers.count),
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .strokeBorder(Color.white.opacity(tier > 0 ? 0.45 : 0.08), lineWidth: 1.5)
                .padding(3)
            Image(systemName: hidden ? "questionmark" : achievement.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tier > 0 ? Color.white : Color.secondary)
                .shadow(color: .black.opacity(tier > 0 ? 0.25 : 0), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: tier > 0 ? TierStyle.colors(tier, of: achievement.tiers.count)[1].opacity(0.45) : .clear, radius: 5, y: 2)
    }
}

/// One achievement: medal, what it takes, how far along you are.
struct AchievementCard: View {
    let achievement: Achievement
    let earned: AchievementBook.Earned?
    let value: Double
    let isNew: Bool

    var body: some View {
        let tier = earned?.tier ?? 0
        let hidden = achievement.secret && tier == 0
        let done = tier == achievement.tiers.count
        let goal = achievement.tiers[min(tier, achievement.tiers.count - 1)]
        HStack(alignment: .top, spacing: 12) {
            AchievementMedal(achievement: achievement, tier: tier)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(hidden ? "???" : achievement.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if achievement.isTiered, tier > 0 {
                        Text(Tier.name(tier))
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(TierStyle.colors(tier, of: achievement.tiers.count)[1].opacity(0.3)))
                    }
                    if isNew {
                        Text("New")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                    }
                }
                Text(hidden ? String(localized: "A secret achievement. Keep using AI and you'll find it.")
                            : achievement.detail(goal: goal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !hidden && !done {
                    HStack(spacing: 6) {
                        UsageBar(value: min(100, value / goal * 100), tint: .accentColor, height: 4)
                        Text("\(achievement.unit.format(min(value, goal))) / \(achievement.unit.format(goal))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.top, 2)
                }
                HStack(spacing: 6) {
                    if achievement.isTiered {
                        HStack(spacing: 3) {
                            ForEach(1...achievement.tiers.count, id: \.self) { index in
                                Circle()
                                    .fill(index <= tier ? TierStyle.colors(index, of: achievement.tiers.count)[0] : Color.primary.opacity(0.12))
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                    if let date = earned?.dates.last {
                        Text(done ? String(localized: "Completed \(Fmt.day(date))") : String(localized: "Earned \(Fmt.day(date))"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(tier > 0 ? 0.6 : 0.35)))
        .opacity(tier > 0 || !hidden ? 1 : 0.75)
    }
}

struct AchievementsSection: View {
    let store: AchievementStore
    /// What was new when the section opened, so the badges stay while you look.
    @State private var fresh: Set<String> = []

    var body: some View {
        let book = store.book
        let all = AchievementCatalog.all
        let unlocked = all.filter { book.tier($0.id) > 0 }.count
        let tiers = all.reduce(0) { $0 + $1.tiers.count }
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(unlocked) of \(all.count) achievements")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("\(book.earnedTiers) of \(tiers) medals, counting each tier")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    UsageBar(value: Double(book.earnedTiers) / Double(tiers) * 100, tint: .yellow, height: 6)
                        .frame(maxWidth: 320)
                        .padding(.top, 4)
                }
                Spacer()
                HStack(spacing: -8) {
                    ForEach(latest(book), id: \.id) { achievement in
                        AchievementMedal(achievement: achievement, tier: book.tier(achievement.id), size: 40)
                            .help(achievement.title)
                    }
                }
            }
            ForEach(AchievementCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 10) {
                    Text(category.title)
                        .font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(all.filter { $0.category == category }) { achievement in
                            AchievementCard(achievement: achievement, earned: book.earned[achievement.id],
                                            value: achievement.value(store.facts), isNew: fresh.contains(achievement.id))
                        }
                    }
                }
            }
            Text("Achievements are kept even when the logs that earned them are gone. The ones about limits count from the day Token Anxiety started watching.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            fresh = book.unseen
            store.markSeen()
        }
    }

    /// The last few earned, newest first.
    private func latest(_ book: AchievementBook) -> [Achievement] {
        AchievementCatalog.all
            .compactMap { achievement in book.earned[achievement.id]?.dates.last.map { (achievement, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map(\.0)
    }
}
