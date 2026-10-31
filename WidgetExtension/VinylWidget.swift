import SwiftUI
import WidgetKit
import AppIntents
import UIKit

struct VinylWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "VINYL — альбом из коллекции"
    static var description = IntentDescription("Добавь Gist ID из VINYL → Настройки → Виджет")
    @Parameter(title: "Gist ID") var gistID: String
    init() { gistID = "" }
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
        if context.isPreview { return placeholderEntry() }
        let payload = await loadPayload(configuration.gistID)
        return await createEntry(for: .now, payload: payload, seed: configuration.gistID)
    }

    func timeline(for configuration: VinylWidgetConfiguration, in context: Context) async -> Timeline<VinylEntry> {
        let payload = await loadPayload(configuration.gistID)
        let now = Date()
        var dates: [Date] = [now]
        var next = WidgetRotation.nextBoundary(after: now)
        // Precompute future entries: change every 3 hours WITHOUT waking the
        // extension or relying on a background Spotify/API request at each slot.
        for _ in 0..<8 {
            dates.append(next)
            next = WidgetRotation.nextBoundary(after: next.addingTimeInterval(1))
        }
        // Prefetch distinct covers concurrently so a 9-entry timeline does not
        // block on nine sequential HTTP requests. The extension caches images.
        let albums = dates.map { selectAlbum(from: payload, at: $0, seed: configuration.gistID) }
        var prepared: [String: Data] = [:]
        await withTaskGroup(of: (String, Data?).self) { group in
            var seen = Set<String>()
            for album in albums where seen.insert(album.id).inserted {
                group.addTask { (album.id, await artworkData(for: album)) }
            }
            for await (id, data) in group {
                if let data { prepared[id] = data }
            }
        }
        var entries: [VinylEntry] = []
        for (date, album) in zip(dates, albums) {
            let art = prepared[album.id]
            entries.append(VinylEntry(date: date, album: album, imageData: art,
                         background: CoverPalette.from(art.flatMap(UIImage.init(data:))),
                         synced: payload?.library?.isEmpty == false))
        }
        return Timeline(entries: entries, policy: .after(next))
    }

    private func placeholderEntry() -> VinylEntry {
        VinylEntry(date: .now, album: setupAlbum, imageData: nil,
                   background: CoverPalette.fallback, synced: false)
    }

    private var setupAlbum: VinylAlbum {
        VinylAlbum(id: "setup", name: "Открой VINYL", artist: "Настрой библиотеку виджета",
                   year: "", artURL: "", spotifyURL: "")
    }

    private func selectAlbum(from payload: WidgetPayload?, at date: Date, seed: String) -> VinylAlbum {
        guard let payload else { return setupAlbum }
        guard let library = payload.library, !library.isEmpty else {
            // Old Gist v1: keep its actual record, NEVER use the 4 demo albums.
            return payload.album
        }
        if let until = payload.manualUntil, date < until {
            return payload.album
        }
        let ids = library.map(\.id)
        guard let index = WidgetRotation.index(albumIDs: ids, at: date, seed: seed) else {
            return payload.album
        }
        let candidate = library[index]
        // A manually selected album must rotate away when its three-hour
        // window expires (unless there's only one album available).
        if let until = payload.manualUntil, date >= until,
           date < WidgetRotation.nextBoundary(after: until),
           candidate.id == payload.album.id, library.count > 1 {
            return library[(index + 1) % library.count]
        }
        return candidate
    }

    private func loadPayload(_ gistID: String) async -> WidgetPayload? {
        let id = gistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: "^[0-9a-fA-F]{10,64}$", options: .regularExpression) != nil else { return nil }
        let path = cachedPayloadURL(for: id)
        guard let url = URL(string: "https://api.github.com/gists/\(id)") else { return cached(at: path) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VINYL-iOS-widget", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                // Gist was revoked. Don't keep an old collection alive from cache.
                try? FileManager.default.removeItem(at: path)
                return nil
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [String: Any],
                  let file = files["vinyl-widget.json"] as? [String: Any] else {
                return cached(at: path)
            }
            let body: Data?
            if (file["truncated"] as? Bool) == true {
                // GitHub JSON endpoint truncates file content above ~1 MB.
                if let string = file["raw_url"] as? String,
                   let fullURL = URL(string: string), fullURL.scheme == "https",
                   fullURL.host?.hasSuffix("githubusercontent.com") == true,
                   let (raw, reply) = try? await URLSession.shared.data(from: fullURL),
                   (reply as? HTTPURLResponse)?.statusCode == 200 { body = raw }
                else { body = nil }
            } else {
                body = (file["content"] as? String)?.data(using: .utf8)
            }
            if let body, body.count <= 8_000_000,
               let payload = try? JSONDecoder().decode(WidgetPayload.self, from: body),
               (payload.version == 1 || payload.version == 2) {
                try? body.write(to: path, options: .atomic)
                return payload
            }
        } catch { /* Offline: use the last successfully downloaded collection. */ }
        return cached(at: path)
    }

    private func cachedPayloadURL(for id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vinyl_gist_\(id).json")
    }

    private func cached(at path: URL) -> WidgetPayload? {
        guard let data = try? Data(contentsOf: path), data.count <= 8_000_000 else { return nil }
        return try? JSONDecoder().decode(WidgetPayload.self, from: data)
    }

    private func artworkData(for album: VinylAlbum) async -> Data? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safeID = album.id.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
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
        guard let url, url.scheme == "https",
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              UIImage(data: data) != nil else { return try? Data(contentsOf: file) }
        try? data.write(to: file, options: .atomic)
        return data
    }
}

private enum SpotifyWidgetAction {
    static func link(for album: VinylAlbum) -> URL? {
        guard let spotify = album.link,
              spotify.scheme?.lowercased() == "https",
              spotify.host?.lowercased() == "open.spotify.com" else { return nil }
        var url = URLComponents()
        url.scheme = "vinyl-of-day"
        url.host = "open-spotify"
        url.queryItems = [URLQueryItem(name: "url", value: spotify.absoluteString)]
        return url.url
    }
}

struct VinylWidgetView: View {
    let entry: VinylEntry
    @Environment(\.widgetRenderingMode) private var renderingMode

    @ViewBuilder
    private func artworkView(_ image: UIImage) -> some View {
        if #available(iOS 26.0, *) {
            Image(uiImage: image)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFill()
        } else {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let data = entry.imageData, let image = UIImage(data: data) {
                    artworkView(image)
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
                    .widgetAccentable()
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
                HStack(spacing: 3) {
                    if let action = SpotifyWidgetAction.link(for: entry.album) {
                        Link(destination: action) {
                            Label("OPEN IN SPOTIFY", systemImage: "play.fill")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                    }
                    Spacer(minLength: 0)
                    Link(destination: URL(string: "vinyl-of-day://shuffle-widget")!) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 25, height: 28)
                    }
                    .accessibilityLabel("Следующий альбом через VINYL")
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            if renderingMode == .fullColor {
                entry.background.swiftUIColor
            } else {
                // iOS 26 applies clear/tinted Liquid Glass itself.
                Color.clear
            }
        }
    }
}

struct VinylMediumWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "VinylMediumWidget", intent: VinylWidgetConfiguration.self, provider: VinylProvider()) { entry in
            VinylWidgetView(entry: entry)
        }
        .configurationDisplayName("VINYL OF THE DAY")
        .description("Случайный альбом из коллекции каждые 3 часа — укажи Gist ID в настройках")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct VinylWidgetBundle: WidgetBundle {
    var body: some Widget { VinylMediumWidget() }
}
