import SwiftUI

// A lightweight snapshot, not a full Spotify track object. Keeping the name
// locally means old reviews remain readable without an internet connection.
struct ReviewTrack: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let discNumber: Int
    let trackNumber: Int
}

struct AlbumReview: Codable, Equatable {
    let score: Int
    let bestTracks: [ReviewTrack]
    let comment: String
    // nil only for ratings migrated from VINYL 1.2.x (which had no dates).
    let ratedAt: Date?
    let updatedAt: Date?
}

private enum ReviewDateLabel {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()
    static func string(_ date: Date) -> String { formatter.string(from: date) }
}

/// A dedicated screen for both creating and reading an album review.
/// Opening an existing review goes directly to the detail view. "Изменить"
/// in the top-right corner opens the editor without losing the first date.
struct AlbumReviewFlowView: View {
    let album: VinylAlbum
    var startInEditor: Bool = false
    @EnvironmentObject private var model: VinylModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var wantsDeletion = false

    private var existing: AlbumReview? { model.review(for: album) }
    private var editorVisible: Bool { editing || existing == nil }

    var body: some View {
        NavigationStack {
            Group {
                if editorVisible {
                    AlbumReviewEditorView(album: album,
                                          onSaved: { editing = false },
                                          onCancel: {
                                              if existing == nil { dismiss() }
                                              else { editing = false }
                                          })
                } else if let review = existing {
                    AlbumReviewDetailView(album: album, review: review,
                                          onRemove: { wantsDeletion = true })
                }
            }
            .background(VinylBackdrop(accent: model.accent))
            .navigationTitle(editorVisible ? "Оценка альбома" : "Моя рецензия")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                        .foregroundStyle(.white)
                }
                if !editorVisible {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Изменить") { editing = true }
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                }
            }
            .confirmationDialog("Удалить оценку и рецензию?", isPresented: $wantsDeletion,
                                titleVisibility: .visible) {
                Button("Удалить оценку", role: .destructive) {
                    model.deleteReview(for: album)
                    dismiss()
                }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Баллы, выбранные треки и комментарий будут удалены только из VINYL.")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if startInEditor && existing != nil { editing = true }
        }
    }
}

