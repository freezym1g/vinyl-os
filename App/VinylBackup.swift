import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Portable local JSON, no keys, passwords or Gist access tokens.
struct VinylBackupPayload: Codable {
    let version: Int
    let exportedAt: Date
    let saved: [VinylAlbum]
    let recent: [VinylAlbum]
    let manual: [VinylAlbum]
    let ratings: [String: Int]
    let ratedSnapshots: [String: VinylAlbum]
    let reviews: [String: AlbumReview]
    let wishlistDates: [String: Date]
    let wishlistSnapshots: [String: VinylAlbum]
    let profileFavoriteIDs: [String]

    init(version: Int, exportedAt: Date, saved: [VinylAlbum], recent: [VinylAlbum],
         manual: [VinylAlbum], ratings: [String: Int],
         ratedSnapshots: [String: VinylAlbum], reviews: [String: AlbumReview],
         wishlistDates: [String: Date], wishlistSnapshots: [String: VinylAlbum],
         profileFavoriteIDs: [String]) {
        self.version = version
        self.exportedAt = exportedAt
        self.saved = saved
        self.recent = recent
        self.manual = manual
        self.ratings = ratings
        self.ratedSnapshots = ratedSnapshots
        self.reviews = reviews
        self.wishlistDates = wishlistDates
        self.wishlistSnapshots = wishlistSnapshots
        self.profileFavoriteIDs = profileFavoriteIDs
    }

    private enum CodingKeys: String, CodingKey {
        case version, exportedAt, saved, recent, manual, ratings, ratedSnapshots,
             reviews, wishlistDates, wishlistSnapshots, profileFavoriteIDs
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        saved = try c.decode([VinylAlbum].self, forKey: .saved)
        recent = try c.decode([VinylAlbum].self, forKey: .recent)
        manual = try c.decode([VinylAlbum].self, forKey: .manual)
        ratings = try c.decode([String: Int].self, forKey: .ratings)
        ratedSnapshots = try c.decode([String: VinylAlbum].self, forKey: .ratedSnapshots)
        reviews = try c.decode([String: AlbumReview].self, forKey: .reviews)
        wishlistDates = try c.decode([String: Date].self, forKey: .wishlistDates)
        wishlistSnapshots = try c.decode([String: VinylAlbum].self, forKey: .wishlistSnapshots)
        profileFavoriteIDs = try c.decodeIfPresent([String].self, forKey: .profileFavoriteIDs) ?? []
    }
}

enum VinylBackupError: LocalizedError {
    case tooLarge
    case unsupportedVersion
    case missingData

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Файл слишком большой или содержит слишком много записей."
        case .unsupportedVersion: return "Неподдерживаемая версия резервной копии VINYL."
        case .missingData: return "Выбранный файл не содержит данных JSON."
        }
    }
}

struct VinylBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw VinylBackupError.missingData
        }
        data = fileData
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
