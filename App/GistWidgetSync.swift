import Foundation

/// Free signing cannot enable App Groups, so the app and widget communicate
/// via an unlisted GitHub Gist containing ONLY the selected album's metadata.
/// The write token stays in the main app's Keychain; the widget reads anonymously.
@MainActor
final class GistWidgetSync {
    static let shared = GistWidgetSync()

    private let service = "VinylOfTheDay"
    private let account = "vinyl.github.gistToken.v1"
    private let gistKey = "vinyl.widget.gistID"
    private let filename = "vinyl-widget.json"

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

    func publish(album: VinylAlbum) async throws -> String {
        guard let token else { throw WidgetSyncError.missingToken }
        let payload = WidgetPayload(version: 1, album: album, updatedAt: Date())
        let contentData = try JSONEncoder().encode(payload)
        guard let content = String(data: contentData, encoding: .utf8) else {
            throw WidgetSyncError.badResponse("Не удалось сформировать JSON альбома")
        }
        let existing = gistID
        let url = existing.isEmpty
            ? URL(string: "https://api.github.com/gists")!
            : URL(string: "https://api.github.com/gists/\(existing)")!
        var request = URLRequest(url: url)
        request.httpMethod = existing.isEmpty ? "POST" : "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("VINYL-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        var body: [String: Any] = ["files": [filename: ["content": content]]]
        if existing.isEmpty {
            body["description"] = "VINYL widget album (only one selected album; unlisted)"
            body["public"] = false
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WidgetSyncError.badResponse("GitHub не ответил")
        }
        guard (200...299).contains(http.statusCode) else {
            let reason = String(data: data, encoding: .utf8) ?? ""
            let clipped = String(reason.prefix(180))
            throw WidgetSyncError.badResponse("GitHub HTTP \(http.statusCode): \(clipped)")
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = result["id"] as? String, !id.isEmpty else {
            throw WidgetSyncError.badResponse("GitHub не вернул ID Gist")
        }
        UserDefaults.standard.set(id, forKey: gistKey)
        return id
    }
}

enum WidgetSyncError: LocalizedError {
    case missingToken
    case storage
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Сначала добавь GitHub Gist-токен в Настройки → Виджет."
        case .storage: return "Не удалось сохранить GitHub-токен в Keychain."
        case .badResponse(let description): return description
        }
    }
}
