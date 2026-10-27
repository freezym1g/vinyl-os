import Foundation
import SwiftUI
import UIKit
import WidgetKit

enum CollectionMode: String, CaseIterable, Identifiable {
    case saved = "Моя библиотека"
    case recent = "Недавно слушал"
    var id: String { rawValue }
}

@MainActor
final class VinylModel: ObservableObject {
    @Published var saved: [VinylAlbum] = []
    @Published var recent: [VinylAlbum] = []
    @Published var manual: [VinylAlbum] = []
    @Published var selectedID: String = ""
    @Published var mode: CollectionMode = .saved
    @Published var ratings: [String: Int] = [:]
    @Published var ratedSnapshots: [String: VinylAlbum] = [:]
    @Published var widgetGistID: String = GistWidgetSync.shared.gistID
    @Published var widgetBusy = false
    @Published var isLoading = false
    @Published var message: String?
    @Published var accent: RGBColor = CoverPalette.fallback
    @Published var connected = SpotifyAPI.shared.isConnected
    @Published var clientID = SpotifyAPI.shared.clientID
    private let defaults = UserDefaults.standard

    var pool: [VinylAlbum] {
        switch mode {
        case .saved:
            // Links added manually remain available inside the normal library mode.
            var visited = Set<String>()
            return (saved + manual).filter { visited.insert($0.id).inserted }
        case .recent: return recent
        }
    }
    var current: VinylAlbum? { pool.first(where: { $0.id == selectedID }) ?? pool.first }
    var allAlbums: [VinylAlbum] {
        var visited = Set<String>()
        return (saved + manual + recent).filter { visited.insert($0.id).inserted }
    }
    var ratedAlbums: [VinylAlbum] {
        var lookup = ratedSnapshots
        for album in allAlbums { lookup[album.id] = album }
        return ratings.filter { $0.value > 0 }
            .compactMap { lookup[$0.key] }
            .sorted {
                let lhs = ratings[$0.id] ?? 0, rhs = ratings[$1.id] ?? 0
                return lhs == rhs ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : lhs > rhs
            }
    }

    init() {
        saved = read([VinylAlbum].self, key: "vinyl.saved") ?? []
        recent = read([VinylAlbum].self, key: "vinyl.recent") ?? []
        manual = read([VinylAlbum].self, key: "vinyl.manual") ?? []
        ratings = read([String: Int].self, key: "vinyl.ratings") ?? [:]
        ratedSnapshots = read([String: VinylAlbum].self, key: "vinyl.rated.snapshots") ?? [:]
        mode = CollectionMode(rawValue: defaults.string(forKey: "vinyl.mode") ?? "") ?? .saved
        selectedID = defaults.string(forKey: "vinyl.selected") ?? ""
        selectDailyIfNeeded()
        Task { await updateAccent() }
    }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func store<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    func selectDailyIfNeeded() {
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        let key = "vinyl.day.\(mode.rawValue)"
        if defaults.string(forKey: key) != date || !pool.contains(where: { $0.id == selectedID }) {
            if let pick = pool.randomElement() { select(pick) }
            defaults.set(date, forKey: key)
        }
    }

    func setMode(_ value: CollectionMode) {
        mode = value
        defaults.set(value.rawValue, forKey: "vinyl.mode")
        selectedID = ""
        selectDailyIfNeeded()
        Task { await updateAccent() }
    }

    func select(_ album: VinylAlbum) {
        selectedID = album.id
        defaults.set(album.id, forKey: "vinyl.selected")
        Task { await updateAccent() }
    }
    func shuffle() {
        let options = pool.filter { $0.id != current?.id }
        if let pick = (options.isEmpty ? pool : options).randomElement() { select(pick) }
    }
    func rate(_ value: Int, album: VinylAlbum) {
        if value == 0 {
            ratings.removeValue(forKey: album.id)
            ratedSnapshots.removeValue(forKey: album.id)
        } else {
            ratings[album.id] = min(10, max(1, value))
            ratedSnapshots[album.id] = album
        }
        store(ratings, key: "vinyl.ratings")
        store(ratedSnapshots, key: "vinyl.rated.snapshots")
    }

    func saveGitHubToken(_ value: String) {
        do {
            try GistWidgetSync.shared.setToken(value)
            message = "GitHub-токен сохранён в Keychain. Теперь выбери альбом и нажми «Добавить в виджет»."
        } catch { message = error.localizedDescription }
    }

    @discardableResult
    func publishToWidget(_ album: VinylAlbum) async -> Bool {
        guard !widgetBusy else { return false }
        widgetBusy = true
        defer { widgetBusy = false }
        do {
            let id = try await GistWidgetSync.shared.publish(album: album)
            widgetGistID = id
            message = "«\(album.name)» отправлен в виджет. Если ещё не настроил виджет, скопируй Gist ID в Настройки → Виджет и укажи его в настройках виджета на домашнем экране."
            // Requesting an update is safe, but iOS decides when to draw it.
            WidgetCenter.shared.reloadTimelines(ofKind: "VinylMediumWidget")
            return true
        } catch {
            message = "Виджет: \(error.localizedDescription)"
            return false
        }
    }

