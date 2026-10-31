import Foundation

/// An unlisted Gist can be read by anyone holding its URL.
/// Never include credentials, review text, ratings or private listening history.
/// v1 held a single album; v2 optionally holds the user-approved album library.
struct WidgetPayload: Codable {
    let version: Int
    let album: VinylAlbum
    let updatedAt: Date
    let library: [VinylAlbum]?
    let manualUntil: Date?

    init(version: Int, album: VinylAlbum, updatedAt: Date,
         library: [VinylAlbum]? = nil, manualUntil: Date? = nil) {
        self.version = version
        self.album = album
        self.updatedAt = updatedAt
        self.library = library
        self.manualUntil = manualUntil
    }
}
