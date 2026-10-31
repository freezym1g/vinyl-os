import Foundation
import SwiftUI

struct VinylAlbum: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let artist: String
    let year: String
    let artURL: String
    let spotifyURL: String

    var artwork: URL? { URL(string: artURL) }
    var link: URL? { URL(string: spotifyURL) }
}

struct RGBColor {
    let red: Double
    let green: Double
    let blue: Double
    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}

#if canImport(UIKit)
import UIKit

enum CoverPalette {
    static let fallback = RGBColor(red: 0.19, green: 0.17, blue: 0.115)

    static func from(_ image: UIImage?) -> RGBColor {
        guard let cgImage = image?.cgImage else { return fallback }
        var sample = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &sample, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return fallback
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        // Подмешиваем чёрный для стабильной читаемости белого текста.
        return RGBColor(red: Double(sample[0]) / 255 * 0.34,
                        green: Double(sample[1]) / 255 * 0.34,
                        blue: Double(sample[2]) / 255 * 0.34)
    }
}
#endif
