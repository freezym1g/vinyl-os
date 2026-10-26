import SwiftUI
import WidgetKit
import AppIntents
import UIKit

private enum WidgetSelection {
    static let indexKey = "vinyl.widget.manualIndex"
    static let dayKey = "vinyl.widget.manualDay"
    static func day() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
    static func index() -> Int {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: dayKey) == day() {
            return (defaults.integer(forKey: indexKey) % PresetRecords.all.count + PresetRecords.all.count) % PresetRecords.all.count
        }
        let ordinal = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return ordinal % PresetRecords.all.count
    }
    static func next() {
        let defaults = UserDefaults.standard
        defaults.set((index() + 1) % PresetRecords.all.count, forKey: indexKey)
        defaults.set(day(), forKey: dayKey)
    }
}

struct NextRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "Следующий альбом"
    static var description = IntentDescription("Переключить альбом во встроенной подборке виджета")

    func perform() async throws -> some IntentResult {
        WidgetSelection.next()
        WidgetCenter.shared.reloadTimelines(ofKind: "VinylMediumWidget")
        return .result()
    }
}

struct VinylEntry: TimelineEntry {
    let date: Date
    let record: PresetRecord
    let imageData: Data?
    let background: RGBColor
}

struct VinylProvider: TimelineProvider {
    func placeholder(in context: Context) -> VinylEntry {
        VinylEntry(date: .now, record: PresetRecords.all[0], imageData: nil,
                   background: CoverPalette.fallback)
    }

    func getSnapshot(in context: Context, completion: @escaping (VinylEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VinylEntry>) -> Void) {
        Task {
            let record = PresetRecords.all[WidgetSelection.index()]
            let data = await fetchCover(for: record)
            let background = CoverPalette.from(data.flatMap(UIImage.init(data:)))
            let entry = VinylEntry(date: .now, record: record, imageData: data, background: background)
            let nextDate = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 1), matchingPolicy: .nextTime)
                ?? Date().addingTimeInterval(24 * 3600)
            completion(Timeline(entries: [entry], policy: .after(nextDate)))
        }
    }

    private func fetchCover(for record: PresetRecord) async -> Data? {
        struct Embed: Decodable { let thumbnail_url: String? }
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: record.link.absoluteString)]
        guard let url = components.url,
              let (json, _) = try? await URLSession.shared.data(from: url),
              let embed = try? JSONDecoder().decode(Embed.self, from: json),
              let str = embed.thumbnail_url, let coverURL = URL(string: str),
              let (data, _) = try? await URLSession.shared.data(from: coverURL) else {
            return nil
        }
        return data
    }
}

struct VinylWidgetView: View {
    let entry: VinylEntry
    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let data = entry.imageData, let picture = UIImage(data: data) {
                    Image(uiImage: picture).resizable().scaledToFit()
                } else {
                    ZStack {
                        Color.white.opacity(0.12)
                        Image(systemName: "opticaldisc").font(.system(size: 36)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(width: 115, height: 115)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 7) {
                Text("TODAY’S RECORD")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
                Text(entry.record.title)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .lineLimit(2).minimumScaleFactor(0.67)
                Text(entry.record.artist)
                    .font(.system(size: 14)).lineLimit(1).minimumScaleFactor(0.75)
                Text(entry.record.year)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Link(destination: entry.record.link) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                            Text("OPEN IN SPOTIFY")
                        }.font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(intent: NextRecordIntent()) {
                        Image(systemName: "shuffle").font(.system(size: 15, weight: .bold))
                            .frame(width: 27, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Следующий альбом")
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .containerBackground(entry.background.swiftUIColor, for: .widget)
    }
}

struct VinylMediumWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VinylMediumWidget", provider: VinylProvider()) { entry in
            VinylWidgetView(entry: entry)
        }
        .configurationDisplayName("VINYL OF THE DAY")
        .description("Альбом дня с переходом в Spotify и кнопкой переключения")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct VinylWidgetBundle: WidgetBundle {
    var body: some Widget { VinylMediumWidget() }
}
