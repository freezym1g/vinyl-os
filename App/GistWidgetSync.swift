import Foundation

/// The FREE signed app cannot use App Groups. The widget reads a user-approved
/// unlisted Gist (album metadata only); app authorization stays in Keychain.
@MainActor
final class GistWidgetSync {
    static let shared = GistWidgetSync()

    private let service = "VinylOfTheDay"
    private let account = "vinyl.github.gistToken.v1"
    private let gistKey = "vinyl.widget.gistID"
    private let filename = "vinyl-widget.json"
    private let lastAlbumKey = "vinyl.widget.manual.album.v2"
    private let manualUntilKey = "vinyl.widget.manual.until.v2"

    private init() {}

    var gistID: String { UserDefaults.standard.string(forKey: gistKey) ?? "" }
    var hasToken: Bool { token != nil }

    private var token: String? {
        guard let data = KeychainBox.read(service: service, account: account),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    func setToken(_ value: String) throws {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw WidgetSyncError.missingToken }
        guard KeychainBox.write(Data(cleaned.utf8), service: service, account: account) else {
            throw WidgetSyncError.storage
        }
    }

    func clearToken() { KeychainBox.delete(service: service, account: account) }

    /// Explicit user choice: show a specific record only until the NEXT local 3-hour boundary.
    func publishManual(album: VinylAlbum, library: [VinylAlbum]) async throws -> String {
        let until = WidgetRotation.nextBoundary(after: .now)
        let id = try await send(WidgetPayload(version: 2, album: album, updatedAt: .now,
                                               library: library, manualUntil: until))
        if let data = try? JSONEncoder().encode(album) {
            UserDefaults.standard.set(data, forKey: lastAlbumKey)
        }
        UserDefaults.standard.set(until, forKey: manualUntilKey)
        return id
    }

    /// Refresh the entire collection without extending a previous manual override.
    func publishLibrary(_ albums: [VinylAlbum]) async throws -> String {
        guard let first = albums.first else { throw WidgetSyncError.emptyLibrary }
        let savedUntil = UserDefaults.standard.object(forKey: manualUntilKey) as? Date
        let manual = UserDefaults.standard.data(forKey: lastAlbumKey)
            .flatMap { try? JSONDecoder().decode(VinylAlbum.self, from: $0) }
        let active = savedUntil != nil && savedUntil! > Date()
        // A manual pick may be a recently played album not in Saved Albums;
        // preserve it for the remaining slot, then resume rotation of Saved.
        let selected = (active ? manual : nil) ?? first
        return try await send(WidgetPayload(version: 2, album: selected, updatedAt: .now,
                                             library: albums, manualUntil: active ? savedUntil : nil))
    }

    /// Fully revoke the shared library by DELETING its Gist, including history.
    /// A new Gist ID must be configured in the widget next time it is enabled.
    func deletePublishedGist() async throws {
        guard let token else { throw WidgetSyncError.missingToken }
        let id = gistID
        if !id.isEmpty {
            guard let url = URL(string: "https://api.github.com/gists/\(id)") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 25
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("VINYL-iOS", forHTTPHeaderField: "User-Agent")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 204 || http.statusCode == 404 else {
                throw WidgetSyncError.badResponse("Не удалось удалить Gist в GitHub")
            }
        }
        UserDefaults.standard.removeObject(forKey: gistKey)
        UserDefaults.standard.removeObject(forKey: lastAlbumKey)
        UserDefaults.standard.removeObject(forKey: manualUntilKey)
    }

    private func send(_ payload: WidgetPayload) async throws -> String {
        guard let token else { throw WidgetSyncError.missingToken }
        let contentData = try JSONEncoder().encode(payload)
        // GitHub's normal Gist API can truncate files larger than 1 MB; the
        // widget supports raw_url, but protect against unbounded uploads.
        guard contentData.count <= 8_000_000 else { throw WidgetSyncError.tooLarge }
        guard let content = String(data: contentData, encoding: .utf8) else {
            throw WidgetSyncError.badResponse("Не удалось сформировать JSON")
        }
        let existing = gistID
        let url = existing.isEmpty
            ? URL(string: "https://api.github.com/gists")!
            : URL(string: "https://api.github.com/gists/\(existing)")!
        var request = URLRequest(url: url)
        request.httpMethod = existing.isEmpty ? "POST" : "PATCH"
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("VINYL-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        var body: [String: Any] = ["files": [filename: ["content": content]]]
        if existing.isEmpty {
            body["description"] = "VINYL widget catalog (unlisted; metadata only)"
            body["public"] = false
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WidgetSyncError.badResponse("GitHub не ответил")
        }
        guard (200...299).contains(http.statusCode) else {
            let reason = String(data: data, encoding: .utf8) ?? ""
            throw WidgetSyncError.badResponse("GitHub HTTP \(http.statusCode): \(reason.prefix(140))")
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = result["id"] as? String, !id.isEmpty else {
            throw WidgetSyncError.badResponse("GitHub не вернул Gist ID")
        }
        UserDefaults.standard.set(id, forKey: gistKey)
        return id
    }
}

enum WidgetSyncError: LocalizedError {
    case missingToken
    case storage
    case emptyLibrary
    case tooLarge
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Сначала добавь GitHub Gist-токен в Настройки → Виджет."
        case .storage: return "Не удалось сохранить GitHub-токен в Keychain."
        case .emptyLibrary: return "Библиотека пуста. Сначала синхронизируй Spotify."
        case .tooLarge: return "Библиотека слишком большая для одного Gist (больше 8 МБ)."
        case .badResponse(let description): return description
        }
    }
}
