import SwiftUI
import WidgetKit
import AppIntents
import UIKit

// Each widget can be configured with the Gist ID shown in VINYL settings.
// App Groups are intentionally NOT used: this works with free sideload signing.
struct VinylWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "VINYL — выбранный альбом"
    static var description = IntentDescription("Вставь Gist ID из VINYL → Настройки → Виджет")

    @Parameter(title: "Gist ID")
    var gistID: String

    init() { gistID = "" }
}

private enum WidgetFallback {
    private static let indexKey = "vinyl.widget.manualIndex"
    private static let dayKey = "vinyl.widget.manualDay"

    private static func day() -> String {
        let d = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return "\(d.year ?? 0)-\(d.month ?? 0)-\(d.day ?? 0)"
    }
    static func index() -> Int {
        let count = PresetRecords.all.count
        let defaults = UserDefaults.standard // Widget extension's own sandbox.
        if defaults.string(forKey: dayKey) == day() {
            return (defaults.integer(forKey: indexKey) % count + count) % count
        }
        let ordinal = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        return ordinal % count
    }
    static func next() {
        UserDefaults.standard.set((index() + 1) % PresetRecords.all.count, forKey: indexKey)
        UserDefaults.standard.set(day(), forKey: dayKey)
    }
    static var current: VinylAlbum {
        let item = PresetRecords.all[index()]
        return VinylAlbum(id: item.id, name: item.title, artist: item.artist,
                          year: item.year, artURL: "", spotifyURL: item.link.absoluteString)
    }
}

struct NextLocalRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "Следующий альбом"
    func perform() async throws -> some IntentResult {
        WidgetFallback.next()
        WidgetCenter.shared.reloadTimelines(ofKind: "VinylMediumWidget")
        return .result()
    }
}

struct VinylEntry: TimelineEntry {
    let date: Date
    let album: VinylAlbum
    let imageData: Data?
    let background: RGBColor
    let synced: Bool
}

struct VinylProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VinylEntry { placeholderEntry() }

    func snapshot(for configuration: VinylWidgetConfiguration, in context: Context) async -> VinylEntry {
        await loadEntry(gistID: configuration.gistID, preview: context.isPreview)
    }

    func timeline(for configuration: VinylWidgetConfiguration, in context: Context) async -> Timeline<VinylEntry> {
        let entry = await loadEntry(gistID: configuration.gistID, preview: false)
        // iOS may defer reload; this is a request, not an exact schedule.
        let refresh = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    private func placeholderEntry() -> VinylEntry {
        VinylEntry(date: .now, album: WidgetFallback.current, imageData: nil,
                   background: CoverPalette.fallback, synced: false)
    }

    private func loadEntry(gistID: String, preview: Bool) async -> VinylEntry {
        if preview { return placeholderEntry() }
        let id = gistID.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValid = id.range(of: "^[0-9a-fA-F]{10,64}$", options: .regularExpression) != nil
        let album: VinylAlbum
        let synced: Bool
        if isValid {
            let downloaded = await readGist(id)
            if let downloaded {
                album = downloaded
                cacheAlbum(downloaded, gistID: id)
                synced = true
            } else if let cached = cachedAlbum(gistID: id) {
                album = cached
                synced = true
            } else {
                album = WidgetFallback.current
                synced = false
            }
        } else {
            album = WidgetFallback.current
            synced = false
        }
        let artwork = await artworkData(for: album)
        return VinylEntry(date: .now, album: album, imageData: artwork,
                          background: CoverPalette.from(artwork.flatMap(UIImage.init(data:))), synced: synced)
    }

    private func readGist(_ id: String) async -> VinylAlbum? {
        guard let url = URL(string: "https://api.github.com/gists/\(id)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VINYL-iOS-widget", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [String: Any],
              let file = files["vinyl-widget.json"] as? [String: Any],
              let content = file["content"] as? String,
              let body = content.data(using: .utf8),
              let payload = try? JSONDecoder().decode(WidgetPayload.self, from: body),
              payload.version == 1 else { return nil }
        return payload.album
    }

    private func cacheAlbum(_ album: VinylAlbum, gistID: String) {
        guard let data = try? JSONEncoder().encode(album) else { return }
        UserDefaults.standard.set(data, forKey: "vinyl.gist.cached.\(gistID)")
    }

    private func cachedAlbum(gistID: String) -> VinylAlbum? {
        guard let data = UserDefaults.standard.data(forKey: "vinyl.gist.cached.\(gistID)") else { return nil }
        return try? JSONDecoder().decode(VinylAlbum.self, from: data)
    }

    private func artworkData(for album: VinylAlbum) async -> Data? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safeID = album.id.filter { $0.isASCII && $0.isLetter || $0.isNumber }
        let file = directory.appendingPathComponent("vinyl_\(safeID).jpg")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let date = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < 7 * 24 * 3600,
           let data = try? Data(contentsOf: file) { return data }

        var url = album.artwork
        if url == nil || album.artURL.isEmpty {
            struct Embed: Decodable { let thumbnail_url: String? }
            var components = URLComponents(string: "https://open.spotify.com/oembed")!
            components.queryItems = [URLQueryItem(name: "url", value: album.spotifyURL)]
            if let requestURL = components.url,
               let (data, _) = try? await URLSession.shared.data(from: requestURL),
               let embed = try? JSONDecoder().decode(Embed.self, from: data),
               let str = embed.thumbnail_url { url = URL(string: str) }
        }
        guard let url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              UIImage(data: data) != nil else { return try? Data(contentsOf: file) }
        try? data.write(to: file, options: .atomic)
        return data
    }
}

struct VinylWidgetView: View {
    let entry: VinylEntry

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let data = entry.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.1)
                        Image(systemName: "opticaldisc").font(.system(size: 38))
                    }
                }
            }
            .frame(width: 115, height: 115)
            .clipShape(RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 6) {
                Text("TODAY’S RECORD")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
                Text(entry.album.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(2).minimumScaleFactor(0.67)
                Text(entry.album.artist)
                    .font(.system(size: 14)).lineLimit(1).minimumScaleFactor(0.75)
                Text(entry.album.year)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if let spotify = entry.album.link {
                        Link(destination: spotify) {
                            Label("OPEN IN SPOTIFY", systemImage: "play.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    Spacer(minLength: 0)
                    if entry.synced {
                        // Launches the containing app, which publishes the next album.
                        // This is essential because free signing has no App Groups.
                        Link(destination: URL(string: "vinyl-of-day://shuffle-widget")!) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("Следующий альбом через VINYL")
                    } else {
                        Button(intent: NextLocalRecordIntent()) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Следующий альбом")
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(entry.background.swiftUIColor, for: .widget)
    }
}

struct VinylMediumWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "VinylMediumWidget", intent: VinylWidgetConfiguration.self, provider: VinylProvider()) { entry in
            VinylWidgetView(entry: entry)
        }
        .configurationDisplayName("VINYL OF THE DAY")
        .description("Выбранный альбом из приложения VINYL — GitHub Gist ID в настройках виджета")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct VinylWidgetBundle: WidgetBundle {
    var body: some Widget { VinylMediumWidget() }
}
