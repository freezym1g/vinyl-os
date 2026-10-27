import Foundation

/// Public-facing widget data. No ratings, Spotify access tokens, or library contents.
struct WidgetPayload: Codable {
    let version: Int
    let album: VinylAlbum
    let updatedAt: Date
}
