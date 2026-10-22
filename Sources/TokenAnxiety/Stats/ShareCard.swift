import AppKit
import SwiftUI
import TokenAnxietyCore

enum ShareTemplate: String, CaseIterable, Identifiable {
    case activity, achievements

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: String(localized: "My year with AI")
        case .achievements: String(localized: "My achievements")
        }
    }
}

/// The image people share: 1200 × 630 points, dark, with no project names.
struct ShareCardView: View {
    let template: ShareTemplate
    let ledger: UsageLedger
    let book: AchievementBook
    let showCost: Bool
    let now: Date

    static let size = CGSize(width: 1200, height: 630)

    var body: some View {
        let calendar = Fmt.calendar
        let start = calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: now)) ?? now
        let year = DateInterval(start: start, end: now)
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 14) {
                Image(nsImage: ProviderGlyph.image(nil, size: 26, color: .white))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.orange.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.title).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Token Anxiety · \(Self.longDay(start)) – \(Self.longDay(now))")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            switch template {
            case .activity: activity(year)
            case .achievements: achievements
            }
            Spacer(minLength: 0)
            Text(verbatim: "github.com/IsaiaPhiliph/token-anxiety")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(48)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.16), Color(red: 0.18, green: 0.10, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .environment(\.colorScheme, .dark)
    }

    private func activity(_ year: DateInterval) -> some View {
        let calendar = Fmt.calendar
        let totals = ledger.totals(in: year)
        let streaks = ledger.streaks(now: now, calendar: calendar)
        let days = ledger.daily(in: year, calendar: calendar)
        let favourite = ledger.grouped(in: year) { ModelNames.display($0.model) }.max { $0.value.counts.total < $1.value.counts.total }?.key
        var figures: [(String, String)] = [
            (String(localized: "Tokens"), Fmt.tokens(Double(totals.counts.total))),
            (String(localized: "Active days"), "\(days.values.filter { $0.counts.requests > 0 }.count)"),
            (String(localized: "Best streak"), String(localized: "\(streaks.longest) days")),
            (String(localized: "Favourite model"), favourite ?? "–"),
        ]
        if showCost { figures.insert((String(localized: "≈ API value"), Fmt.money(totals.cost)), at: 1) }
        return VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .top, spacing: 44) {
                ForEach(figures, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value).font(.system(size: 38, weight: .semibold, design: .rounded)).lineLimit(1)
                        Text(label).font(.system(size: 16)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            ActivityHeatmap(values: days.mapValues { Double($0.counts.total) }, calendar: calendar, now: now,
                            format: { Fmt.tokens($0) }, maxCell: 18)
        }
    }

    private var achievements: some View {
        let earned = AchievementCatalog.all
            .filter { book.tier($0.id) > 0 }
            .sorted { (book.tier($0.id), $0.tiers.count) > (book.tier($1.id), $1.tiers.count) }
        return VStack(alignment: .leading, spacing: 26) {
            Text("\(earned.count) of \(AchievementCatalog.all.count) achievements · \(book.earnedTiers) medals")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 6), alignment: .leading, spacing: 20) {
                ForEach(earned.prefix(12)) { achievement in
                    VStack(spacing: 8) {
                        AchievementMedal(achievement: achievement, tier: book.tier(achievement.id), size: 64)
                        Text(achievement.title)
                            .font(.system(size: 14, weight: .medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        if achievement.isTiered {
                            Text(Tier.name(book.tier(achievement.id)))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    static func longDay(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(Fmt.locale))
    }

    /// A PNG at twice the size, for sharp images.
    @MainActor
    func png() -> Data? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        // The renderer draws 16 bits per channel with alpha (11 MB); 8-bit opaque sRGB is plenty.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])
    }
}

/// Choose a card, look at it, save it.
struct ShareSheet: View {
    let store: UsageStore
    let dismiss: () -> Void

    @AppStorage("share.template") private var template: ShareTemplate = .activity
    @AppStorage("share.cost") private var showCost = true
    @State private var saved: URL?

    var body: some View {
        let card = ShareCardView(template: template, ledger: store.usage.ledger, book: store.achievements.book,
                                 showCost: showCost, now: Date())
        VStack(alignment: .leading, spacing: 14) {
            Text("Share card").font(.title2.weight(.semibold))
            card
                .scaleEffect(0.5, anchor: .topLeading)
                .frame(width: ShareCardView.size.width / 2, height: ShareCardView.size.height / 2, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 16) {
                Picker("Card", selection: $template) {
                    ForEach(ShareTemplate.allCases) { template in Text(template.title).tag(template) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Toggle("Show the API value", isOn: $showCost)
                    .disabled(template != .activity)
            }
            Text("Made on this Mac: no project names, no accounts, nothing uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let saved {
                    Label(String(localized: "Saved as \(saved.lastPathComponent)"), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: dismiss)
                Button("Save as PNG…") { save(card) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: ShareCardView.size.width / 2 + 40)
    }

    private func save(_ card: ShareCardView) {
        guard let data = card.png() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "token-anxiety-\(template.rawValue).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            saved = url
            store.achievements.shareExported()
        } catch {
            saved = nil
        }
    }
}
