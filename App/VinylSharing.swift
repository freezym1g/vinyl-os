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
        let view = VinylReviewShareCard(album: album, review: review, artwork: cover)
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

private struct VinylReviewShareCard: View {
    let album: VinylAlbum
    let review: AlbumReview
    let artwork: UIImage?

    private var dateText: String {
        guard let date = review.ratedAt else { return "Оценка из моей коллекции" }
        return date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.19, green: 0.22, blue: 0.26),
                                    Color(red: 0.06, green: 0.065, blue: 0.085)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("VINYL")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                    Spacer()
                    Text("ALBUM REVIEW")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(2.5)
                        .foregroundStyle(.white.opacity(0.65))
                }

                HStack(alignment: .top, spacing: 21) {
                    Group {
                        if let artwork {
                            Image(uiImage: artwork).resizable().scaledToFill()
                        } else {
                            ZStack {
                                Color.white.opacity(0.07)
                                Image(systemName: "opticaldisc")
                                    .font(.system(size: 90, weight: .thin))
                                    .foregroundStyle(.white.opacity(0.5))
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
                            .foregroundStyle(.white.opacity(0.6))
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(review.score)")
                                .font(.system(size: 72, weight: .heavy, design: .rounded))
                            Text("/10")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Text(album.year)
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.65))
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
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)

                Rectangle().fill(.white.opacity(0.2)).frame(height: 1)

                if !review.bestTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("ЛЮБИМЫЕ ТРЕКИ")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.8)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(review.bestTracks.prefix(3).map(\.name).joined(separator: " · "))
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(2)
                    }
                }
                if !review.comment.isEmpty {
                    Text("“\(review.comment)”")
                        .font(.system(size: 18))
                        .lineLimit(4)
                        .foregroundStyle(.white.opacity(0.86))
                }
                Spacer(minLength: 5)
                HStack {
                    Text(dateText)
                    Spacer()
                    Text("MY MUSIC JOURNAL")
                        .tracking(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            }
            .padding(30)
            .foregroundStyle(.white)
        }
        .frame(width: 540, height: 760)
    }
}
