import Foundation
import UIKit
import AuthenticationServices
import CryptoKit
import Security

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum SpotifyFailure: LocalizedError {
    case missingClient
    case noTokens
    case badCallback
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingClient: return "Укажи Spotify Client ID в настройках."
        case .noTokens: return "Сначала подключи Spotify."
        case .badCallback: return "Spotify не вернул код авторизации."
        case .badResponse(let message): return message
        }
    }
}

// Spotify отдаёт иногда неполные/недоступные альбомы. Сохранённые
// альбомы разбираются по одному, чтобы один элемент не ломал всю страницу.

@MainActor
final class SpotifyAPI: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SpotifyAPI()
    static let redirectURI = "vinyl-of-day://callback"
    private let keychainAccount = "vinyl.spotify.tokens.v1"
    private let keychainService = "VinylOfTheDay"
    private var webSession: ASWebAuthenticationSession?
    private(set) var tokens: SpotifyTokens?
    var clientID: String {
        get { UserDefaults.standard.string(forKey: "spotify_client_id") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "spotify_client_id") }
    }

    override private init() {
        super.init()
        if let data = KeychainBox.read(service: keychainService, account: keychainAccount) {
            tokens = try? JSONDecoder().decode(SpotifyTokens.self, from: data)
        }
    }

    var isConnected: Bool { tokens != nil }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // UIKit scene is provided by the host iOS app; no force unwrap.
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first
        ?? ASPresentationAnchor()
    }

    func connect() async throws {
        guard !clientID.isEmpty else { throw SpotifyFailure.missingClient }
        let verifier = Self.base64URL(Self.randomBytes(count: 32))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.base64URL(Self.randomBytes(count: 16))
        var parts = URLComponents(string: "https://accounts.spotify.com/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: "user-library-read user-read-recently-played"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "show_dialog", value: "true")
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: parts.url!, callbackURLScheme: "vinyl-of-day") { url, error in
                if let error = error { continuation.resume(throwing: error) }
                else if let url = url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: SpotifyFailure.badCallback) }
            }
            self.webSession = session
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                self.webSession = nil
                continuation.resume(throwing: SpotifyFailure.badResponse("Не удалось открыть вход Spotify."))
            }
        }
        webSession = nil
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { query.first(where: { $0.name == key })?.value }
        guard value("state") == state, let code = value("code") else {
            throw SpotifyFailure.badResponse(value("error") ?? "Некорректный ответ Spotify (state/code).")
        }
        try await exchange(form: ["grant_type": "authorization_code", "code": code,
                                  "redirect_uri": Self.redirectURI, "client_id": clientID,
                                  "code_verifier": verifier])
    }

    func disconnect() {
        tokens = nil
        KeychainBox.delete(service: keychainService, account: keychainAccount)
    }

    private struct TokenDTO: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }
    private func exchange(form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let parts = form.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(Self.encode(key))=\(Self.encode(value))"
        }.joined(separator: "&")
        request.httpBody = Data(parts.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SpotifyFailure.badResponse("Ошибка авторизации Spotify: \(Self.errorText(data))")
        }
        let item = try JSONDecoder().decode(TokenDTO.self, from: data)
        let refresh = item.refresh_token ?? tokens?.refreshToken ?? ""
        guard !refresh.isEmpty else { throw SpotifyFailure.badResponse("Spotify не вернул refresh token.") }
        let newTokens = SpotifyTokens(accessToken: item.access_token,
                                     refreshToken: refresh,
                                     expiresAt: Date().addingTimeInterval(TimeInterval(item.expires_in)))
        let stored = try JSONEncoder().encode(newTokens)
        guard KeychainBox.write(stored, service: keychainService, account: keychainAccount) else {
            throw SpotifyFailure.badResponse("Не удалось сохранить токен в Keychain.")
        }
        tokens = newTokens
    }

    private func accessToken() async throws -> String {
        guard let tokens else { throw SpotifyFailure.noTokens }
        if tokens.expiresAt.timeIntervalSinceNow < 90 {
            guard !clientID.isEmpty else { throw SpotifyFailure.missingClient }
            try await exchange(form: ["grant_type": "refresh_token",
                                      "refresh_token": tokens.refreshToken,
                                      "client_id": clientID])
        }
        guard let token = self.tokens?.accessToken else { throw SpotifyFailure.noTokens }
        return token
    }

    // Получаем один JSON-объект и проверяем HTTP-код до его обработки.
    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let bearer = try await accessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SpotifyFailure.badResponse("Spotify API (\(status)): \(Self.errorText(data))")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            throw SpotifyFailure.badResponse("Spotify вернул некорректный JSON (\(url.path)).")
        }
        return json
    }

    // У альбома могут отсутствовать обложка, год, ссылка или исполнители.
    // Обязательны только ID и название: без них нельзя показать запись.
    private static func parseAlbum(_ value: Any?) -> VinylAlbum? {
        guard let data = value as? [String: Any],
              let id = data["id"] as? String, !id.isEmpty,
              let name = data["name"] as? String, !name.isEmpty else { return nil }
        let artists = (data["artists"] as? [Any] ?? [])
            .compactMap { ($0 as? [String: Any])?["name"] as? String }
        let images = (data["images"] as? [Any] ?? [])
            .compactMap { ($0 as? [String: Any])?["url"] as? String }
        let links = data["external_urls"] as? [String: Any]
        let date = data["release_date"] as? String ?? ""
        return VinylAlbum(id: id,
                          name: name,
                          artist: artists.isEmpty ? "Неизвестный исполнитель" : artists.joined(separator: ", "),
                          year: date.isEmpty ? "—" : String(date.prefix(4)),
                          artURL: images.first ?? "",
                          spotifyURL: links?["spotify"] as? String ?? "https://open.spotify.com/album/\(id)")
    }

    private(set) var skippedSaved = 0
    private(set) var skippedRecent = 0

    func savedAlbums() async throws -> [VinylAlbum] {
        var results: [VinylAlbum] = []
        var next: String? = "https://api.spotify.com/v1/me/albums?limit=50"
        var pages = 0
        var encountered = 0
        skippedSaved = 0
        while let link = next, let url = URL(string: link), pages < 20 {
            let json = try await getJSON(url)
            guard let items = json["items"] as? [Any] else {
                throw SpotifyFailure.badResponse("Spotify вернул страницу без массива items (\(url.path)).")
            }
            encountered += items.count
            for value in items {
                let wrapped = value as? [String: Any]
                if let album = Self.parseAlbum(wrapped?["album"]) {
                    results.append(album)
                } else {
                    skippedSaved += 1
                }
            }
            next = json["next"] as? String
            pages += 1
        }
        // Не перезаписываем ранее сохранённую библиотеку пустотой, если
        // Spotify вернул элементы, но ни один не удалось разобрать.
        if encountered > 0 && results.isEmpty {
            throw SpotifyFailure.badResponse("Все записи библиотеки Spotify оказались неполными. Старый кеш сохранён.")
        }
        if skippedSaved > 0 {
            print("VINYL: пропущено неполных альбомов: \(skippedSaved)")
        }
        return results
    }

    func recentAlbums() async throws -> [VinylAlbum] {
        skippedRecent = 0
        let json = try await getJSON(URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=50")!)
        guard let items = json["items"] as? [Any] else {
            throw SpotifyFailure.badResponse("Spotify вернул историю без массива items.")
        }
        var seen = Set<String>()
        var results: [VinylAlbum] = []
        for value in items {
            let track = (value as? [String: Any])?["track"] as? [String: Any]
            guard let album = Self.parseAlbum(track?["album"]) else {
                skippedRecent += 1
                continue
            }
            if seen.insert(album.id).inserted { results.append(album) }
        }
        if skippedRecent > 0 {
            print("VINYL: пропущено записей истории: \(skippedRecent)")
        }
        return results
    }

    // Album tracklist for selecting favorites in VINYL Reviews.
    // Uses the same OAuth access token and refresh flow as saved albums.
    func albumTracks(for album: VinylAlbum) async throws -> [ReviewTrack] {
        guard album.id.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil else {
            throw SpotifyFailure.badResponse("Не удалось определить Spotify ID альбома. Добавь треки вручную.")
        }
        var next: String? = "https://api.spotify.com/v1/albums/\(album.id)/tracks?limit=50"
        var results: [ReviewTrack] = []
        var seen = Set<String>()
        var pageCount = 0
        while let link = next, pageCount < 12 {
            guard let url = URL(string: link),
                  url.scheme == "https", url.host == "api.spotify.com",
                  url.path == "/v1/albums/\(album.id)/tracks" else {
                throw SpotifyFailure.badResponse("Spotify вернул недопустимую ссылку страницы треков.")
            }
            let json = try await getJSON(url)
            guard let items = json["items"] as? [Any] else {
                throw SpotifyFailure.badResponse("Spotify вернул треклист без массива items.")
            }
            for entry in items {
                guard let item = entry as? [String: Any],
                      let name = item["name"] as? String, !name.isEmpty else { continue }
                let disc = max(1, item["disc_number"] as? Int ?? 1)
                let number = max(1, item["track_number"] as? Int ?? results.count + 1)
                let id = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "album:\(album.id):\(disc):\(number)"
                if seen.insert(id).inserted {
                    results.append(ReviewTrack(id: id, name: name, discNumber: disc, trackNumber: number))
                }
            }
            next = json["next"] as? String
            pageCount += 1
        }
        return results
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "Secure random unavailable")
        return Data(bytes)
    }
    private static func base64URL(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
    private static func errorText(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "Нет ответа"
        return String(text.prefix(200))
    }
}

enum KeychainBox {
    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    static func write(_ data: Data, service: String, account: String) -> Bool {
        delete(service: service, account: account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    static func delete(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
