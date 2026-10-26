import Foundation
import SwiftUI
import UIKit

enum CollectionMode: String, CaseIterable, Identifiable {
    case saved = "Моя библиотека"
    case recent = "Недавно слушал"
    case manual = "По ссылкам"
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
    @Published var isLoading = false
    @Published var message: String?
    @Published var accent: RGBColor = CoverPalette.fallback
    @Published var connected = SpotifyAPI.shared.isConnected
    @Published var clientID = SpotifyAPI.shared.clientID
    private let defaults = UserDefaults.standard

    var pool: [VinylAlbum] {
        switch mode {
        case .saved: return saved
        case .recent: return recent
        case .manual: return manual
        }
    }
    var current: VinylAlbum? { pool.first(where: { $0.id == selectedID }) ?? pool.first }

    init() {
        saved = read([VinylAlbum].self, key: "vinyl.saved") ?? []
        recent = read([VinylAlbum].self, key: "vinyl.recent") ?? []
        manual = read([VinylAlbum].self, key: "vinyl.manual") ?? []
        ratings = read([String: Int].self, key: "vinyl.ratings") ?? [:]
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
        if value == 0 { ratings.removeValue(forKey: album.id) }
        else { ratings[album.id] = value }
        store(ratings, key: "vinyl.ratings")
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
        setMode(.manual)
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
        message = errors.isEmpty ? "Синхронизация завершена. Сохранено: \(saved.count), недавно: \(recent.count)." : errors.joined(separator: "\n")
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
