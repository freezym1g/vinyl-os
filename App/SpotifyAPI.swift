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

struct AlbumDTO: Decodable {
    let id: String
    let name: String
    let artists: [ArtistDTO]?
    let release_date: String?
    let images: [ImageDTO]?
    let external_urls: ExternalURLs?

    func asVinylAlbum() -> VinylAlbum {
        VinylAlbum(id: id,
                   name: name,
                   artist: (artists ?? []).map(\.name).joined(separator: ", "),
                   year: String((release_date ?? "—").prefix(4)),
                   artURL: images?.first?.url ?? "",
                   spotifyURL: external_urls?.spotify ?? "https://open.spotify.com/album/\(id)")
    }
}
struct ArtistDTO: Decodable { let name: String }
struct ImageDTO: Decodable { let url: String }
struct ExternalURLs: Decodable { let spotify: String? }
struct SavedAlbumsDTO: Decodable {
    struct Item: Decodable { let album: AlbumDTO? }
    let items: [Item]
    let next: String?
}
struct RecentTracksDTO: Decodable {
    struct Item: Decodable {
        struct Track: Decodable { let album: AlbumDTO? }
        let track: Track?
    }
    let items: [Item]
}

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

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let bearer = try await accessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SpotifyFailure.badResponse("Spotify API (\(status)): \(Self.errorText(data))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(350), encoding: .utf8) ?? "(не текстовый ответ)"
            throw SpotifyFailure.badResponse("Spotify вернул неожиданные данные: \(error.localizedDescription). Ответ: \(preview)")
        }
    }

    func savedAlbums() async throws -> [VinylAlbum] {
        var results: [VinylAlbum] = []
        var next: String? = "https://api.spotify.com/v1/me/albums?limit=50"
        var pages = 0
        while let link = next, let url = URL(string: link), pages < 20 {
            let response: SavedAlbumsDTO = try await get(url)
            results += response.items.compactMap { $0.album?.asVinylAlbum() }
            next = response.next
            pages += 1
        }
        return results
    }

    func recentAlbums() async throws -> [VinylAlbum] {
        let response: RecentTracksDTO = try await get(URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=50")!)
        var seen = Set<String>()
        return response.items.compactMap { item in
            guard let album = item.track?.album?.asVinylAlbum() else { return nil }
            return seen.insert(album.id).inserted ? album : nil
        }
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
