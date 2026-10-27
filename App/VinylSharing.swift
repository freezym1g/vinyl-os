import SwiftUI
import UIKit

/// Generates a real PNG using SwiftUI's ImageRenderer, then shares with iOS Share Sheet.
/// Network artwork is decoded BEFORE rendering; AsyncImage isn't reliable in offscreen renderers.
struct ReviewShareButton: View {
    let album: VinylAlbum
    let review: AlbumReview

    @State private var imageToShare: UIImage?
    @State private var presenting = false
    @State private var creating = false
    @State private var errorText: String?

    var body: some View {
        Button {
            Task { await makeImage() }
        } label: {
            HStack {
                if creating { ProgressView().tint(.white) }
                else { Image(systemName: "square.and.arrow.up") }
                Text(creating ? "Готовим карточку…" : "Поделиться рецензией")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .modifier(VinylGlassButtonModifier(prominent: true))
        .disabled(creating)
        .sheet(isPresented: $presenting) {
            if let imageToShare {
                VinylActivitySheet(items: [imageToShare])
            }
        }
        .alert("Карточка не создана", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "Неизвестная ошибка")
        }
    }

    @MainActor
    private func makeImage() async {
        creating = true
        defer { creating = false }
        var cover: UIImage?
        if let artwork = album.artwork {
            if let (data, _) = try? await URLSession.shared.data(from: artwork) {
                cover = UIImage(data: data)
            }
        }
        let view = VinylReviewShareCard(album: album, review: review, artwork: cover, palette: ReviewSharePalette.from(cover))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.uiImage else {
            errorText = "iOS не смогла отрисовать изображение. Попробуй ещё раз."
            return
        }
        imageToShare = image
        presenting = true
    }
}

private struct VinylActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// A quiet, legible palette extracted from the actual artwork (not the current
/// home-screen album). Pale covers get paper/ink; saturated covers are muted.
/// All color calculations happen before ImageRenderer renders the offline PNG.
private struct ReviewSharePalette {
    let top: Color
    let bottom: Color
    let ink: Color
    let subdued: Color
    let separator: Color
    let isLight: Bool

    private static func make(hue: CGFloat, saturation: CGFloat, light: Bool) -> ReviewSharePalette {
        if light {
            // Paper-like surface: even a white cover such as Blonde remains
            // comfortably readable, without a pure #FFFFFF glare.
            let tint = min(0.20, max(0.035, saturation * 0.22))
            return ReviewSharePalette(
                top: Color(uiColor: UIColor(hue: hue, saturation: tint, brightness: 0.93, alpha: 1)),
                bottom: Color(uiColor: UIColor(hue: hue, saturation: tint * 0.75, brightness: 0.83, alpha: 1)),
                ink: Color(red: 0.12, green: 0.13, blue: 0.15),
                subdued: Color(red: 0.28, green: 0.29, blue: 0.31),
                separator: Color.black.opacity(0.18),
                isLight: true
            )
        }
        let tint = min(0.42, max(0.12, saturation * 0.47))
        return ReviewSharePalette(
            top: Color(uiColor: UIColor(hue: hue, saturation: tint, brightness: 0.31, alpha: 1)),
            bottom: Color(uiColor: UIColor(hue: hue, saturation: tint * 0.65, brightness: 0.14, alpha: 1)),
            ink: Color(red: 0.98, green: 0.97, blue: 0.95),
            subdued: Color(red: 0.83, green: 0.82, blue: 0.80),
            separator: Color.white.opacity(0.20),
            isLight: false
        )
    }

