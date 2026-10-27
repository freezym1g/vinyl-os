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
