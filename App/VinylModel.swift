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
    // Rich reviews are stored separately: existing 1–10 ratings remain compatible.
    @Published private(set) var reviews: [String: AlbumReview] = [:]
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
        reviews = read([String: AlbumReview].self, key: "vinyl.album.reviews.v1") ?? [:]
        // Reviews from previous updates don't override newer legacy scores.
        for (id, review) in reviews where ratings[id] == nil {
            ratings[id] = review.score
        }
        mode = CollectionMode(rawValue: defaults.string(forKey: "vinyl.mode") ?? "") ?? .saved
        // Migrate the old single selection into whichever source was active.
        // Never overwrite a source-specific selection when upgrading.
        let legacyID = defaults.string(forKey: "vinyl.selected") ?? ""
        let initialKey = selectionKey(for: mode)
        if defaults.string(forKey: initialKey) == nil && !legacyID.isEmpty {
            defaults.set(legacyID, forKey: initialKey)
        }
        selectedID = defaults.string(forKey: initialKey) ?? ""
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

    // The two sources must remember their selections independently. The
    // single `vinyl.selected` key is retained for older app data/compatibility.
    private func selectionKey(for source: CollectionMode) -> String {
        switch source {
        case .saved: return "vinyl.selected.saved"
        case .recent: return "vinyl.selected.recent"
        }
    }

    private func dateKey(for source: CollectionMode) -> String {
        "vinyl.day.\(source.rawValue)"
    }

    private func todayStamp() -> String {
        // Stable calendar date, independent of user language or date-format settings.
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    // Called at application launch: choose a new record at most once per day
    // for the currently active source. Changing tabs NEVER calls this method.
    func selectDailyIfNeeded() {
        let key = dateKey(for: mode)
        let stamp = todayStamp()
        let legacyStamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        let storedStamp = defaults.string(forKey: key)
        let sameDay = storedStamp == stamp || storedStamp == legacyStamp
        if !sameDay || !pool.contains(where: { $0.id == selectedID }) {
            if let pick = pool.randomElement() { select(pick) }
        }
        defaults.set(stamp, forKey: key)
    }

    // After a refresh or a source change, only choose a new record if the
    // previous one is genuinely unavailable. Never reshuffle on tab switches.
    private func restoreValidSelection() {
        guard !pool.contains(where: { $0.id == selectedID }) else { return }
        if let first = pool.first { select(first) }
        else { selectedID = "" }
    }

    func setMode(_ value: CollectionMode) {
        guard mode != value else { return }
        if !selectedID.isEmpty {
            defaults.set(selectedID, forKey: selectionKey(for: mode))
        }
        mode = value
        defaults.set(value.rawValue, forKey: "vinyl.mode")
        selectedID = defaults.string(forKey: selectionKey(for: value)) ?? ""
        restoreValidSelection()
        // The initial selection for a source should also survive a later
        // visit on the same or another day; automatic rotation is app-launch only.
        defaults.set(todayStamp(), forKey: dateKey(for: value))
        Task { await updateAccent() }
    }

    func select(_ album: VinylAlbum) {
        selectedID = album.id
        defaults.set(album.id, forKey: selectionKey(for: mode))
        defaults.set(album.id, forKey: "vinyl.selected")
        Task { await updateAccent() }
    }
    func shuffle() {
        let options = pool.filter { $0.id != current?.id }
        if let pick = (options.isEmpty ? pool : options).randomElement() { select(pick) }
    }
    // Legacy ratings from VINYL 1.2 show up as reviews without an invented date.
    // Their date is set when the user first saves a full review in VINYL 1.3.
    func review(for album: VinylAlbum) -> AlbumReview? {
        if let review = reviews[album.id] { return review }
        guard let score = ratings[album.id], (1...10).contains(score) else { return nil }
        return AlbumReview(score: score, bestTracks: [], comment: "", ratedAt: nil, updatedAt: nil)
    }

    func saveReview(score: Int, bestTracks: [ReviewTrack], comment: String, for album: VinylAlbum) {
        guard (1...10).contains(score) else { return }
        let now = Date()
        // Preserve original review date when editing; never pretend to know the
        // original date for 1.2.x ratings that did not store a timestamp.
        let firstDate = reviews[album.id]?.ratedAt ?? now
        let cleanComment = String(comment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        let review = AlbumReview(score: score, bestTracks: bestTracks, comment: cleanComment,
                                 ratedAt: firstDate, updatedAt: now)
        reviews[album.id] = review
        ratings[album.id] = score
        ratedSnapshots[album.id] = album
        store(reviews, key: "vinyl.album.reviews.v1")
        store(ratings, key: "vinyl.ratings")
        store(ratedSnapshots, key: "vinyl.rated.snapshots")
    }

    func deleteReview(for album: VinylAlbum) {
        reviews.removeValue(forKey: album.id)
        ratings.removeValue(forKey: album.id)
        ratedSnapshots.removeValue(forKey: album.id)
        store(reviews, key: "vinyl.album.reviews.v1")
        store(ratings, key: "vinyl.ratings")
        store(ratedSnapshots, key: "vinyl.rated.snapshots")
    }

    // Compatibility with old call sites / data format.
    func rate(_ value: Int, album: VinylAlbum) {
        if value == 0 { deleteReview(for: album) }
        else { saveReview(score: min(10, max(1, value)), bestTracks: review(for: album)?.bestTracks ?? [],
                          comment: review(for: album)?.comment ?? "", for: album) }
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
        if selectedID == album.id { selectedID = ""; restoreValidSelection() }
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
        // Network refresh should not change the record that was on screen.
        restoreValidSelection()
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