    func nextWidgetAlbum() async {
        let candidates = allAlbums.filter { $0.id != (UserDefaults.standard.string(forKey: "vinyl.widget.lastAlbumID") ?? "") }
        let chosen = (candidates.isEmpty ? allAlbums : candidates).randomElement()
        guard let album = chosen else {
            message = "Сначала синхронизируй Spotify или добавь альбом по ссылке."
            return
        }
        if await publishToWidget(album) {
            UserDefaults.standard.set(album.id, forKey: "vinyl.widget.lastAlbumID")
        }
    }

    func addManual(spotifyLink: String, title: String, artist: String, year: String) async {
        guard let incoming = URL(string: spotifyLink.trimmingCharacters(in: .whitespacesAndNewlines)),
              incoming.host == "open.spotify.com",
              incoming.pathComponents.filter({ $0 != "/" }).first == "album",
              incoming.pathComponents.filter({ $0 != "/" }).count >= 2 else {
            message = "Вставь ссылку на альбом вида https://open.spotify.com/album/..."
            return
        }
        let albumID = incoming.pathComponents.filter { $0 != "/" }[1]
        let cleanURL = "https://open.spotify.com/album/\(albumID)"
        var cover = ""
        var suggestedTitle = ""
        var urlParts = URLComponents(string: "https://open.spotify.com/oembed")!
        urlParts.queryItems = [URLQueryItem(name: "url", value: cleanURL)]
        if let url = urlParts.url,
           let (data, _) = try? await URLSession.shared.data(from: url),
           let result = try? JSONDecoder().decode(OEmbedAlbum.self, from: data) {
            cover = result.thumbnail_url ?? ""
            suggestedTitle = result.title
        }
        let record = VinylAlbum(id: albumID, name: title.isEmpty ? (suggestedTitle.isEmpty ? "Spotify Album" : suggestedTitle) : title,
                                artist: artist.isEmpty ? "Исполнитель" : artist,
                                year: year.isEmpty ? "—" : year,
                                artURL: cover, spotifyURL: cleanURL)
        manual.removeAll { $0.id == albumID }
        manual.insert(record, at: 0)
        store(manual, key: "vinyl.manual")
        setMode(.saved)
        select(record)
        message = "Альбом добавлен по ссылке."
    }

    func removeManual(_ album: VinylAlbum) {
        manual.removeAll { $0.id == album.id }
        store(manual, key: "vinyl.manual")
        if selectedID == album.id { selectedID = ""; selectDailyIfNeeded() }
    }

    func setClientID() {
        SpotifyAPI.shared.clientID = clientID
        message = "Client ID сохранён на устройстве."
    }
    func login() async {
        isLoading = true
        defer { isLoading = false }
        do {
            SpotifyAPI.shared.clientID = clientID
            try await SpotifyAPI.shared.connect()
            connected = true
            await synchronize()
        } catch { message = error.localizedDescription }
    }
    func logout() {
        SpotifyAPI.shared.disconnect()
        connected = false
        message = "Spotify отключён. Сохранённые альбомы и оценки не удалены."
    }
    func synchronize() async {
        guard SpotifyAPI.shared.isConnected else {
            message = "Подключи Spotify в настройках."
            return
        }
        isLoading = true
        defer { isLoading = false }
        var errors: [String] = []
        do {
            saved = try await SpotifyAPI.shared.savedAlbums()
            store(saved, key: "vinyl.saved")
        } catch { errors.append("Библиотека: \(error.localizedDescription)") }
        do {
            recent = try await SpotifyAPI.shared.recentAlbums()
            store(recent, key: "vinyl.recent")
        } catch { errors.append("История: \(error.localizedDescription)") }
        selectDailyIfNeeded()
        await updateAccent()
        let skipped = SpotifyAPI.shared.skippedSaved + SpotifyAPI.shared.skippedRecent
        let summary = "Синхронизация завершена. Сохранено: \(saved.count), недавно: \(recent.count)." + (skipped > 0 ? " Пропущено неполных записей: \(skipped)." : "")
        message = errors.isEmpty ? summary : errors.joined(separator: "\n")
    }
    func updateAccent() async {
        guard let url = current?.artwork else { accent = CoverPalette.fallback; return }
        let selected = current?.id
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data), current?.id == selected else { return }
        accent = CoverPalette.from(image)
    }
}

private struct OEmbedAlbum: Decodable {
    let title: String
    let thumbnail_url: String?
}