private struct ReviewAlbumHeader: View {
    let album: VinylAlbum
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RemoteArtwork(url: album.artwork)
                .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 5) {
                Text(album.name)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Text(album.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(album.year)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AlbumReviewDetailView: View {
    let album: VinylAlbum
    let review: AlbumReview
    let onRemove: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ReviewAlbumHeader(album: album)
                    .padding(18)
                    .vinylGlassSurface(cornerRadius: 24)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("\(review.score)")
                        .font(.system(size: 70, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("/ 10")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Лучшие треки", systemImage: "music.note.list")
                        .font(.headline)
                    if review.bestTracks.isEmpty {
                        Text("Пока не выбраны")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(review.bestTracks) { track in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                Text(track.name)
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .vinylGlassSurface(cornerRadius: 24)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Мой комментарий", systemImage: "text.alignleft")
                        .font(.headline)
                    Text(review.comment.isEmpty ? "Без комментария" : review.comment)
                        .font(.body)
                        .foregroundStyle(review.comment.isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .vinylGlassSurface(cornerRadius: 24)

                VStack(alignment: .leading, spacing: 7) {
                    if let date = review.ratedAt {
                        Label("Дата оценки: \(ReviewDateLabel.string(date))", systemImage: "calendar")
                    } else {
                        Label("Дата первой оценки не сохранилась в старой версии", systemImage: "calendar.badge.exclamationmark")
                    }
                    if let updated = review.updatedAt,
                       let first = review.ratedAt,
                       updated.timeIntervalSince(first) > 60 {
                        Label("Изменено: \(ReviewDateLabel.string(updated))", systemImage: "pencil")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                ReviewShareButton(album: album, review: review)

                Button(role: .destructive, action: onRemove) {
                    Label("Удалить оценку", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .padding(.top, 5)
            }
            .padding(20)
            .padding(.bottom, 36)
        }
    }
}

private struct AlbumReviewEditorView: View {
    let album: VinylAlbum
    let onSaved: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var model: VinylModel
    @State private var initialized = false
    @State private var score = 0
    @State private var comment = ""
    @State private var choices = Set<String>()
    @State private var tracklist: [ReviewTrack] = []
    @State private var customTracks: [ReviewTrack] = []
    @State private var customName = ""
    @State private var loadingTracks = false
    @State private var trackError: String?

    private var availableTracks: [ReviewTrack] {
        var found = Set<String>()
        // Saved choices remain visible even when the Spotify API cannot be read.
        return (tracklist + customTracks).filter { found.insert($0.id).inserted }
    }
    private var selectedTracks: [ReviewTrack] {
        availableTracks.filter { choices.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ReviewAlbumHeader(album: album)
                    .padding(18)
                    .vinylGlassSurface(cornerRadius: 24)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Твоя оценка")
                        .font(.headline)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(score == 0 ? "—" : "\(score)")
                            .font(.system(size: 58, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("/ 10")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(1...10, id: \.self) { number in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { score = number }
                            } label: {
                                Text("\(number)")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 45)
                                    .background(score == number ? Color.white.opacity(0.24) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(.white.opacity(score == number ? 0.8 : 0.13), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Оценка \(number) из 10")
                            .accessibilityAddTraits(score == number ? [.isSelected] : [])
                        }
                    }
                }
                .padding(18)
                .vinylGlassSurface(cornerRadius: 24)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Лучшие треки")
                            .font(.headline)
                        Spacer()
                        if !choices.isEmpty {
                            Text("Выбрано: \(choices.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Отметь треки, которые больше всего понравились.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if loadingTracks {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Загружаем треклист Spotify…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let trackError {
                        Text(trackError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(availableTracks) { track in
                        Button { toggle(track) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: choices.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(choices.contains(track.id) ? 1 : 0.5))
                                Text(track.name)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if track.discNumber > 0 {
                                    Text("\(track.trackNumber)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                    HStack(spacing: 8) {
                        TextField("Вписать трек вручную", text: $customName)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.done)
                            .onSubmit(addCustomTrack)
                        Button { addCustomTrack() } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Добавить трек вручную")
                    }
                    .padding(12)
                    .vinylGlassSurface(cornerRadius: 16)
                }
                .padding(18)
                .vinylGlassSurface(cornerRadius: 24)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Комментарий")
                        .font(.headline)
                    TextEditor(text: $comment)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 135)
                        .padding(7)
                        .background(Color.black.opacity(0.19), in: RoundedRectangle(cornerRadius: 15))
                        .accessibilityLabel("Мой комментарий к альбому")
                    Text("Максимум 4000 символов. Комментарий необязателен.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .vinylGlassSurface(cornerRadius: 24)

                Button {
                    model.saveReview(score: score, bestTracks: selectedTracks,
                                     comment: comment, for: album)
                    onSaved()
                } label: {
                    Label("Сохранить оценку", systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .modifier(VinylGlassButtonModifier(prominent: true))
                .disabled(score == 0)

                Button("Отмена", action: onCancel)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
            .padding(20)
        }
        .task(id: album.id) {
            initializeIfNeeded()
            await fetchTracks()
        }
    }

    private func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true
        if let old = model.review(for: album) {
            score = old.score
            comment = old.comment
            customTracks = old.bestTracks
            choices = Set(old.bestTracks.map(\.id))
        }
    }

    private func fetchTracks() async {
        guard SpotifyAPI.shared.isConnected else {
            trackError = "Для автозагрузки треков подключи Spotify. Можно добавить названия вручную."
            return
        }
        loadingTracks = true
        defer { loadingTracks = false }
        do {
            let fetched = try await SpotifyAPI.shared.albumTracks(for: album)
            tracklist = fetched
            trackError = fetched.isEmpty ? "Spotify не вернул треки. Добавь нужные вручную." : nil
        } catch {
            trackError = "Не удалось получить треклист: \(error.localizedDescription) Впиши любимые треки вручную."
        }
    }

    private func toggle(_ track: ReviewTrack) {
        if choices.contains(track.id) { choices.remove(track.id) }
        else { choices.insert(track.id) }
    }

    private func addCustomTrack() {
        let name = String(customName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !name.isEmpty else { return }
        // Avoid duplicate manually entered names within this review.
        if let previous = availableTracks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            choices.insert(previous.id)
        } else {
            let track = ReviewTrack(id: "custom:\(UUID().uuidString)", name: name,
                                    discNumber: 0, trackNumber: 0)
            customTracks.append(track)
            choices.insert(track.id)
        }
        customName = ""
    }
}
