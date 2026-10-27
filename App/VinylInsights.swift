import SwiftUI

private struct DayBucket: Identifiable {
    let date: Date?
    let albums: [VinylAlbum]
    var id: String { date.map { String($0.timeIntervalSince1970) } ?? "undated" }
    var title: String {
        guard let date else { return "Ранние оценки · дата неизвестна" }
        return date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))
    }
}

/// A real diary: review dates persisted by AlbumReviews.swift, not mocked Spotify listening history.
struct VinylDiaryView: View {
    @EnvironmentObject private var model: VinylModel
    let albums: [VinylAlbum]
    let onSelect: (VinylAlbum) -> Void
    let onEdit: (VinylAlbum) -> Void
    let onDelete: (VinylAlbum) -> Void

    private var days: [DayBucket] {
        let dated = Dictionary(grouping: albums) { album -> Date? in
            guard let time = model.review(for: album)?.ratedAt else { return nil }
            return Calendar.current.startOfDay(for: time)
        }
        return dated.keys.sorted { lhs, rhs in
            (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }.map { key in
            DayBucket(date: key, albums: (dated[key] ?? []).sorted {
                (model.review(for: $0)?.ratedAt ?? .distantPast) >
                (model.review(for: $1)?.ratedAt ?? .distantPast)
            })
        }
    }

    var body: some View {
        List {
            ForEach(days) { bucket in
                Section(bucket.title) {
                    ForEach(bucket.albums) { album in
                        Button { onSelect(album) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                AlbumListRow(album: album, rating: model.ratings[album.id])
                                if let comment = model.review(for: album)?.comment,
                                   !comment.isEmpty {
                                    Text(comment)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .padding(.horizontal, 8)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { onDelete(album) } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                            Button { onEdit(album) } label: {
                                Label("Изменить", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct ArtistSummary: Identifiable {
    let name: String
    let count: Int
    let mean: Double
    var id: String { name }
}

struct VinylStatisticsView: View {
    @EnvironmentObject private var model: VinylModel

    private var albums: [VinylAlbum] { model.ratedAlbums }
    private var scores: [Int] { albums.compactMap { model.ratings[$0.id] } }
    private var mean: Double { scores.isEmpty ? 0 : Double(scores.reduce(0, +)) / Double(scores.count) }
    private var ratedThisYear: Int {
        albums.filter {
            guard let date = model.review(for: $0)?.ratedAt else { return false }
            return Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        }.count
    }
    private var topArtists: [ArtistSummary] {
        let buckets = Dictionary(grouping: albums, by: { $0.artist })
        return buckets.map { name, records in
            let values = records.compactMap { model.ratings[$0.id] }
            return ArtistSummary(name: name, count: values.count,
                                 mean: values.isEmpty ? 0 : Double(values.reduce(0,+)) / Double(values.count))
        }.sorted { $0.count == $1.count ? $0.mean > $1.mean : $0.count > $1.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    insightTile("Оценено", value: "\(scores.count)", symbol: "star.fill")
                    insightTile("Средний балл", value: scores.isEmpty ? "—" : String(format: "%.1f", mean), symbol: "chart.bar.fill")
                    insightTile("Оценок 10/10", value: "\(scores.filter { $0 == 10 }.count)", symbol: "sparkles")
                    insightTile("В этом году", value: "\(ratedThisYear)", symbol: "calendar")
                }

                VStack(alignment: .leading, spacing: 14) {
                    Label("Распределение оценок", systemImage: "chart.bar.xaxis")
                        .font(.headline)
                    ForEach((1...10).reversed(), id: \.self) { score in
                        let total = scores.filter { $0 == score }.count
                        HStack(spacing: 12) {
                            Text("\(score)").font(.caption.weight(.bold)).frame(width: 18)
                            GeometryReader { box in
                                Capsule()
                                    .fill(.white.opacity(0.12))
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(.white.opacity(0.85))
                                            .frame(width: scores.isEmpty ? 0 : box.size.width * CGFloat(total) / CGFloat(max(1, scores.count)))
                                    }
                            }
                            .frame(height: 12)
                            Text("\(total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                        }
                    }
                }
                .padding(18)
                .vinylGlassSurface(cornerRadius: 24)

                VStack(alignment: .leading, spacing: 12) {
                    Label("Чаще всего оцениваешь", systemImage: "music.mic")
                        .font(.headline)
                    if topArtists.isEmpty {
                        Text("Появится после первых рецензий")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(topArtists.prefix(5))) { artist in
                            HStack(spacing: 10) {
                                Text(artist.name).font(.subheadline).lineLimit(2)
                                Spacer()
                                Text("\(artist.count) альб.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "%.1f", artist.mean))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                .padding(18)
                .vinylGlassSurface(cornerRadius: 24)

                Text("Статистика построена по твоим оценкам VINYL, а не по количеству прослушиваний Spotify.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .padding(.bottom, 28)
        }
    }

    private func insightTile(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.white.opacity(0.8))
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .vinylGlassSurface(cornerRadius: 23)
    }
}
