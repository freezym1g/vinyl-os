import SwiftUI

/// A local music profile, built only from the user's saved VINYL data.
/// This screen does not publish anything to Spotify or to the Gist widget.
struct VinylProfileView: View {
    @EnvironmentObject private var model: VinylModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingAlbums = false
    @State private var openingReview: VinylAlbum?

    private var allScores: [Int] { model.ratedAlbums.compactMap { model.ratings[$0.id] } }
    private var average: String {
        guard !allScores.isEmpty else { return "—" }
        return String(format: "%.1f", Double(allScores.reduce(0, +)) / Double(allScores.count))
    }
    private var allTrackScores: [(VinylAlbum, TrackRating)] {
        let sourceAlbums = model.ratedAlbums
        return sourceAlbums.flatMap { album in
            (model.review(for: album)?.trackRatings ?? []).map { (album, $0) }
        }.sorted { lhs, rhs in
            lhs.1.score == rhs.1.score
                ? lhs.1.track.name.localizedStandardCompare(rhs.1.track.name) == .orderedAscending
                : lhs.1.score > rhs.1.score
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        metric("Рецензий", value: "\(allScores.count)", icon: "star.fill")
                        metric("Средний балл", value: average, icon: "chart.bar.fill")
                        metric("Оценено треков", value: "\(model.ratedTracksCount)", icon: "music.note")
                        metric("Десяток", value: "\(allScores.filter { $0 == 10 }.count)", icon: "sparkles")
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Моя четвёрка", systemImage: "square.grid.2x2.fill")
                                .font(.headline)
                            Spacer()
                            Button { choosingAlbums = true } label: {
                                Label("Настроить", systemImage: "pencil")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                        }
                        Text("Четыре альбома, которые ты выбираешь сам. Порядок можно менять.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.profileFavoriteAlbums.isEmpty {
                            Button { choosingAlbums = true } label: {
                                Label("Выбрать любимые альбомы", systemImage: "plus.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 20)
                            }
                            .foregroundStyle(.white)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                                ForEach(Array(model.profileFavoriteAlbums.enumerated()), id: \.element.id) { index, album in
                                    Button { openingReview = album } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            RemoteArtwork(url: album.artwork)
                                                .overlay(alignment: .topLeading) {
                                                    Text("0\(index + 1)")
                                                        .font(.caption.weight(.bold).monospacedDigit())
                                                        .padding(7)
                                                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                                                        .padding(8)
                                                }
                                            Text(album.name)
                                                .font(.subheadline.weight(.semibold))
                                                .lineLimit(1)
                                            Text(album.artist)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(18)
                    .vinylGlassSurface(cornerRadius: 24)

                    VStack(alignment: .leading, spacing: 13) {
                        Label("Мои лучшие треки", systemImage: "music.note.list")
                            .font(.headline)
                        if allTrackScores.isEmpty {
                            Text("Оцени отдельные песни в рецензии — здесь появятся треки с самыми высокими баллами.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(allTrackScores.prefix(5).enumerated()), id: \.element.1.id) { _, item in
                                HStack(alignment: .center, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.1.track.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text("\(item.0.artist) · \(item.0.name)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text("\(item.1.score)/10")
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .vinylGlassSurface(cornerRadius: 24)
                    Text("Все цифры здесь основаны на твоих оценках в VINYL, а не на статистике прослушиваний Spotify.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .padding(.bottom, 28)
            }
            .background(VinylBackdrop(accent: model.accent))
            .navigationTitle("Мой профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
            .sheet(isPresented: $choosingAlbums) {
                ProfileFavoritePicker().environmentObject(model)
            }
            .fullScreenCover(item: $openingReview) { album in
                AlbumReviewFlowView(album: album).environmentObject(model)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 76, height: 76)
                .vinylGlassSurface(cornerRadius: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text("МОЯ МУЗЫКА")
                    .font(.caption.weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Text("VINYL PROFILE")
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .lineLimit(1)
                Text("Мои альбомы, мои оценки")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title3)
                .foregroundStyle(.white.opacity(0.8))
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .vinylGlassSurface(cornerRadius: 22)
    }
}

private struct ProfileFavoritePicker: View {
    @EnvironmentObject private var model: VinylModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var candidates: [VinylAlbum] {
        var found = Set<String>()
        return (model.allAlbums + model.ratedAlbums + model.profileFavoriteAlbums)
            .filter { found.insert($0.id).inserted }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Моя четвёрка · \(model.profileFavoriteIDs.count)/4") {
                    if model.profileFavoriteAlbums.isEmpty {
                        Text("Выбери до четырёх альбомов ниже")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.profileFavoriteAlbums.enumerated()), id: \.element.id) { index, album in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .frame(width: 15)
                            RemoteArtwork(url: album.artwork).frame(width: 46, height: 46)
                            VStack(alignment: .leading) {
                                Text(album.name).lineLimit(1)
                                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button { model.moveProfileFavorite(from: index, to: index - 1) } label: {
                                Image(systemName: "arrow.up")
                            }
                            .disabled(index == 0)
                            .buttonStyle(.borderless)
                            Button { model.moveProfileFavorite(from: index, to: index + 1) } label: {
                                Image(systemName: "arrow.down")
                            }
                            .disabled(index >= model.profileFavoriteAlbums.count - 1)
                            .buttonStyle(.borderless)
                            Button { model.removeProfileFavorite(album) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red.opacity(0.9))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Section("Добавить альбом") {
                    ForEach(candidates) { album in
                        let isChosen = model.profileFavoriteIDs.contains(album.id)
                        Button {
                            if isChosen { model.removeProfileFavorite(album) }
                            else { model.addProfileFavorite(album) }
                        } label: {
                            HStack(spacing: 12) {
                                RemoteArtwork(url: album.artwork).frame(width: 48, height: 48)
                                VStack(alignment: .leading) {
                                    Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: isChosen ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(isChosen ? Color.green : Color.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!isChosen && model.profileFavoriteIDs.count >= 4)
                    }
                }
            }
            .searchable(text: $search, prompt: "Найти альбом")
            .navigationTitle("Любимая четвёрка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