    static func from(_ artwork: UIImage?) -> ReviewSharePalette {
        guard let image = artwork?.cgImage else {
            return make(hue: 0.62, saturation: 0.20, light: false)
        }
        // Downsampling keeps the analysis fast even for 3000px Spotify art.
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return make(hue: 0.62, saturation: 0.20, light: false)
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        let count = 18
        var weights = [Double](repeating: 0, count: count)
        var saturationSum = [Double](repeating: 0, count: count)
        var luminanceSum = 0.0
        var paleCount = 0
        var eligibleCount = 0
        for i in 0..<(side * side) {
            let offset = i * 4
            if pixels[offset + 3] < 30 { continue }
            let r = CGFloat(pixels[offset]) / 255
            let g = CGFloat(pixels[offset + 1]) / 255
            let b = CGFloat(pixels[offset + 2]) / 255
            let luminosity = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            luminanceSum += luminosity
            eligibleCount += 1
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            if luminosity > 0.69 && saturation < 0.24 { paleCount += 1 }
            // Ignore near-neutral/dark noise, and prefer hues that occupy a
            // meaningful part of the cover instead of a tiny neon detail.
            if saturation > 0.10 && brightness > 0.14 {
                let bucket = min(count - 1, Int(hue * CGFloat(count)))
                let weight = 0.35 + Double(saturation) * 0.65
                weights[bucket] += weight
                saturationSum[bucket] += weight * Double(saturation)
            }
        }
        guard eligibleCount > 0 else { return make(hue: 0.62, saturation: 0.2, light: false) }
        let whiteRatio = Double(paleCount) / Double(eligibleCount)
        let averageLuminosity = luminanceSum / Double(eligibleCount)
        let light = whiteRatio > 0.40 || (whiteRatio > 0.23 && averageLuminosity > 0.64)

        // A white/near-grayscale sleeve uses warm-neutral tones. Otherwise
        // keep the most present hue, desaturated and contrast-corrected.
        if light && whiteRatio > 0.40 {
            return make(hue: 0.10, saturation: 0.08, light: true)
        }
        guard let dominant = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[dominant] > 0 else {
            return make(hue: 0.10, saturation: 0.05, light: light || averageLuminosity > 0.72)
        }
        let hue = CGFloat(Double(dominant) + 0.5) / CGFloat(count)
        let saturation = CGFloat(saturationSum[dominant] / weights[dominant])
        return make(hue: hue, saturation: saturation, light: light)
    }
}

private struct VinylReviewShareCard: View {
    let album: VinylAlbum
    let review: AlbumReview
    let artwork: UIImage?
    let palette: ReviewSharePalette

    private var dateText: String {
        guard let date = review.ratedAt else { return "Оценка из моей коллекции" }
        return date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.top, palette.bottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("VINYL")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                    Spacer()
                    Text("ALBUM REVIEW")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(2.5)
                        .foregroundStyle(palette.subdued)
                }

                HStack(alignment: .top, spacing: 21) {
                    Group {
                        if let artwork {
                            Image(uiImage: artwork).resizable().scaledToFill()
                        } else {
                            ZStack {
                                palette.separator
                                Image(systemName: "opticaldisc")
                                    .font(.system(size: 90, weight: .thin))
                                    .foregroundStyle(palette.subdued)
                            }
                        }
                    }
                    .frame(width: 265, height: 265)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("МОЯ ОЦЕНКА")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(palette.subdued)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(review.score)")
                                .font(.system(size: 72, weight: .heavy, design: .rounded))
                            Text("/10")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(palette.subdued)
                        }
                        Spacer()
                        Text(album.year)
                            .font(.system(size: 18))
                            .foregroundStyle(palette.subdued)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 265)
                }
                Text(album.name)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(album.artist)
                    .font(.system(size: 20))
                    .foregroundStyle(palette.subdued)
                    .lineLimit(2)

                Rectangle().fill(palette.separator).frame(height: 1)

                if !review.bestTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("ЛЮБИМЫЕ ТРЕКИ")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.8)
                            .foregroundStyle(palette.subdued)
                        Text(review.bestTracks.prefix(3).map(\.name).joined(separator: " · "))
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(2)
                    }
                }
                if !review.comment.isEmpty {
                    Text("“\(review.comment)”")
                        .font(.system(size: 18))
                        .lineLimit(4)
                        .foregroundStyle(palette.ink.opacity(0.85))
                }
                Spacer(minLength: 5)
                HStack {
                    Text(dateText)
                    Spacer()
                    Text("MY MUSIC JOURNAL")
                        .tracking(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.subdued)
            }
            .padding(30)
            .foregroundStyle(palette.ink)
        }
        .frame(width: 540, height: 760)
    }
}
