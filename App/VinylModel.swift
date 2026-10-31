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
    // Local listen-later shelf, independent of Spotify and the native widget.
    @Published private(set) var wishlistDates: [String: Date] = [:]
    @Published private(set) var wishlistSnapshots: [String: VinylAlbum] = [:]
    // Rich reviews are stored separately: existing 1–10 ratings remain compatible.
    @Published private(set) var reviews: [String: AlbumReview] = [:]
    // An ordered personal top four; separate from Spotify and album ratings.
    @Published private(set) var profileFavoriteIDs: [String] = []
    @Published var widgetGistID: String = GistWidgetSync.shared.gistID
    @Published private(set) var widgetLibrarySharingEnabled = UserDefaults.standard.bool(forKey: "vinyl.widget.shareLibrary.v2")
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
    // The FULL library: saved Spotify albums + manual links + recent listening.
    // Duplicates removed while preserving stable order for the widget rotation.
    var widgetAlbumPool: [VinylAlbum] {
        // Saved Spotify collection + manually added albums. Recent listening
        // history is deliberately NOT uploaded to the unlisted Gist.
        var seen = Set<String>()
        return (saved + manual).filter { seen.insert($0.id).inserted }
    }

    var allAlbums: [VinylAlbum] {
        var visited = Set<String>()
        return (saved + manual + recent).filter { visited.insert($0.id).inserted }
    }
    var wishlistedAlbums: [VinylAlbum] {
        var lookup = wishlistSnapshots
        for album in allAlbums { lookup[album.id] = album }
        return wishlistDates.keys.compactMap { lookup[$0] }
            .sorted { (wishlistDates[$0.id] ?? .distantPast) > (wishlistDates[$1.id] ?? .distantPast) }
    }
    func isWishlisted(_ album: VinylAlbum) -> Bool { wishlistDates[album.id] != nil }
    func toggleWishlist(_ album: VinylAlbum) {
        if isWishlisted(album) {
            wishlistDates.removeValue(forKey: album.id)
            wishlistSnapshots.removeValue(forKey: album.id)
        } else {
            wishlistDates[album.id] = Date()
            wishlistSnapshots[album.id] = album
        }
        store(wishlistDates, key: "vinyl.wishlist.dates.v1")
        store(wishlistSnapshots, key: "vinyl.wishlist.albums.v1")
    }

    var profileFavoriteAlbums: [VinylAlbum] {
        var lookup = ratedSnapshots
        for album in allAlbums { lookup[album.id] = album }
        return profileFavoriteIDs.compactMap { lookup[$0] }
    }
    func addProfileFavorite(_ album: VinylAlbum) {
        guard !profileFavoriteIDs.contains(album.id), profileFavoriteIDs.count < 4 else { return }
        // Preserve a snapshot so an album can stay in the profile offline.
        ratedSnapshots[album.id] = album
        store(ratedSnapshots, key: "vinyl.rated.snapshots")
        profileFavoriteIDs.append(album.id)
        store(profileFavoriteIDs, key: "vinyl.profile.favorites.v1")
    }
    func removeProfileFavorite(_ album: VinylAlbum) {
        profileFavoriteIDs.removeAll { $0 == album.id }
        store(profileFavoriteIDs, key: "vinyl.profile.favorites.v1")
    }
    func moveProfileFavorite(from source: Int, to destination: Int) {
        guard profileFavoriteIDs.indices.contains(source),
              profileFavoriteIDs.indices.contains(destination), source != destination else { return }
        let item = profileFavoriteIDs.remove(at: source)
        profileFavoriteIDs.insert(item, at: destination)
        store(profileFavoriteIDs, key: "vinyl.profile.favorites.v1")
    }
    var ratedTracksCount: Int { reviews.values.reduce(0) { $0 + $1.trackRatings.count } }

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
        wishlistDates = read([String: Date].self, key: "vinyl.wishlist.dates.v1") ?? [:]
        wishlistSnapshots = read([String: VinylAlbum].self, key: "vinyl.wishlist.albums.v1") ?? [:]
        reviews = read([String: AlbumReview].self, key: "vinyl.album.reviews.v1") ?? [:]
        var profileSeen = Set<String>()
        profileFavoriteIDs = Array((read([String].self, key: "vinyl.profile.favorites.v1") ?? [])
            .filter { profileSeen.insert($0).inserted }.prefix(4))
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

    func saveReview(score: Int, bestTracks: [ReviewTrack], comment: String,
                    trackRatings: [TrackRating]? = nil, for album: VinylAlbum) {
        guard (1...10).contains(score) else { return }
        let now = Date()
        // Preserve original review date when editing; never pretend to know the
        // original date for 1.2.x ratings that did not store a timestamp.
        let firstDate = reviews[album.id]?.ratedAt ?? now
        let cleanComment = String(comment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        let validTrackRatings = (trackRatings ?? reviews[album.id]?.trackRatings ?? [])
            .filter { (1...10).contains($0.score) }
        let review = AlbumReview(score: score, bestTracks: bestTracks, comment: cleanComment,
                                 ratedAt: firstDate, updatedAt: now, trackRatings: validTrackRatings)
        reviews[album.id] = review
        ratings[album.id] = score
        ratedSnapshots[album.id] = album
        // An album moves out of the listening queue when it gets a review.
        if isWishlisted(album) { toggleWishlist(album) }
        store(reviews, key: "vinyl.album.reviews.v1")
        store(ratings, key: "vinyl.ratings")
        store(ratedSnapshots, key: "vinyl.rated.snapshots")
    }

    func deleteReview(for album: VinylAlbum) {
        reviews.removeValue(forKey: album.id)
        ratings.removeValue(forKey: album.id)
        // Keep a profile snapshot if this record is in the personal Top 4.
        if !profileFavoriteIDs.contains(album.id) {
            ratedSnapshots.removeValue(forKey: album.id)
        }
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

    // Export/import are deliberately scoped to music data. Credentials stay
    // in Keychain and are never encoded into the JSON archive.
    func exportBackupData() throws -> Data {
        let archive = VinylBackupPayload(
            version: 1, exportedAt: Date(), saved: saved, recent: recent,
            manual: manual, ratings: ratings, ratedSnapshots: ratedSnapshots,
            reviews: reviews, wishlistDates: wishlistDates,
            wishlistSnapshots: wishlistSnapshots, profileFavoriteIDs: profileFavoriteIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    func inspectBackup(_ data: Data) throws -> VinylBackupPayload {
        guard data.count <= 20_000_000 else { throw VinylBackupError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(VinylBackupPayload.self, from: data)
        guard archive.version == 1 else { throw VinylBackupError.unsupportedVersion }
        guard archive.saved.count < 100_000, archive.recent.count < 100_000,
              archive.manual.count < 100_000, archive.ratings.count < 100_000,
              archive.reviews.count < 100_000, archive.wishlistDates.count < 100_000 else {
            throw VinylBackupError.tooLarge
        }
        return archive
    }

    func restoreBackup(_ archive: VinylBackupPayload, replace: Bool) {
        func combining(_ old: [VinylAlbum], _ incoming: [VinylAlbum]) -> [VinylAlbum] {
            var ids = Set<String>()
            return (old + incoming).filter { ids.insert($0.id).inserted }
        }
        func merging<T>(_ current: [String: T], _ imported: [String: T]) -> [String: T] {
            // Keep the user's on-device entry when both sides contain the ID.
            imported.merging(current) { _, local in local }
        }
        saved = replace ? archive.saved : combining(saved, archive.saved)
        recent = replace ? archive.recent : combining(recent, archive.recent)
        manual = replace ? archive.manual : combining(manual, archive.manual)
        reviews = replace ? archive.reviews : merging(reviews, archive.reviews)
        ratings = replace ? archive.ratings : merging(ratings, archive.ratings)
        ratedSnapshots = replace ? archive.ratedSnapshots : merging(ratedSnapshots, archive.ratedSnapshots)
        wishlistDates = replace ? archive.wishlistDates : merging(wishlistDates, archive.wishlistDates)
        wishlistSnapshots = replace ? archive.wishlistSnapshots : merging(wishlistSnapshots, archive.wishlistSnapshots)
        if replace {
            profileFavoriteIDs = Array(archive.profileFavoriteIDs.prefix(4))
        } else {
            var seen = Set<String>()
            profileFavoriteIDs = Array((profileFavoriteIDs + archive.profileFavoriteIDs)
                .filter { seen.insert($0).inserted }.prefix(4))
        }
        ratings = ratings.filter { (1...10).contains($0.value) }
        for (id, review) in reviews { ratings[id] = review.score }
        // A reviewed record does not also belong to the listen-later queue.
        for id in ratings.keys { wishlistDates.removeValue(forKey: id); wishlistSnapshots.removeValue(forKey: id) }
        store(saved, key: "vinyl.saved")
        store(recent, key: "vinyl.recent")
        store(manual, key: "vinyl.manual")
        store(reviews, key: "vinyl.album.reviews.v1")
        store(ratings, key: "vinyl.ratings")
        store(ratedSnapshots, key: "vinyl.rated.snapshots")
        store(wishlistDates, key: "vinyl.wishlist.dates.v1")
        store(wishlistSnapshots, key: "vinyl.wishlist.albums.v1")
        store(profileFavoriteIDs, key: "vinyl.profile.favorites.v1")
        restoreValidSelection()
        Task { await updateAccent() }
        message = replace ? "Резервная копия восстановлена. Данные VINYL заменены." : "Резервная копия объединена с данными VINYL. Твои текущие рецензии сохранены."
        if widgetLibrarySharingEnabled { Task { await syncWidgetLibrary(silent: true) } }
    }

    func saveGitHubToken(_ value: String) {
        do {
            try GistWidgetSync.shared.setToken(value)
            message = "GitHub-токен сохранён в Keychain. Теперь выбери альбом и нажми «Добавить в виджет»."
        } catch { message = error.localizedDescription }
    }

    /// User must explicitly consent: album titles and links become readable
    /// by anyone who knows the unlisted Gist URL. No reviews or tokens upload.
    func enableWidgetLibrarySharing() async {
        guard !widgetLibrarySharingEnabled else { return }
        guard !widgetAlbumPool.isEmpty else {
            message = "Библиотека пустая. Сначала синхронизируй Spotify."
            return
        }
        guard GistWidgetSync.shared.hasToken else {
            message = "Сначала сохрани GitHub Gist-токен в Настройки → Виджет."
            return
        }
        widgetBusy = true
        defer { widgetBusy = false }
        do {
            let id = try await GistWidgetSync.shared.publishLibrary(widgetAlbumPool)
            widgetLibrarySharingEnabled = true
            defaults.set(true, forKey: "vinyl.widget.shareLibrary.v2")
            widgetGistID = id
            message = "В виджет передано \(widgetAlbumPool.count) альбомов. Теперь он будет случайно менять их по 3-часовым интервалам. Gist ID: \(id)"
            WidgetCenter.shared.reloadTimelines(ofKind: "VinylMediumWidget")
        } catch { message = "Виджет: \(error.localizedDescription)" }
    }

    func disableWidgetLibrarySharing() async {
        guard widgetLibrarySharingEnabled else { return }
        widgetBusy = true
        defer { widgetBusy = false }
        do {
            try await GistWidgetSync.shared.deletePublishedGist()
            widgetLibrarySharingEnabled = false
            defaults.set(false, forKey: "vinyl.widget.shareLibrary.v2")
            widgetGistID = ""
            WidgetCenter.shared.reloadTimelines(ofKind: "VinylMediumWidget")
            message = "Gist удалён. Удали старый виджет с домашнего экрана. При следующем подключении появится новый Gist ID."
        } catch { message = "Не получилось очистить Gist: \(error.localizedDescription)" }
    }

    func syncWidgetLibrary(silent: Bool = false) async {
        guard widgetLibrarySharingEnabled, GistWidgetSync.shared.hasToken else { return }
        guard !widgetBusy, !widgetAlbumPool.isEmpty else { return }
        widgetBusy = true
        defer { widgetBusy = false }
        do {
            let id = try await GistWidgetSync.shared.publishLibrary(widgetAlbumPool)
            widgetGistID = id
            WidgetCenter.shared.reloadTimelines(ofKind: "VinylMediumWidget")
            if !silent { message = "Библиотека виджета обновлена: \(widgetAlbumPool.count) альбомов." }
        } catch { message = "Обновление библиотеки виджета: \(error.localizedDescription)" }
    }

    @discardableResult
    func publishToWidget(_ album: VinylAlbum) async -> Bool {
        guard widgetLibrarySharingEnabled else {
            message = "Открой Настройки → Виджет и разреши передачу библиотеки в Gist. Тогда будут доступны все альбомы и автосмена каждые 3 часа."
            return false
        }
        guard !widgetBusy else { return false }
        widgetBusy = true
        defer { widgetBusy = false }
        do {
            let id = try await GistWidgetSync.shared.publishManual(album: album, library: widgetAlbumPool)
            widgetGistID = id
            message = "«\(album.name)» добавлен в виджет до следующего 3-часового интервала."
            WidgetCenter.shared.reloadTimelines(ofKind: "VinylMediumWidget")
            return true
        } catch {
            message = "Виджет: \(error.localizedDescription)"
            return false
        }
    }

    func nextWidgetAlbum() async {
        let candidates = widgetAlbumPool.filter { $0.id != (defaults.string(forKey: "vinyl.widget.lastAlbumID") ?? "") }
        let chosen = (candidates.isEmpty ? widgetAlbumPool : candidates).randomElement()
        guard let album = chosen else {
            message = "Сначала синхронизируй Spotify или добавь альбом по ссылке."
            return
        }
        if await publishToWidget(album) {
            defaults.set(album.id, forKey: "vinyl.widget.lastAlbumID")
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
        if widgetLibrarySharingEnabled { await syncWidgetLibrary(silent: true) }
    }

    func removeManual(_ album: VinylAlbum) {
        manual.removeAll { $0.id == album.id }
        store(manual, key: "vinyl.manual")
        if selectedID == album.id { selectedID = ""; restoreValidSelection() }
        if widgetLibrarySharingEnabled { Task { await syncWidgetLibrary(silent: true) } }
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
        if widgetLibrarySharingEnabled {
            await syncWidgetLibrary(silent: true)
        }
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
